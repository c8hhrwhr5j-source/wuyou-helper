//
//  TSVolumeKeyMonitor.m
//  TrollAutoTouch
//
//  App 进程内音量键识别:
//    200ms 轮询 [AVAudioSession sharedInstance].outputVolume (公开只读 API),
//    相邻两次采样值变化即判定音量键被按下。与 AutoGo/CGO 的 aa_volume_monitor_ios.go
//    完全同构 —— 不注入、不监听私有通知、不碰 IOHID, 唯一依赖是能读系统音量。
//
//  放在 App 进程内即可: 只要 App 在运行(含后台保活), 音量键轮询就生效,
//  不依赖任何注入 (iOS 15.5+ TrollStore 2.x 无法获得 platform 身份, 注入不可行)。

#import "TSVolumeKeyMonitor.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

// 轮询间隔 200ms (CGO 同款)。音量键单次按压产生 1/16 格音量变化,
// 200ms 足够捕捉且不会漏掉快速连按。
static const NSTimeInterval TSVolumePollInterval = 0.2;
// 启动校准窗口: start 后这段时间内只校准基准音量, 不触发按键回调。
// 必须用"时间"而非"音量变化次数"——会话刚激活时读值可能从 0/陈旧值
// 经历多次变化才稳定, 但用户按键不受时间限制。若按"变化次数"计数,
// 会把用户前 3 次真实按键也吞掉 (表现为"冷启动后要按 4 次音量键才出
// 暂停/运行弹窗", 且无论连按还是隔很久按, 都精确在第 4 次才触发)。
static const NSTimeInterval TSVolumeWarmupDuration = 2.0;

@implementation TSVolumeKeyMonitor {
    dispatch_source_t _timer;
    float _lastVolume;
    BOOL _running;
    double _warmupUntil;
}

+ (instancetype)shared {
    static TSVolumeKeyMonitor *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [TSVolumeKeyMonitor new];
    });
    return inst;
}

- (float)_currentVolume {
    return [AVAudioSession sharedInstance].outputVolume;
}

- (void)start {
    if (_running) return;
    _running = YES;

    // 关键: 激活音频会话(Playback + 混播), 让 outputVolume 读值实时可用。
    // 会话未激活时 iOS 不会向 App 推送音量变化, 读值会停滞在旧值/0,
    // 表现为"空闲时按音量键检测不到变化 → 无法启动脚本"。
    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers
                       error:&err]) {
        NSLog(@"[TSVolumeKeyMonitor] 设置 audio session 失败: %@", err);
    } else {
        [session setActive:YES error:NULL];
    }

    _lastVolume = [self _currentVolume];
    // 启动后 2s 内只校准基准音量, 不触发按键回调
    _warmupUntil = CACurrentMediaTime() + TSVolumeWarmupDuration;

    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(_timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TSVolumePollInterval * NSEC_PER_SEC)),
                              (uint64_t)(TSVolumePollInterval * NSEC_PER_SEC),
                              (uint64_t)(TSVolumePollInterval * NSEC_PER_SEC * 0.2));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        [weakSelf _poll];
    });
    dispatch_resume(_timer);
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

- (void)_poll {
    if (!_running) return;
    float vol = [self _currentVolume];
    // 浮点误差容差: outputVolume 步进 1/16≈0.0625, 0.001 远小于步进,
    // 不会误判, 又能吸收读值抖动。
    if (fabsf(vol - _lastVolume) < 0.001f) return;
    _lastVolume = vol;
    // 启动初期仅校准基准: 吸收会话刚激活时读值从 0/陈旧跳到真实值,
    // 避免误触发。用时间窗口判断 (2s 后即恢复按键回调), 而不是按
    // "音量变化次数"计数——否则用户前 3 次真实按键会被当成校准吸收,
    // 表现为"冷启动后要按 4 次音量键才出弹窗"。
    if (CACurrentMediaTime() < _warmupUntil) {
        return;
    }
    if (self.onVolumeKey) {
        self.onVolumeKey();
    }
}

@end
