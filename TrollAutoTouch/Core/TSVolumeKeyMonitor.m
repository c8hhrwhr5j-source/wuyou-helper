//
//  TSVolumeKeyMonitor.m
//  TrollAutoTouch
//
//  App 进程内音量键识别 (SpringBoard 硬件按键事件版):
//    主通道通过 CPDistributedMessagingCenter 连 SpringBoard 的硬件按键服务
//    (消息名 com.apple.springboard.hardware-button-service.event-consumption),
//    entitlement 已在 TrollAutoTouch.entitlements 声明。
//    这是逆向 TrollAutoScript.tipa 确认的方案: SpringBoard 派发的是"物理按键事件",
//    与系统音量值是否变化无关, 所以音量到 0/满格时按对应键都能收到。
//
//    兜底通道保留: 私有 AVSystemController 通知 + 200ms 轮询。
//    TrollStore 注入的 substitute.dylib 在进程内注册了 CPDistributedMessagingCenter
//    类, 运行时用 NSClassFromString + objc_msgSend 调用, 避免编译时链接 libsubstrate。
//
//  线程模型: 回调在 main runloop 派发, 调用方自行转主线程。

#import "TSVolumeKeyMonitor.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>
#import <objc/message.h>

// SpringBoard 硬件按键服务 (TrollAutoScript 逆向确认)
static NSString *const kSpringBoardServiceName = @"com.apple.springboard";
static NSString *const kHardwareButtonMessageName =
    @"com.apple.springboard.hardware-button-service.event-consumption";

// 兜底通知名 (音量值变化时触发, 边界值按不动时不发)
static NSString *const kAVVolumeChangedNotification   = @"AVSystemController_VolumeChangedNotification";
static NSString *const kAVSystemVolumeChangedNotif   = @"AVSystemController_SystemVolumeDidChangeNotification";
static NSString *const kAVUserVolumeParamKey         = @"AVSystemController_UserVolumeParameter";
static NSString *const kAVChangeReasonKey            = @"AVSystemController_AudioVolumeChangeReasonParameter";

static const NSTimeInterval TSVolumePollInterval = 0.2;
static const NSTimeInterval TSVolumeWarmupDuration = 2.0;
// 多通道去重窗口: 同一次按键的 mach 事件 + 通知 + 轮询合并为一次
static const NSTimeInterval TSCrossChannelMergeWindow = 0.25;

@implementation TSVolumeKeyMonitor {
    dispatch_source_t _timer;
    float _lastVolume;
    BOOL _running;
    double _warmupUntil;
    double _lastEventAt;
    id _avSystemController;     // 私有 AVSystemController, 触发兜底通知
    id _messagingCenter;        // CPDistributedMessagingCenter 实例
    os_unfair_lock _lock;
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

    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers
                       error:&err]) {
        NSLog(@"[TSVolumeKeyMonitor] audio session: %@", err);
    } else {
        [session setActive:YES error:NULL];
    }

    _lastVolume = [self _currentVolume];
    _warmupUntil = CACurrentMediaTime() + TSVolumeWarmupDuration;
    _lastEventAt = 0;

    [self _installHardwareButtonListener];   // 主通道: 硬件按键事件
    [self _installNotificationListener];     // 兜底通道 ①: 通知
    [self _installPollFallback];             // 兜底通道 ②: 轮询
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
    if (_messagingCenter) {
        SEL sel = NSSelectorFromString(@"unregisterMessageName:target:");
        if ([_messagingCenter respondsToSelector:sel]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(_messagingCenter, sel,
                kHardwareButtonMessageName, self);
        }
        _messagingCenter = nil;
    }
    _avSystemController = nil;
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

// ── 主通道: SpringBoard 硬件按键事件 (CPDistributedMessagingCenter) ──
// TrollStore 注入的 substitute.dylib 注册了 CPDistributedMessagingCenter 类。
// 运行时用 NSClassFromString + objc_msgSend 调用, 避免编译时链接 libsubstrate。
- (void)_installHardwareButtonListener {
    Class cls = NSClassFromString(@"CPDistributedMessagingCenter");
    if (!cls) {
        NSLog(@"[TSVolumeKeyMonitor] CPDistributedMessagingCenter 不可用, 仅靠兜底通道");
        return;
    }
    SEL selCenter = NSSelectorFromString(@"centerNamed:");
    if (![cls respondsToSelector:selCenter]) {
        NSLog(@"[TSVolumeKeyMonitor] centerNamed: 不可用");
        return;
    }
    id center = ((id (*)(id, SEL, id))objc_msgSend)(cls, selCenter, kSpringBoardServiceName);
    if (!center) {
        NSLog(@"[TSVolumeKeyMonitor] 连接 SpringBoard 消息中心失败");
        return;
    }
    _messagingCenter = center;
    SEL selReg = NSSelectorFromString(@"registerForMessageName:target:selector:");
    if (![center respondsToSelector:selReg]) {
        NSLog(@"[TSVolumeKeyMonitor] registerForMessageName: 不可用");
        return;
    }
    ((void (*)(id, SEL, id, id, SEL))objc_msgSend)(center, selReg,
        kHardwareButtonMessageName, self, @selector(_onHardwareButtonMessage:withUserInfo:));
    NSLog(@"[TSVolumeKeyMonitor] 已订阅 SpringBoard 硬件按键事件");
}

// CPDistributedMessagingCenter 回调签名: 返回 NSDictionary 用于 reply, 普通消息可返 nil。
// userInfo 字段 SpringBoard 未公开文档, 包含按键类型/状态; 我们只关心"是否按键"——
// 任何硬件按键事件都触发弹窗 (对齐 TrollAutoScript 行为, 音量+/音量- 弹同一菜单)。
- (NSDictionary *)_onHardwareButtonMessage:(NSString *)name
                              withUserInfo:(NSDictionary *)userInfo {
    [self _onKeyDetectedWithUp:YES];
    return nil;
}

// ── 兜底通道 ①: 私有通知 (边界值按不动时通知可能不发) ──
- (void)_installNotificationListener {
    Class cls = NSClassFromString(@"AVSystemController");
    if (cls && [cls respondsToSelector:@selector(sharedAVSystemController)]) {
        _avSystemController = ((id (*)(id, SEL))objc_msgSend)(cls,
            NSSelectorFromString(@"sharedAVSystemController"));
    }
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
    BOOL isButton = (reason.length &&
                     [reason rangeOfString:@"button" options:NSCaseInsensitiveSearch].location != NSNotFound);
    os_unfair_lock_lock(&_lock);
    BOOL volumeMoved = (fabsf(newVol - _lastVolume) >= 0.001f);
    BOOL up = (newVol > _lastVolume + 0.0005f);
    _lastVolume = newVol;
    os_unfair_lock_unlock(&_lock);
    if (isButton || volumeMoved) {
        [self _onKeyDetectedWithUp:up];
    }
}

// ── 兜底通道 ②: 200ms 轮询 ──
- (void)_installPollFallback {
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

// 统一入口: 启动校准 + 多通道去重 + 回调
- (void)_onKeyDetectedWithUp:(BOOL)up {
    if (!_running) return;
    double now = CACurrentMediaTime();
    if (now < _warmupUntil) return;
    os_unfair_lock_lock(&_lock);
    if ((now - _lastEventAt) < TSCrossChannelMergeWindow) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    _lastEventAt = now;
    os_unfair_lock_unlock(&_lock);
    NSLog(@"[TSVolumeKeyMonitor] 音量键按下 (%@, 通道=硬件事件/通知/轮询)", up ? @"+" : @"-");
    if (self.onVolumeKey) {
        self.onVolumeKey();
    }
}

@end
