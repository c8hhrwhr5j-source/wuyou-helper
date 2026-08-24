//
//  TSVolumeKeyMonitor.m
//  TrollAutoTouch
//
//  App 进程内音量键识别 (物理按键感知版):
//    主通道监听私有通知 AVSystemController_VolumeChangedNotification ——
//    iOS 对音量键的处理是"物理按键事件广播" (含 up/down 原因字段),
//    与当前音量值是否真的变化无关, 所以音量已在 0/静音时按音量- 也能收到,
//    这解决旧轮询方案"静音时按-检测不到"的盲区, 行为对齐 TrollAutoScript。
//
//    兜底通道保留 200ms 轮询 outputVolume —— 私有通知在个别系统/情景失效时
//    仍有公开 API 兜底; 双通道去重窗口避免同一次按键重复触发。
//
//  不注入 SpringBoard、不碰 IOHID/GSEvent (TrollStore 应用无 platform 身份,
//  注入不可行), 唯一前提是 App 运行中且音频会话激活 (TSAudioKeepAlive 保活)。

#import "TSVolumeKeyMonitor.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>
#import <objc/message.h>

// 私有通知名/键 (编译期字符串字面量, 不链接私有框架、不引用私有符号)
static NSString *const kAVVolumeChangedNotification   = @"AVSystemController_VolumeChangedNotification";
static NSString *const kAVSystemVolumeChangedNotif   = @"AVSystemController_SystemVolumeDidChangeNotification";
static NSString *const kAVUserVolumeParamKey         = @"AVSystemController_UserVolumeParameter";
static NSString *const kAVChangeReasonKey            = @"AVSystemController_AudioVolumeChangeReasonParameter";

// 轮询兜底间隔 200ms: 音量键单次按压产生 1/16 格音量变化, 足够捕捉快速连按
static const NSTimeInterval TSVolumePollInterval = 0.2;
// 启动校准窗口: 期间只校准基准音量/吸收会话刚激活的读值跳变, 不触发按键回调。
// 必须用"时间"而非"音量变化次数"——否则会把用户前几次真实按键当成校准吸收。
static const NSTimeInterval TSVolumeWarmupDuration = 2.0;
// 双通道去重窗口: 同一次按键的通知事件与轮询事件落在该窗口内合并为一次
static const NSTimeInterval TSCrossChannelMergeWindow = 0.25;

@implementation TSVolumeKeyMonitor {
    dispatch_source_t _timer;
    float _lastVolume;
    BOOL _running;
    double _warmupUntil;
    double _lastEventAt;       // 双通道去重时间戳 (CACurrentMediaTime)
    id _avSystemController;    // 私有 AVSystemController 单例, 持有以转发系统音量通知
    os_unfair_lock _lock;      // 保护 _lastVolume / _lastEventAt (通知线程+轮询线程并发)
}

+ (instancetype)shared {
    static TSVolumeKeyMonitor *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [TSVolumeKeyMonitor new];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (float)_currentVolume {
    return [AVAudioSession sharedInstance].outputVolume;
}

- (void)start {
    if (_running) return;
    _running = YES;

    // 关键: 激活音频会话(Playback + 混播), 让 outputVolume 读值实时可用,
    // 且系统音量按键事件才会投递到本进程的通知。
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
    _warmupUntil = CACurrentMediaTime() + TSVolumeWarmupDuration;
    _lastEventAt = 0;

    [self _installNotificationListener];

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
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:kAVVolumeChangedNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:kAVSystemVolumeChangedNotif
                                                  object:nil];
    _avSystemController = nil;
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

// ── 主通道: 私有通知 (物理按键广播, 静音时也触发) ──
- (void)_installNotificationListener {
    // 先实例化私有 AVSystemController, 让其在进程内订阅 mediaserverd 的音量事件
    // 并向 NSNotificationCenter 广播; 不实例化则部分系统版本收不到该通知。
    Class cls = NSClassFromString(@"AVSystemController");
    if (cls && [cls respondsToSelector:@selector(sharedAVSystemController)]) {
        // 显式 objc_msgSend, 避免 performSelector 在 ARC 下对未知返回类型的泄漏警告
        _avSystemController = ((id (*)(id, SEL))objc_msgSend)(cls,
                                                              NSSelectorFromString(@"sharedAVSystemController"));
    }
    // 新老系统通知名都注册, 同一 handler, 由去重窗口合并
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_onVolumeChangedNotification:)
                                                 name:kAVVolumeChangedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_onVolumeChangedNotification:)
                                                 name:kAVSystemVolumeChangedNotif
                                               object:nil];
}

- (void)_onVolumeChangedNotification:(NSNotification *)n {
    NSDictionary *ui = n.userInfo;
    float newVol = _lastVolume;
    if ([ui[kAVUserVolumeParamKey] isKindOfClass:NSNumber.class]) {
        newVol = [ui[kAVUserVolumeParamKey] floatValue];
    }
    NSString *reason = ui[kAVChangeReasonKey];
    // 物理按键原因字段: "volumeButtonDown" / "volumeButtonUp" (大小写因系统而异)
    BOOL isButton = (reason.length &&
                     [reason rangeOfString:@"button" options:NSCaseInsensitiveSearch].location != NSNotFound);
    os_unfair_lock_lock(&_lock);
    BOOL volumeMoved = (fabsf(newVol - _lastVolume) >= 0.001f);
    BOOL up = (newVol > _lastVolume + 0.0005f);
    _lastVolume = newVol;
    os_unfair_lock_unlock(&_lock);
    // 按键广播即使音量未变 (音量已在 0/静音时按-) 也判定为按键
    if (isButton || volumeMoved) {
        [self _onKeyDetectedWithUp:up];
    }
}

// ── 兜底通道: 200ms 轮询 (音量值变化即判定) ──
- (void)_poll {
    if (!_running) return;
    float vol = [self _currentVolume];
    os_unfair_lock_lock(&_lock);
    BOOL moved = (fabsf(vol - _lastVolume) >= 0.001f);
    BOOL up = (vol > _lastVolume + 0.0005f);
    _lastVolume = vol;
    os_unfair_lock_unlock(&_lock);
    if (moved) {
        [self _onKeyDetectedWithUp:up];
    }
}

// 统一入口: 启动校准 + 双通道去重 + 回调
- (void)_onKeyDetectedWithUp:(BOOL)up {
    if (!_running) return;
    double now = CACurrentMediaTime();
    // 启动初期仅校准基准: 吸收会话刚激活时读值从 0/陈旧值跳到真实值
    if (now < _warmupUntil) return;
    os_unfair_lock_lock(&_lock);
    if ((now - _lastEventAt) < TSCrossChannelMergeWindow) {
        os_unfair_lock_unlock(&_lock);
        return; // 同一次按键的通知+轮询已触发过, 忽略
    }
    _lastEventAt = now;
    os_unfair_lock_unlock(&_lock);
    NSLog(@"[TSVolumeKeyMonitor] 音量键按下 (%@)", up ? @"+" : @"-");
    if (self.onVolumeKey) {
        self.onVolumeKey();
    }
}

@end
