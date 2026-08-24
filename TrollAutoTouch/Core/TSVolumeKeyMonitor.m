//
//  TSVolumeKeyMonitor.m
//  TrollAutoTouch
//
//  App 进程内音量键识别 (iOS 15 物理按键感知版):
//    ⚠ iOS 15.5+/TrollStore(CoreTrust 2) 拿不到 platform 身份, 以下两条
//      "原始按键事件"通道在 iOS 15.8.4 上实测不可行 (保留但不依赖):
//      ① CPDistributedMessagingCenter 连接 SpringBoard 硬件按键服务
//         (非 platform 进程 mach lookup 被拒, SpringBoard 端不信任);
//      ② IOHIDEventSystemClient 全局 HID 事件 (需 platform + event-dispatch)。
//    实际有效方案 (不依赖 platform):
//      KVO 监听 AVAudioSession.outputVolume (iOS 15 公开可靠信号) 为主通道;
//      音量贴 0/1 边界时用 Celestial AVSystemController setVolumeTo:forCategory:
//      悄悄拉回 0.05/0.95 —— 此后空音量按音量- 也产生真实音量变化 (0.05→0),
//      持续触发回调。200ms 轮询 + AVSystemController 私有通知为兜底。

#import "TSVolumeKeyMonitor.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>
#import <objc/message.h>
#import <dlfcn.h>

// ── SpringBoard 硬件按键服务 (TrollAutoScript 逆向确认) ──
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
    float _lastVolume;
    BOOL _running;
    double _warmupUntil;
    double _lastEventAt;
    id _avSystemController;
    id _messagingCenter;        // CPDistributedMessagingCenter 实例
    IOHIDEventSystemClientRef _hidClient;   // IOHIDEventSystemClient
    dispatch_queue_t _hidQueue;
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
    // iOS 15 起 AVSystemController 私有通知停发, KVO 是唯一可靠变化信号
    [session addObserver:self
              forKeyPath:@"outputVolume"
                 options:NSKeyValueObservingOptionNew
                 context:NULL];

    _lastVolume = [self _currentVolume];
    _warmupUntil = CACurrentMediaTime() + TSVolumeWarmupDuration;
    _lastEventAt = 0;

    [self _installCPDMMachListener];   // 主通道① SpringBoard 硬件按键推送
    [self _installHIDListener];        // 主通道② IOHID 物理事件
    [self _installNotificationListener];
    [self _installPollFallback];
}

- (void)stop {
    if (!_running) return;
    _running = NO;
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
    if (_messagingCenter) {
        SEL sel = NSSelectorFromString(@"unregisterMessageName:target:");
        if ([_messagingCenter respondsToSelector:sel]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(_messagingCenter, sel,
                kHardwareButtonMessageName, self);
        }
        _messagingCenter = nil;
    }
    if (_hidClient) {
        // 私有: IOHIDEventSystemClientUnregisterEventCallback + Invalidate
        void (*fnInvalidate)(IOHIDEventSystemClientRef) =
            (void (*)(IOHIDEventSystemClientRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientInvalidate");
        if (fnInvalidate) fnInvalidate(_hidClient);
        CFRelease(_hidClient);
        _hidClient = NULL;
    }
    _avSystemController = nil;
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

// ═══════════ 主通道①: SpringBoard 硬件按键事件 (CPDistributedMessagingCenter) ═══════════
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
// userInfo 字段未公开文档, 只关心"是否物理按键"——任何事件都触发弹窗。
- (NSDictionary *)handleMessageNamed:(NSString *)name withUserInfo:(NSDictionary *)userInfo {
    NSLog(@"[TSVolumeKeyMonitor] mach 硬件按键事件: %@ %@", name, userInfo ?: @"");
    [self _onKeyDetectedWithUp:YES];
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
    if (self.onVolumeKey) {
        self.onVolumeKey();
    }
}

@end
