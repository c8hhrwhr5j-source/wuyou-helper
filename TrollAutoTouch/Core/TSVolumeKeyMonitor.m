//
//  TSVolumeKeyMonitor.m
//  TrollAutoTouch
//
//  App 进程内音量键识别:
//    200ms 轮询 [AVAudioSession sharedInstance].outputVolume (公开只读 API),
//    相邻两次采样值变化即判定音量键被按下。与 AutoGo/CGO 的 aa_volume_monitor_ios.go
//    完全同构 —— 不注入、不监听私有通知、不碰 IOHID, 唯一依赖是能读系统音量。
//
//  为什么不放在注入的 dylib 里:
//    注入 SpringBoard 依赖 task_for_pid / opainject, arm64e 设备上容易失败
//    (用户实测 "注入失败, 命令未发送"), 导致音量键功能完全不可用。
//    而本方案在 App 进程内运行, 只要脚本在跑就能识别音量键, 与注入解耦。

#import "TSVolumeKeyMonitor.h"
#import <AVFoundation/AVFoundation.h>

// 轮询间隔 200ms (CGO 同款)。音量键单次按压产生 1/16 格音量变化,
// 200ms 足够捕捉且不会漏掉快速连按。
static const NSTimeInterval TSVolumePollInterval = 0.2;

@implementation TSVolumeKeyMonitor {
    dispatch_source_t _timer;
    float _lastVolume;
    BOOL _running;
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
    // 只读属性, 不激活/不修改 AudioSession, 对后台播放/系统音量零影响。
    return [AVAudioSession sharedInstance].outputVolume;
}

- (void)start {
    if (_running) return;
    _running = YES;
    _lastVolume = [self _currentVolume];

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
    if (self.onVolumeKey) {
        self.onVolumeKey();
    }
}

@end
