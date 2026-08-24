//
//  TSVolumeKeyMonitor.m
//  TrollAutoTouch
//
//  App 进程内音量键识别 (TrollAutoScript 同款方案):
//    主通道① CPDistributedMessagingCenter.framework (系统私有框架, 运行时 dlopen):
//      连接 SpringBoard 的硬件按键服务 (com.apple.springboard), 注册
//      com.apple.springboard.hardware-button-service.event-consumption 消息,
//      发送订阅请求激活, SpringBoard 把"物理按键事件"推送到本进程 ——
//      与系统音量值是否变化完全解耦, 音量到 0/满格时按对应键照收。
//    主通道② IOHIDEventSystemClient (IOKit 私有 API, 运行时 dlopen):
//      直接订阅系统 HID 事件, 从物理层面拿音量键, 不依赖 SpringBoard 派发。
//    兜底通道  AVSystemController 通知 + 200ms 轮询。
//
//  entitlement 已在 TrollAutoTouch.entitlements 声明 (platform-application /
//  com.apple.springboard.hardware-button-service.event-consumption /
//  com.apple.private.hid.client.event-monitor / iokit-user-client-class)。

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
    NSLog(@"[TSVolumeKeyMonitor] 音量键按下 (%@)", up ? @"+" : @"-");
    if (self.onVolumeKey) {
        self.onVolumeKey();
    }
}

@end
