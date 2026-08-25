//
//  TSVolumeKeyMonitor.m
//  TrollAutoTouch
//
//  App 进程内音量键识别 (iOS 15+ 物理按键感知版):
//
//  【通道架构 - 按优先级排序】
//  ① BKS 硬件事件路由 (BackBoardServices.framework):
//     使用 BKSHIDEventRouter/BKSHIDEventDeliveryManager 直接拦截硬件按键事件,
//     绕过音频系统, 音量为 0 时仍能检测到物理按键。这是 TrollAutoScript 逆向
//     确认的核心实现方式 —— HUDServices 守护进程通过 BSServiceDomains 权限
//     注册为系统服务, 使用 BackBoardServices 私有 API 获取原始 HID 事件。
//  ② SpringBoard 硬件按键推送 (CPDistributedMessagingCenter):
//     连接 SpringBoard 消息中心, 订阅 hardware-button-service 事件。
//  ③ IOHIDEventSystemClient 全局 HID 事件:
//     通过 IOKit 框架直接获取物理 HID 事件。
//  ④ KVO + 边界回弹 (主通道兜底):
//     KVO 监听 AVAudioSession.outputVolume, 音量贴 0/1 边界时用
//     AVSystemController 悄悄拉回 0.05/0.95, 保证后续按键产生真实音量变化。
//  ⑤ 200ms 轮询 + AVSystemController 私有通知 (最终兜底)。

#import "TSVolumeKeyMonitor.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>
#import <objc/message.h>
#import <dlfcn.h>

// ── BackBoardServices 硬件事件路由 (TrollAutoScript 逆向核心机制) ──
static NSString *const kBKSFrameworkPath =
    @"/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices";
static NSString *const kBKSVolumeDownEventName = @"BKSHIDEventVolumeDown";
static NSString *const kBKSVolumeUpEventName = @"BKSHIDEventVolumeUp";
static NSString *const kBKSHIDEventDeliveryManagerClass = @"BKSHIDEventDeliveryManager";
static NSString *const kBKSApplicationIdentifier = @"com.tencent.QQMusic";

// ── SpringBoard 硬件按键服务 ──
static NSString *const kSpringBoardServiceName = @"com.apple.springboard";
static NSString *const kHardwareButtonMessageName =
    @"com.apple.springboard.hardware-button-service.event-consumption";
static NSString *const kCPDMCentersPath =
    @"/System/Library/PrivateFrameworks/CPDistributedMessagingCenter.framework/CPDistributedMessagingCenter";

// ── 兜底通知名 (音量值变化才触发) ──
static NSString *const kAVVolumeChangedNotification   = @"AVSystemController_VolumeChangedNotification";
static NSString *const kAVSystemVolumeChangedNotif   = @"AVSystemController_SystemVolumeDidChangeNotification";
static NSString *const kAVUserVolumeParamKey         = @"AVSystemController_UserVolumeParameter";
static NSString *const kAVChangeReasonKey            = @"AVSystemController_AudioVolumeChangeReasonParameter";

static const NSTimeInterval TSVolumePollInterval = 0.2;
static const NSTimeInterval TSVolumeWarmupDuration = 2.0;
static const NSTimeInterval TSCrossChannelMergeWindow = 0.25;

// ── IOHID 私有函数签名 (IOKit.framework 运行时 dlsym) ──
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef void (*IOHIDEventCallback)(void *target, void *refcon,
                                   IOHIDServiceClientRef service, IOHIDEventRef event);

// IOHID 事件类型 / 字段 (私有头常量)
enum {
    kTSHIDEventTypeKeyboard = 3,
};
enum {
    kTSHIDEventFieldKeyboardUsagePage = 0x30001,
    kTSHIDEventFieldKeyboardUsage     = 0x30002,
    kTSHIDEventFieldKeyboardDown      = 0x30005,
};

// 音量键 HID Usage (键盘页面)
#define kTSHIDUsage_KeyboardVolumeUp   0x80
#define kTSHIDUsage_KeyboardVolumeDown 0x81

@interface TSVolumeKeyMonitor ()
@property (nonatomic, assign) BOOL running;
- (void)_onKeyDetectedWithUp:(BOOL)up;
@end

@implementation TSVolumeKeyMonitor {
    dispatch_source_t _timer;
    dispatch_source_t _watchdogTimer;  // 看门狗: 持续维持最小音量级别
    float _lastVolume;
    BOOL _running;
    BOOL _stopping;             // 停止标记: 防止后台 BKS 注册线程与主线程 stop 清理竞态
    double _warmupUntil;
    double _lastEventAt;
    id _avSystemController;
    id _messagingCenter;        // CPDistributedMessagingCenter 实例
    IOHIDEventSystemClientRef _hidClient;   // IOHIDEventSystemClient
    dispatch_queue_t _hidQueue;
    os_unfair_lock _lock;
    // BKS 硬件事件路由 (BackBoardServices)
    id _bksDeliveryManager;    // BKSHIDEventDeliveryManager 实例
    id _bksEventObserver;       // BKS 事件观察者/路由对象
    dispatch_queue_t _bksQueue; // BKS 事件处理队列 (注册与清理共用, 串行互斥)
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
    _stopping = NO;

    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers
                       error:&err]) {
        NSLog(@"[TSVolumeKeyMonitor] audio session: %@", err);
    } else {
        [session setActive:YES error:NULL];
    }
    // iOS 15 起 AVSystemController 私有通知停发, KVO 是唯一可靠变化信号
    [session addObserver:self
              forKeyPath:@"outputVolume"
                 options:NSKeyValueObservingOptionNew
                 context:NULL];

    _lastVolume = [self _currentVolume];
    _warmupUntil = CACurrentMediaTime() + TSVolumeWarmupDuration;
    _lastEventAt = 0;

    // 通道① BKS 硬件事件路由 — 异步初始化避免阻塞主线程/启动崩溃
    // ⚠️ 任何私有 API 崩溃只影响后台线程, 不会导致 App 闪退
    // 注册在 _bksQueue 串行队列执行, 与 stop 的清理共用同一队列, 避免竞态
    if (!_bksQueue) {
        _bksQueue = dispatch_queue_create("com.trollautotouch.volumekey.bks", DISPATCH_QUEUE_SERIAL);
    }
    dispatch_async(_bksQueue, ^{
        @try {
            [self _installBKSListener];
        } @catch (NSException *e) {
            NSLog(@"[TSVolumeKeyMonitor] BKS init exception: %@ %@", e.name, e.reason);
        }
    });
    // 通道② SpringBoard 硬件按键推送
    [self _installCPDMMachListener];
    // 通道③ IOHID 物理事件
    [self _installHIDListener];
    // 通道④⑤ 兜底
    [self _installNotificationListener];
    [self _installPollFallback];

    // ═══════════════════════════════════════════════════════════
    // 看门狗定时器: 持续维持最小音量级别 (0.05)
    // 当音量为 0 时, 自动弹回 0.05, 确保下一次物理按键产生可检测的音量变化。
    // 这是"空音量检测"的关键: 系统音量永远不会停留在 0,
    // 每次按音量键都会产生 0.05↔0 的变化, 被 KVO 捕获。
    // ═══════════════════════════════════════════════════════════
    _watchdogTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0));
    if (_watchdogTimer) {
        dispatch_source_set_timer(_watchdogTimer,
            DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_watchdogTimer, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf->_running) return;
            [strongSelf _volumeWatchdog];
        });
        dispatch_resume(_watchdogTimer);
        NSLog(@"[TSVolumeKeyMonitor] 看门狗定时器已启动 (300ms 间隔)");
    }
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    _stopping = YES;   // 通知后台 BKS 注册线程立即退出, 避免与清理并发

    @try {
        [[AVAudioSession sharedInstance] removeObserver:self
                                             forKeyPath:@"outputVolume"
                                                context:NULL];
    } @catch (NSException *exception) { /* 未注册过 KVO 则忽略 */ }
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:kAVVolumeChangedNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:kAVSystemVolumeChangedNotif
                                                  object:nil];

    // 清理 BKS 硬件事件路由 (与后台注册共用 _bksQueue, 串行互斥, 杜绝并发私有 API 调用)
    void (^cleanBKS)(void) = ^{
        if (_bksDeliveryManager) {
            @try {
                [self _unregisterBKSDeliveryManager];
            } @catch (NSException *e) {
                NSLog(@"[TSVolumeKeyMonitor] BKS 清理异常: %@ %@", e.name, e.reason);
            }
            _bksDeliveryManager = nil;
        }
        _bksEventObserver = nil;
    };
    // ⚠️ 绝不能 dispatch_sync 阻塞主线程等待 BKS 清理:
    // iOS 15.8 / TrollStore (无 BSServiceDomains 权限) 下 BKS 私有 API 可能挂起等待,
    // 若后台注册线程卡在 registerForVolumeEventsWithHandler: 内, 主线程同步等待
    // → 主线程永久阻塞 → 系统 watchdog 杀进程 (用户表现为"闪退")。
    // 改异步: 清理与注册共用 _bksQueue 串行执行, _stopping 门控保证无并发, 主线程不等待。
    if (_bksQueue) {
        dispatch_async(_bksQueue, cleanBKS);
    } else {
        cleanBKS();
    }

    // 清理 CPDM (SpringBoard 硬件按键)
    if (_messagingCenter) {
        @try {
            // 取消 delegate
            SEL setDelSel = NSSelectorFromString(@"setDelegate:");
            if ([_messagingCenter respondsToSelector:setDelSel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(_messagingCenter, setDelSel, nil);
            }
            // 取消消息注册
            SEL unregSel = NSSelectorFromString(@"unregisterMessageName:target:");
            if ([_messagingCenter respondsToSelector:unregSel]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(_messagingCenter, unregSel,
                    kHardwareButtonMessageName, self);
            }
        } @catch (NSException *e) {
            NSLog(@"[TSVolumeKeyMonitor] CPDM 清理异常: %@ %@", e.name, e.reason);
        }
        _messagingCenter = nil;
    }

    // 清理 IOHID
    if (_hidClient) {
        @try {
            void (*fnInvalidate)(IOHIDEventSystemClientRef) =
                (void (*)(IOHIDEventSystemClientRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientInvalidate");
            if (fnInvalidate) fnInvalidate(_hidClient);
            CFRelease(_hidClient);
        } @catch (NSException *e) {
            NSLog(@"[TSVolumeKeyMonitor] IOHID 清理异常: %@ %@", e.name, e.reason);
        }
        _hidClient = NULL;
    }

    _avSystemController = nil;
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    if (_watchdogTimer) {
        dispatch_source_cancel(_watchdogTimer);
        _watchdogTimer = nil;
    }
}

// ═══════════ 主通道①: BKS 硬件事件路由 (BackBoardServices.framework) ═══════════
// TrollAutoScript 逆向核心: HUDServices 守护进程通过 BackBoardServices 私有 API
// 的 BKSHIDEventDeliveryManager 直接获取硬件按键事件, 绕过音频系统, 音量为 0 时
// 仍能检测到物理按键。BSServiceDomains 权限是此通道生效的前提。
// ⚠️ 安全防护: 整个方法包裹在 @try/@catch 中, 避免任何私有 API 崩溃导致 App 闪退。
- (void)_installBKSListener {
    @try {
        if (_stopping) return;   // stop 已执行: 放弃注册, 避免与主线程清理竞态
        // 预处理: 检查 iOS 版本 (BackBoardServices 在 iOS 7+ 存在,
        // 但 BKSHIDEventDeliveryManager 类在 iOS 12+ 才有)
        NSOperatingSystemVersion osVer = [NSProcessInfo processInfo].operatingSystemVersion;
        if (osVer.majorVersion < 12) {
            NSLog(@"[TSVolumeKeyMonitor] BKS 跳过: iOS %d.%d 不支持 BKSHIDEventDeliveryManager",
                  (int)osVer.majorVersion, (int)osVer.minorVersion);
            return;
        }

        // 预处理: 检查框架二进制文件是否存在 (避免 dlopen 崩溃)
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:kBKSFrameworkPath]) {
            NSLog(@"[TSVolumeKeyMonitor] BKS 跳过: BackBoardServices 框架不存在于路径 %@", kBKSFrameworkPath);
            return;
        }

        // 动态加载 BackBoardServices 私有框架 (用 RTLD_LAZY 避免立即解析依赖)
        void *bksHandle = dlopen([kBKSFrameworkPath UTF8String], RTLD_LAZY | RTLD_LOCAL);
        if (!bksHandle) {
            NSLog(@"[TSVolumeKeyMonitor] dlopen BackBoardServices 失败: %s", dlerror());
            return;
        }
        NSLog(@"[TSVolumeKeyMonitor] BackBoardServices 框架已加载");

        // 获取 BKSHIDEventDeliveryManager 类
        Class deliveryMgrClass = NSClassFromString(kBKSHIDEventDeliveryManagerClass);
        if (!deliveryMgrClass) {
            NSLog(@"[TSVolumeKeyMonitor] BKSHIDEventDeliveryManager 类不存在");
            dlclose(bksHandle);
            return;
        }

        // 获取单例或实例 (所有 objc_msgSend 调用加空指针检查)
        id mgr = nil;
        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        if ([deliveryMgrClass respondsToSelector:sharedSel]) {
            mgr = ((id (*)(id, SEL))objc_msgSend)(deliveryMgrClass, sharedSel);
        }
        if (!mgr) {
            mgr = ((id (*)(id, SEL))objc_msgSend)(deliveryMgrClass, @selector(alloc));
            if (mgr) {
                mgr = ((id (*)(id, SEL))objc_msgSend)(mgr, @selector(init));
            }
        }
        if (!mgr) {
            NSLog(@"[TSVolumeKeyMonitor] BKSHIDEventDeliveryManager 实例化失败");
            dlclose(bksHandle);
            return;
        }
        if (_stopping) return;   // stop 已执行: 放弃注册
        _bksDeliveryManager = mgr;
        NSLog(@"[TSVolumeKeyMonitor] BKSHIDEventDeliveryManager 已获取: %@", mgr);

        if (!_bksQueue) {
            _bksQueue = dispatch_queue_create("com.trollautotouch.volumekey.bks", DISPATCH_QUEUE_SERIAL);
        }

        __weak typeof(self) weakSelf = self;

        // 方式 A: registerForVolumeEventsWithHandler: (block-based, iOS 14+)
        SEL regVolumeSel = NSSelectorFromString(@"registerForVolumeEventsWithHandler:");
        if ([mgr respondsToSelector:regVolumeSel]) {
            void (^handler)(BOOL volumeUp) = ^(BOOL volumeUp) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf _onKeyDetectedWithUp:volumeUp];
                });
            };
            ((void (*)(id, SEL, id))objc_msgSend)(mgr, regVolumeSel, handler);
            _bksEventObserver = handler;
            NSLog(@"[TSVolumeKeyMonitor] BKS 通道已注册 (registerForVolumeEventsWithHandler:)");
            return;
        }

        // 方式 B: registerForEventOfType:withHandler:
        SEL regEventTypeSel = NSSelectorFromString(@"registerForEventOfType:withHandler:");
        if ([mgr respondsToSelector:regEventTypeSel]) {
            void (^handler)(NSString *eventType) = ^(NSString *eventType) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                BOOL isUp = [eventType containsString:@"Up"];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf _onKeyDetectedWithUp:isUp];
                });
            };
            NSString *volDownType = @"com.apple.hid.event.volume-down";
            NSString *volUpType = @"com.apple.hid.event.volume-up";
            ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, regEventTypeSel, volDownType, handler);
            ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, regEventTypeSel, volUpType, handler);
            _bksEventObserver = handler;
            NSLog(@"[TSVolumeKeyMonitor] BKS 通道已注册 (registerForEventOfType:withHandler:)");
            return;
        }

        // 方式 C: BKSHIDEventRouter (iOS 13+ 替代方案)
        Class routerClass = NSClassFromString(@"BKSHIDEventRouter");
        if (routerClass) {
            id router = ((id (*)(id, SEL))objc_msgSend)(routerClass, @selector(alloc));
            if (router) {
                router = ((id (*)(id, SEL))objc_msgSend)(router, @selector(init));
                SEL setRouteSel = NSSelectorFromString(@"setRoute:forApplication:");
                if (router && [router respondsToSelector:setRouteSel]) {
                    id routeClass = NSClassFromString(@"BKSHIDEventRoute");
                    id route = nil;
                    if (routeClass) {
                        route = ((id (*)(id, SEL))objc_msgSend)(routeClass, @selector(alloc));
                        if (route) route = ((id (*)(id, SEL))objc_msgSend)(route, @selector(init));
                    }
                    if (route) {
                        SEL setEventsSel = NSSelectorFromString(@"setEventTypes:");
                        if ([route respondsToSelector:setEventsSel]) {
                            NSArray *volumeEvents = @[kBKSVolumeDownEventName, kBKSVolumeUpEventName];
                            ((void (*)(id, SEL, id))objc_msgSend)(route, setEventsSel, volumeEvents);
                        }
                        ((void (*)(id, SEL, id, id))objc_msgSend)(router, setRouteSel, route, kBKSApplicationIdentifier);
                        _bksEventObserver = router;
                        NSLog(@"[TSVolumeKeyMonitor] BKS BKSHIDEventRouter 已设置路由");
                        return;
                    }
                }
            }
        }

        // 方式 D: registerObserver:forEvents:
        SEL regObserverSel = NSSelectorFromString(@"registerObserver:forEvents:");
        if ([mgr respondsToSelector:regObserverSel]) {
            id observerBlock = ^(NSString *eventType, NSDictionary *eventInfo) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                BOOL isUp = [eventType containsString:@"Up"];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf _onKeyDetectedWithUp:isUp];
                });
            };
            NSArray *events = @[kBKSVolumeDownEventName, kBKSVolumeUpEventName];
            ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, regObserverSel, observerBlock, events);
            _bksEventObserver = observerBlock;
            NSLog(@"[TSVolumeKeyMonitor] BKS 通道已注册 (registerObserver:forEvents:)");
            return;
        }

        // 方式 E: registerConsumer:withIdentifier:
        SEL regConsumerSel = NSSelectorFromString(@"registerConsumer:withIdentifier:");
        if ([mgr respondsToSelector:regConsumerSel]) {
            id consumer = ^(NSDictionary *event) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                NSString *eventType = event[@"type"] ?: event[@"eventType"] ?: @"";
                BOOL isUp = [eventType containsString:@"Up"] || [eventType integerValue] == 1;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf _onKeyDetectedWithUp:isUp];
                });
            };
            ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, regConsumerSel, consumer, kBKSApplicationIdentifier);
            _bksEventObserver = consumer;
            NSLog(@"[TSVolumeKeyMonitor] BKS 通道已注册 (registerConsumer:withIdentifier:)");
            return;
        }

        NSLog(@"[TSVolumeKeyMonitor] BKS 通道: 所有注册方式均未匹配 (可能此 iOS 版本不支持)");
    } @catch (NSException *exception) {
        NSLog(@"[TSVolumeKeyMonitor] BKS 通道异常 (已跳过): %@ %@",
              exception.name, exception.reason);
        _bksDeliveryManager = nil;
        _bksEventObserver = nil;
    }
}

// 清理 BKS 硬件事件路由
- (void)_unregisterBKSDeliveryManager {
    if (!_bksDeliveryManager) return;

    // 尝试各种取消注册方法
    // unregisterForVolumeEvents
    SEL unregVolSel = NSSelectorFromString(@"unregisterForVolumeEvents");
    if ([_bksDeliveryManager respondsToSelector:unregVolSel]) {
        ((void (*)(id, SEL))objc_msgSend)(_bksDeliveryManager, unregVolSel);
        NSLog(@"[TSVolumeKeyMonitor] BKS 已取消注册 (unregisterForVolumeEvents)");
        return;
    }

    // unregisterObserver:
    if (_bksEventObserver) {
        SEL unregObsSel = NSSelectorFromString(@"unregisterObserver:");
        if ([_bksDeliveryManager respondsToSelector:unregObsSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(_bksDeliveryManager, unregObsSel, _bksEventObserver);
            NSLog(@"[TSVolumeKeyMonitor] BKS 已取消注册 (unregisterObserver:)");
        }
    }

    // invalidate / removeRoutes
    SEL invalidateSel = NSSelectorFromString(@"invalidate");
    if ([_bksDeliveryManager respondsToSelector:invalidateSel]) {
        ((void (*)(id, SEL))objc_msgSend)(_bksDeliveryManager, invalidateSel);
    }

    NSLog(@"[TSVolumeKeyMonitor] BKS 通道已清理");
}

// ═══════════ 主通道②: SpringBoard 硬件按键事件 (CPDistributedMessagingCenter) ═══════════
// TrollAutoScript 逆向结论: 不用 registerForMessageName:target:selector:,
// 而是连接后 sendMessageAndReceiveReplyName: 发送订阅请求, 并实现
// handleMessageNamed:withUserInfo: 方法接收 SpringBoard 后续推送的按键事件。
- (void)_installCPDMMachListener {
    // 关键: 系统私有框架默认未加载, 必须先 dlopen (TrollAutoScript 是编译时链接,
    // 运行时自动加载; 我们走运行时 dlopen, 效果等价)。
    void *handle = dlopen([kCPDMCentersPath UTF8String], RTLD_NOW);
    if (!handle) {
        NSLog(@"[TSVolumeKeyMonitor] dlopen CPDistributedMessagingCenter 失败: %s", dlerror());
        return;
    }
    Class cls = NSClassFromString(@"CPDistributedMessagingCenter");
    if (!cls) {
        NSLog(@"[TSVolumeKeyMonitor] CPDistributedMessagingCenter 类不存在");
        return;
    }
    id center = ((id (*)(id, SEL, id))objc_msgSend)(cls, @selector(centerNamed:), kSpringBoardServiceName);
    if (!center) {
        NSLog(@"[TSVolumeKeyMonitor] 连接 SpringBoard 消息中心失败 (center 为 nil)");
        return;
    }
    _messagingCenter = center;

    // ⚠️ 关键: 设置 delegate, SpringBoard 才会通过 handleMessageNamed:withUserInfo: 回调
    SEL setDelSel = NSSelectorFromString(@"setDelegate:");
    if ([center respondsToSelector:setDelSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(center, setDelSel, self);
        NSLog(@"[TSVolumeKeyMonitor] 已设置 CPDMC delegate");
    }

    // 也尝试 registerForMessageName:target:selector: 方式 (双重保险)
    SEL regMsgSel = NSSelectorFromString(@"registerForMessageName:target:selector:");
    if ([center respondsToSelector:regMsgSel]) {
        ((void (*)(id, SEL, id, id, SEL))objc_msgSend)(center,
            regMsgSel, kHardwareButtonMessageName, self,
            @selector(handleMessageNamed:withUserInfo:));
        NSLog(@"[TSVolumeKeyMonitor] 已注册 CPDMC 消息监听 (registerForMessageName)");
    }

    // 发送订阅请求: SpringBoard 收到后向本进程推送硬件按键事件 (同步等 reply)。
    // 消息名 = 硬件按键服务名 (TrollAutoScript 从自身 embedded entitlements 读取,
    // 我们直接硬编码同名)。userInfo 空即可, 订阅由 mach 服务端按消息名匹配。
    if ([center respondsToSelector:@selector(sendMessageAndReceiveReplyName:userInfo:error:)]) {
        NSError *subErr = nil;
        id reply = ((id (*)(id, SEL, id, id, id *))objc_msgSend)(center,
            @selector(sendMessageAndReceiveReplyName:userInfo:error:),
            kHardwareButtonMessageName, @{}, &subErr);
        NSLog(@"[TSVolumeKeyMonitor] 硬件按键订阅 reply=%@ 错误=%@",
              reply, subErr ? subErr.localizedDescription : @"无");
    }
    NSLog(@"[TSVolumeKeyMonitor] 已订阅 SpringBoard 硬件按键事件 (mach 通道)");
}

// 接收 SpringBoard 推送的回调, 方法名必须精确匹配 handleMessageNamed:withUserInfo:。
// userInfo 字段未公开文档, 尝试从字典中提取按键方向信息。
- (NSDictionary *)handleMessageNamed:(NSString *)name withUserInfo:(NSDictionary *)userInfo {
    NSLog(@"[TSVolumeKeyMonitor] CPDMC 硬件按键事件: %@ userInfo=%@", name, userInfo ?: @"");
    
    // 尝试判断按键方向
    BOOL isUp = YES; // 默认上
    if (userInfo) {
        // 常见字段名尝试
        NSString *eventType = userInfo[@"eventType"] ?: userInfo[@"type"] ?: userInfo[@"event"] ?: @"";
        if ([eventType containsString:@"Down"] || [eventType containsString:@"down"] ||
            [eventType containsString:@"VolumeDown"]) {
            isUp = NO;
        } else if ([eventType containsString:@"Up"] || [eventType containsString:@"up"]) {
            isUp = YES;
        }
        // 也可能是数值编码
        NSNumber *direction = userInfo[@"direction"] ?: userInfo[@"buttonDirection"];
        if (direction) {
            isUp = [direction boolValue]; // 1=up, 0=down 或相反
        }
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _onKeyDetectedWithUp:isUp];
    });
    return nil;
}

// ═══════════ 主通道②: IOHIDEventSystemClient 直接拿物理事件 ═══════════
- (void)_installHIDListener {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!iokit) {
        NSLog(@"[TSVolumeKeyMonitor] dlopen IOKit 失败: %s", dlerror());
        return;
    }
    // IOHIDEventSystemClientCreate(CFAllocatorRef)
    IOHIDEventSystemClientRef (*fnCreate)(CFAllocatorRef) =
        (IOHIDEventSystemClientRef (*)(CFAllocatorRef))dlsym(iokit, "IOHIDEventSystemClientCreate");
    void (*fnRegister)(IOHIDEventSystemClientRef, IOHIDEventCallback, void *, void *) =
        (void (*)(IOHIDEventSystemClientRef, IOHIDEventCallback, void *, void *))
        dlsym(iokit, "IOHIDEventSystemClientRegisterEventCallback");
    void (*fnSetDispatchQueue)(IOHIDEventSystemClientRef, dispatch_queue_t) =
        (void (*)(IOHIDEventSystemClientRef, dispatch_queue_t))
        dlsym(iokit, "IOHIDEventSystemClientSetDispatchQueue");
    if (!fnCreate || !fnRegister || !fnSetDispatchQueue) {
        NSLog(@"[TSVolumeKeyMonitor] IOHID 符号缺失 create=%p register=%p queue=%p",
              fnCreate, fnRegister, fnSetDispatchQueue);
        return;
    }
    IOHIDEventSystemClientRef client = fnCreate(kCFAllocatorDefault);
    if (!client) {
        NSLog(@"[TSVolumeKeyMonitor] IOHIDEventSystemClientCreate 返回 NULL (权限不足?)");
        return;
    }
    _hidClient = client;
    _hidQueue = dispatch_queue_create("com.wuyou.volumekey.hid", DISPATCH_QUEUE_SERIAL);
    fnSetDispatchQueue(client, _hidQueue);
    fnRegister(client, &TSVolumeKeyHIDCallback, NULL, NULL);
    NSLog(@"[TSVolumeKeyMonitor] IOHID 物理事件监听已启动");
}

// C 回调桥接 (C 函数内不能访问实例, 通过单例获取)
static void TSVolumeKeyHIDCallback(void *target, void *refcon,
                                   IOHIDServiceClientRef service, IOHIDEventRef event) {
    if (!event) return;
    // IOHIDEventGetType
    static uint32_t (*fnGetType)(IOHIDEventRef) = NULL;
    static int64_t (*fnGetInteger)(IOHIDEventRef, uint32_t) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        fnGetType = (uint32_t (*)(IOHIDEventRef))dlsym(iokit, "IOHIDEventGetType");
        fnGetInteger = (int64_t (*)(IOHIDEventRef, uint32_t))dlsym(iokit, "IOHIDEventGetIntegerValue");
    });
    if (!fnGetType || !fnGetInteger) return;
    if (fnGetType(event) != kTSHIDEventTypeKeyboard) return;

    uint32_t usagePage = (uint32_t)fnGetInteger(event, kTSHIDEventFieldKeyboardUsagePage);
    uint32_t usage     = (uint32_t)fnGetInteger(event, kTSHIDEventFieldKeyboardUsage);
    // 音量键: 键盘页面 0x80(音量+) / 0x81(音量-)
    if (usagePage == 0x01 && (usage == kTSHIDUsage_KeyboardVolumeUp ||
                              usage == kTSHIDUsage_KeyboardVolumeDown)) {
        TSVolumeKeyMonitor *mon = [TSVolumeKeyMonitor shared];
        [mon _onKeyDetectedWithUp:(usage == kTSHIDUsage_KeyboardVolumeUp)];
    }
}

// ═══════════ 兜底通道①: AVSystemController 通知 ═══════════
- (void)_installNotificationListener {
    Class cls = NSClassFromString(@"AVSystemController");
    if (!cls) {
        // Celestial 私有框架通常已被 UIKit 隐式加载; 未加载时主动 dlopen
        dlopen("/System/Library/PrivateFrameworks/Celestial.framework/Celestial", RTLD_NOW);
        cls = NSClassFromString(@"AVSystemController");
    }
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
    [self _onVolumeValueChangedTo:newVol];
}

// ═══════════ 统一音量变化处理 + 边界回弹 (iOS 15 空音量检测核心) ═══════════
// KVO 回调 (公开 API, iOS 15 唯一可靠变化信号; 线程不定, 内部有锁)
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"outputVolume"]) {
        NSNumber *v = change[NSKeyValueChangeNewKey];
        if ([v isKindOfClass:NSNumber.class]) {
            [self _onVolumeValueChangedTo:v.floatValue];
        }
    }
}

// 音量值变化统一入口 (KVO / 私有通知 / 轮询共用)。
// 关键: 音量到 0 后系统不再改变音量, 任何通道都收不到"按键"。
// 因此检测到边界时主动把音量拉回活跃区 (0.05/0.95), 使后续物理按键
// 每次都产生真实音量变化 (0.05→0), 空音量按音量- 也持续触发回调。
- (void)_onVolumeValueChangedTo:(float)newVol {
    os_unfair_lock_lock(&_lock);
    BOOL volumeMoved = (fabsf(newVol - _lastVolume) >= 0.001f);
    BOOL up = (newVol > _lastVolume + 0.0005f);
    if (volumeMoved) _lastVolume = newVol;
    os_unfair_lock_unlock(&_lock);
    if (volumeMoved) {
        [self _onKeyDetectedWithUp:up];
    }
    [self _bounceIfAtBoundary:newVol];
}

// 看门狗: 持续维持最小音量级别 (0.05)
// 当音量为 0 时, 自动弹回 0.05, 确保下一次物理按键产生 0.05→0 的变化被 KVO 捕获。
// ⚠️ 这是检测"空音量物理按键"的核心机制: 系统永远不会停在 0 音量。
- (void)_volumeWatchdog {
    float vol = [self _currentVolume];
    if (vol <= 0.001f) {
        // 音量为 0, 悄悄拉到 0.05
        // 使用 AVSystemController 私有 API 设置 (不经过系统音量 UI)
        [self _setMediaVolumeAndSync:0.05f];
        NSLog(@"[TSVolumeKeyMonitor] 看门狗: 音量为0 → 弹回 0.05");
    } else if (vol >= 0.99f) {
        // 音量满格, 悄悄拉到 0.95 (对称处理)
        [self _setMediaVolumeAndSync:0.95f];
    }
}

// 音量贴边界 (0 或 1) 时主动回弹, 保证按键可检测。幂等: 不在边界直接返回。
- (void)_bounceIfAtBoundary:(float)current {
    if (!_avSystemController) return;
    if (current <= 0.001f) {
        [self _setMediaVolumeAndSync:0.05f];
    } else if (current >= 0.99f) {
        [self _setMediaVolumeAndSync:0.95f];
    }
}

// 私有 API 设置媒体音量 (Celestial AVSystemController, 运行时调用)。
// category 依次尝试 Audio/Video → MediaPlayback, 以第一个返回 YES 的为准。
- (BOOL)_setMediaVolume:(float)vol {
    if (!_avSystemController) return NO;
    SEL sel = NSSelectorFromString(@"setVolumeTo:forCategory:");
    if (![_avSystemController respondsToSelector:sel]) return NO;
    for (NSString *cat in @[@"Audio/Video", @"MediaPlayback"]) {
        BOOL ok = ((BOOL (*)(id, SEL, float, id))objc_msgSend)(_avSystemController, sel, vol, cat);
        if (ok) return YES;
    }
    return NO;
}

// 立即同步内部基线 + 主线程执行设置。
// 先同步基线: 使"回弹产生的音量变化 (0→0.05)"在 KVO/轮询中判定为 moved=NO,
// 不误触发按键回调。
- (void)_setMediaVolumeAndSync:(float)target {
    os_unfair_lock_lock(&_lock);
    _lastVolume = target;
    os_unfair_lock_unlock(&_lock);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _setMediaVolume:target];
    });
}

// ═══════════ 兜底通道②: 200ms 轮询 ═══════════
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
    [self _onVolumeValueChangedTo:vol];
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
    NSLog(@"[TSVolumeKeyMonitor] 音量键按下 (%@)", up ? @"+" : @"-");
    // 一次读取并强引用回调: 旧代码在 if 判断与调用之间读取两次属性,
    // 主线程 (关闭 TAS 时置 nil) 可能插入置 nil → 第二次读到 nil → 调用 nil block
    // → EXC_BAD_ACCESS 闪退。atomic getter 返回的对象由局部变量持有, 置 nil 不影响本次调用。
    void (^handler)(void) = self.onVolumeKey;
    if (handler) {
        handler();
    }
}

@end
