//
//  TSHIDEventTouch.m
//  TrollAutoTouch
//
//  系统级触摸 —— 双通道，对齐原版 TrollAutoScript 2.2.0 / ZXTouch 13。
//
//  关键背景（2026-08-16 逆向原版 tipa 确认）:
//    原版 TrollAutoScript 2.2.0 的触摸**不是**注入 SpringBoard 实现的:
//      - 主 app 二进制无任何 HID 注入字符串 (无 IOHIDEventSystemClientDispatchEvent),
//      - HUDServices 注册为 FrontBoard 服务域 (Info.plist BSServiceDomains:
//        com.apple.frontboard), 在**它自己的进程内**用
//        IOHIDEventSystemClientDispatchEvent 直发 IOHID 触摸事件
//        (源码即 research/zxtouch/Touch.xm, iOS 16 实测可用);
//      - 直发完全不需要 task_for_pid / mach_vm / 进程注入。
//    因此"普通 app 直发会被 backboardd 丢弃"的旧结论不成立 —— 旧测试失败
//    的真实原因是当时 senderID 未就绪 / entitlements 不齐，而非机制本身。
//
//  当前架构（本类）双通道, 依次尝试:
//    1. [第一通道] app 进程内 IOHID 直发 (ZXTouch 同款: parent digitizer +
//       child finger 事件 + IOHIDEventSetSenderID + IOHIDEventSystemClientDispatchEvent)。
//       需要 entitlements: com.apple.backboard.client +
//       com.apple.private.hid.client.event-dispatch (TrollAutoTouch.entitlements 已含)
//       以及有效 senderID (动态获取, 见 _setupSenderID)。
//    2. [兜底] 本应用点击 fallback (借鉴 无忧辅助触控 TouchSimulation 三重策略):
//       直发不可用时, 不再丢弃点击:
//         a. AX (Accessibility): AXUIElementCopyElementAtPosition + AXPress,
//            需要 com.apple.accessibility.api (已含), 对前台标准 UIKit 元素有效;
//         b. 进程内 UIControl: 主线程 hitTest + sendActionsForControlEvents。
//
//  (注: 原三级通道中的"注入 SpringBoard" (opainject + TSInjectedTouchService)
//   已确认在 iOS 15.5+ TrollStore 2.x 下因无法获得 platform 身份而不可行,
//   相关代码已整体移除, 不再尝试注入。)
//
//  senderID 动态获取: 监听系统 digitizer 事件读取真实 senderID, 持久化到
//  NSUserDefaults, 重启后复用 (ZXTouch senderid.plist 同款逻辑)。
//

#import "TSHIDEventTouch.h"
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <dlfcn.h>

// ---------- 私有类型与常量 ----------
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDService *IOHIDServiceRef;
typedef double IOHIDFloat;
typedef uint32_t IOHIDEventOptionBits;
typedef uint32_t IOHIDEventType;

#define kIOHIDEventTypeDigitizer 11

// IOHIDDigitizerEventMask 位 (来自 IOKit 私有头)
#define kIOHIDDigitizerEventRange      (1 << 0)
#define kIOHIDDigitizerEventTouch      (1 << 1)
#define kIOHIDDigitizerEventPosition   (1 << 2)
// 注: identity 位 (1<<5=0x20) 未单列宏, 它含于直发时父事件的掩码 0xb0007=0x23
//     (0x23 = 1|2|32), 见 _dispatchIOHIDTouchAtPoint:。

// IOHIDDigitizerTransducerType (iOS 13+ 私有头 IOHIDEventTypes.h)
#define kIOHIDDigitizerTransducerTypeFinger   2   // 单根手指
#define kIOHIDDigitizerTransducerTypeHand     3   // 整只手 (父事件容器)

// senderID 持久化键 (NSUserDefaults)
static NSString * const kSenderIDDefaultsKey        = @"TSHIDSenderID";
static NSString * const kSenderIDBootTimeDefaultsKey = @"TSHIDSenderIDBootTime";

// senderID 获取成功通知（userInfo 带 senderID），供 Lua 桥接层输出可见日志
NSString * const TSHIDSenderIDDidChangeNotification = @"TSHIDSenderIDDidChangeNotification";

// ---------- 类扩展（必须置于 C 回调之前） ----------
// 注意: TSHIDSenderIDCallback 等 C 静态回调会调用 [self _xxx] 私有方法，
// 编译器按源码顺序处理，若类扩展声明放在回调之后会报
// "no visible @interface ... declares the selector"（Release 下为硬错误）。
@interface TSHIDEventTouch ()
@property (nonatomic, assign) IOHIDEventSystemClientRef client;          // 事件投递 client
@property (nonatomic, assign) IOHIDEventSystemClientRef senderIDClient;  // senderID 监听 client
// 当前仍处于按下状态的手指 index 集合，及每个手指的最后位置。
// 用于 releaseAllTouches 在脚本停止时补发 touchUp，避免幽灵手指。
@property (nonatomic, strong) NSMutableSet<NSNumber *> *pressedIndexes;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSValue *> *lastPoints;
- (void)_setupClient;
- (void)_setupSenderID;
- (void)_releaseSenderIDClient;
@end

// ---------- 私有函数声明 (IOKit 私有/未公开 C 接口) ----------
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef client, CFRunLoopRef runLoop, CFStringRef mode);
extern void IOHIDEventSystemClientUnscheduleWithRunLoop(IOHIDEventSystemClientRef client, CFRunLoopRef runLoop, CFStringRef mode);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);

typedef void (*IOHIDEventSystemClientEventCallback)(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event);
extern void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef client, IOHIDEventSystemClientEventCallback callback, void *target, void *refcon);
extern void IOHIDEventSystemClientUnregisterEventCallback(IOHIDEventSystemClientRef client);

extern IOHIDEventType IOHIDEventGetType(IOHIDEventRef event);
extern uint64_t IOHIDEventGetSenderID(IOHIDEventRef event);

// iOS 13+ 新签名 (15 参):
//   (allocator, timeStamp, type, index, identity, eventMask, buttonMask,
//    x, y, z, tipPressure, barrelPressure, range, touch, options)
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t type, uint32_t index, uint32_t identity,
    uint32_t eventMask, uint32_t buttonMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat barrelPressure,
    Boolean range, Boolean touch,
    IOHIDEventOptionBits options);

// 13 参 finger 子事件 (ZXTouch 使用，无 quality 的简版)：
//   (allocator, timeStamp, index, identity, eventMask,
//    x, y, z, tipPressure, twist, range, touch, options)
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(
    CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t index, uint32_t identity, uint32_t eventMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat twist,
    Boolean range, Boolean touch, IOHIDEventOptionBits options);

// 18 参 finger 子事件 (原版 TrollAutoScript luaLib 实际使用的 iOS 15+ 完整签名)：
//   (allocator, timeStamp, index, identity, eventMask,
//    x, y, z, tipPressure, twist,
//    minorRadius, majorRadius, quality, density, irregularity,
//    range, touch, options)
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEventWithQuality(
    CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t index, uint32_t identity, uint32_t eventMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat twist,
    IOHIDFloat minorRadius, IOHIDFloat majorRadius,
    IOHIDFloat quality, IOHIDFloat density, IOHIDFloat irregularity,
    Boolean range, Boolean touch, IOHIDEventOptionBits options);

extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, IOHIDEventOptionBits options);
extern void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t senderID);

// 私有字段写入 (ZXTouch 同款)
extern void IOHIDEventSetFloatValue(IOHIDEventRef event, uint32_t field, IOHIDFloat value);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, int value);

// ---------- IOHIDEventField 数字位字段常量 (IOKit 私有头 IOHIDEventTypes.h) ----------
// 位 20-31: 类别, 低 16 位: 字段序号。digitizer 类别 = 0x000b。
#define kIOHIDEventFieldDigitizerX             0x000b0001
#define kIOHIDEventFieldDigitizerY             0x000b0002
#define kIOHIDEventFieldDigitizerZ             0x000b0003
#define kIOHIDEventFieldDigitizerButtonMask    0x000b0003
#define kIOHIDEventFieldDigitizerType          0x000b0004
#define kIOHIDEventFieldDigitizerIndex         0x000b0005
#define kIOHIDEventFieldDigitizerIdentity      0x000b0006
#define kIOHIDEventFieldDigitizerEventMask     0x000b0007
#define kIOHIDEventFieldDigitizerRange         0x000b0008
#define kIOHIDEventFieldDigitizerTouch         0x000b0009
#define kIOHIDEventFieldDigitizerPressure      0x000b000a
#define kIOHIDEventFieldDigitizerAuxiliaryPressure 0x000b000b
#define kIOHIDEventFieldDigitizerTwist         0x000b000c
#define kIOHIDEventFieldDigitizerTiltX         0x000b000d
#define kIOHIDEventFieldDigitizerTiltY         0x000b000e
#define kIOHIDEventFieldDigitizerAltitude      0x000b000f
#define kIOHIDEventFieldDigitizerAzimuth       0x000b0010
#define kIOHIDEventFieldDigitizerQuality       0x000b0011
#define kIOHIDEventFieldDigitizerDensity       0x000b0012
#define kIOHIDEventFieldDigitizerIrregularity  0x000b0013
#define kIOHIDEventFieldDigitizerMajorRadius   0x000b0014
#define kIOHIDEventFieldDigitizerMinorRadius   0x000b0015

// ---------- 静态全局 ----------
// 触摸事件发送者 ID：通过监听系统 digitizer 事件动态获取。
// 多线程共享，因此用静态全局（ZXTouch 亦为全局）。
static uint64_t s_senderID = 0;

// 当前开机时间（绝对秒）。用于判断设备是否重启过（重启后 senderID 会变化）。
static NSTimeInterval TSHIDCurrentBootTime(void) {
    return [[NSDate date] timeIntervalSince1970] - [NSProcessInfo processInfo].systemUptime;
}

// 监听系统触摸屏(digitizer)事件，读取真实 senderID（ZXTouch setSenderIdCallback 同款）。
// 回调通过 ScheduleWithRunLoop 调度到主 RunLoop，可安全访问 NSUserDefaults。
// target 传入 self (见 _setupSenderID)，拿到 senderID 后立即释放监听 client，避免常驻监听。
static void TSHIDSenderIDCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event) {
    if (!event) return;
    if (IOHIDEventGetType(event) != kIOHIDEventTypeDigitizer) return;
    if (s_senderID != 0) return;
    uint64_t sid = IOHIDEventGetSenderID(event);
    if (sid == 0) return;

    s_senderID = sid;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setDouble:(double)sid forKey:kSenderIDDefaultsKey];
    [ud setDouble:TSHIDCurrentBootTime() forKey:kSenderIDBootTimeDefaultsKey];
    [ud synchronize];
    NSLog(@"[TSHIDEventTouch] 已获取触摸发送者 senderID: 0x%llX", sid);
    // 通知 Lua 桥接层，让"已获取 senderID"直接显示在脚本日志中
    [[NSNotificationCenter defaultCenter] postNotificationName:TSHIDSenderIDDidChangeNotification
                                                        object:nil
                                                      userInfo:@{@"senderID": @(sid)}];
    // senderID 已就绪，监听不再需要 → 注销回调并释放监听 client（省掉每次系统触摸事件的回调检查）
    TSHIDEventTouch *self = (__bridge TSHIDEventTouch *)target;
    if (self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _releaseSenderIDClient];
        });
    }
}

// ---------- AX (Accessibility) 辅助功能点击: 本应用点击的核心 fallback ----------
// 借鉴自 无忧辅助触控 TouchSimulation.m (已验证"本应用点击有效")。
// 原理: AXUIElementCreateSystemWide + AXUIElementCopyElementAtPosition 在屏幕坐标
// 处找到前台 app 的可访问性元素, 再 AXUIElementPerformAction(AXPress) 触发点击。
// 需要 entitlement: com.apple.accessibility.api (TrollAutoTouch.entitlements 已含)。
// 注意: 系统级 AX 对任意前台 app 的标准 UIKit 元素都有效; 对自绘/无 accessibility
// 元素的游戏类 app 无效 —— 这正是"本应用点击有效, 跨应用(游戏)失效"的边界。
// 全部通过 dlsym 动态加载, 避免链接私有框架; 线程安全, 可在 Lua 后台线程调用。
typedef struct __AXUIElement *TSAXUIElementRef;
typedef int32_t TSAXError;
static const TSAXError TSAXErrorSuccess = 0;

static BOOL s_tsAXReady = NO;
static void *s_tsAXCreateSystemWide = NULL;
static void *s_tsAXCopyElementAtPosition = NULL;
static void *s_tsAXPerformAction = NULL;

static void TSAXSetup(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 优先查共享缓存, 再逐路径 dlopen (对齐无忧辅助的做法)
        s_tsAXCreateSystemWide      = dlsym(RTLD_DEFAULT, "AXUIElementCreateSystemWide");
        s_tsAXCopyElementAtPosition = dlsym(RTLD_DEFAULT, "AXUIElementCopyElementAtPosition");
        s_tsAXPerformAction         = dlsym(RTLD_DEFAULT, "AXUIElementPerformAction");
        if (!s_tsAXCreateSystemWide || !s_tsAXCopyElementAtPosition || !s_tsAXPerformAction) {
            const char *axPaths[] = {
                "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
                "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
                "/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility",
                NULL
            };
            for (int i = 0; axPaths[i]; i++) {
                void *h = dlopen(axPaths[i], RTLD_NOW | RTLD_LOCAL);
                if (!h) continue;
                if (!s_tsAXCreateSystemWide) s_tsAXCreateSystemWide = dlsym(h, "AXUIElementCreateSystemWide");
                if (!s_tsAXCopyElementAtPosition) s_tsAXCopyElementAtPosition = dlsym(h, "AXUIElementCopyElementAtPosition");
                if (!s_tsAXPerformAction) s_tsAXPerformAction = dlsym(h, "AXUIElementPerformAction");
                if (s_tsAXCreateSystemWide && s_tsAXCopyElementAtPosition && s_tsAXPerformAction) {
                    NSLog(@"[TSHIDEventTouch] AX API 已加载 (%s)", axPaths[i]);
                    break;
                }
            }
        }
        s_tsAXReady = (s_tsAXCreateSystemWide && s_tsAXCopyElementAtPosition && s_tsAXPerformAction);
        NSLog(@"[TSHIDEventTouch] AX 辅助功能点击 %@", s_tsAXReady ? @"可用 (权限: com.apple.accessibility.api)" : @"不可用 (符号缺失或权限不足)");
    });
}

// 在屏幕坐标 (x, y) 处执行一次 AX 点击。返回是否成功 (找到元素且动作成功)。
static BOOL TSAXTapAt(CGFloat x, CGFloat y) {
    TSAXSetup();
    if (!s_tsAXReady) return NO;
    TSAXUIElementRef (*createSysWide)(void) = (TSAXUIElementRef (*)(void))s_tsAXCreateSystemWide;
    TSAXError (*copyAt)(TSAXUIElementRef, float, float, TSAXUIElementRef *) = (TSAXError (*)(TSAXUIElementRef, float, float, TSAXUIElementRef *))s_tsAXCopyElementAtPosition;
    TSAXError (*perform)(TSAXUIElementRef, CFStringRef) = (TSAXError (*)(TSAXUIElementRef, CFStringRef))s_tsAXPerformAction;
    TSAXUIElementRef sysWide = createSysWide();
    if (!sysWide) return NO;
    TSAXUIElementRef element = NULL;
    TSAXError err = copyAt(sysWide, (float)x, (float)y, &element);
    CFRelease(sysWide);
    if (err != TSAXErrorSuccess || !element) {
        NSLog(@"[TSHIDEventTouch] AX 未找到元素 @(%.0f,%.0f) (err=%d) —— 目标可能无 accessibility 元素", x, y, (int)err);
        return NO;
    }
    err = perform(element, CFSTR("AXPress"));
    if (err != TSAXErrorSuccess) err = perform(element, CFSTR("AXPick"));
    if (err != TSAXErrorSuccess) err = perform(element, CFSTR("AXConfirm"));
    BOOL ok = (err == TSAXErrorSuccess);
    CFRelease(element);
    if (ok) {
        NSLog(@"[TSHIDEventTouch] AX 点击成功 @(%.0f,%.0f)", x, y);
    } else {
        NSLog(@"[TSHIDEventTouch] AX 点击失败 @(%.0f,%.0f) (err=%d)", x, y, (int)err);
    }
    return ok;
}

// ---------- 实现 ----------

@implementation TSHIDEventTouch

+ (instancetype)shared {
    static TSHIDEventTouch *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TSHIDEventTouch alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pressedIndexes = [NSMutableSet set];
        _lastPoints = [NSMutableDictionary dictionary];
        [self _setupClient];
        [self _setupSenderID];
    }
    return self;
}

- (void)_setupClient {
    // 创建 HID 事件系统客户端并挂到主 RunLoop，使 dispatch 的事件被 backboardd 处理。
    // 需要 entitlements: com.apple.backboard.client / com.apple.private.hid.client.event-dispatch。
    _client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (_client) {
        IOHIDEventSystemClientScheduleWithRunLoop(_client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    } else {
        NSLog(@"[TSHIDEventTouch] IOHIDEventSystemClientCreate 失败，请确认已用 TrollStore 安装且权限生效。");
    }
}

/// 初始化 senderID：优先复用已保存值；否则注册回调监听系统触摸事件动态获取。
/// 注意: 动态获取需要用户先在设备上触摸一次屏幕（或按 Home 键等产生 digitizer 事件）。
- (void)_setupSenderID {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    uint64_t saved = (uint64_t)[ud doubleForKey:kSenderIDDefaultsKey];
    NSTimeInterval savedBoot = [ud doubleForKey:kSenderIDBootTimeDefaultsKey];

    if (saved != 0 && fabs(savedBoot - TSHIDCurrentBootTime()) <= 3) {
        s_senderID = saved;
        NSLog(@"[TSHIDEventTouch] 设备未重启，复用已保存的 senderID: 0x%llX", s_senderID);
        return;
    }

    _senderIDClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!_senderIDClient) {
        NSLog(@"[TSHIDEventTouch] 创建 senderID 监听 client 失败");
        return;
    }
    IOHIDEventSystemClientScheduleWithRunLoop(_senderIDClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    // target 传 self: 回调拿到 senderID 后经 _releaseSenderIDClient 注销回调并释放 client
    IOHIDEventSystemClientRegisterEventCallback(_senderIDClient, TSHIDSenderIDCallback, (__bridge void *)self, NULL);
    NSLog(@"[TSHIDEventTouch] 正在监听系统触摸事件获取 senderID……（若迟迟不生效请先在设备上手动触摸一次屏幕）");
}

/// senderID 已获取后调用：注销回调、解除 runloop 调度并释放监听 client。
/// 避免监听 client 常驻，让每个系统触摸事件都进回调检查（省掉持续的开销）。
- (void)_releaseSenderIDClient {
    if (!_senderIDClient) return;
    IOHIDEventSystemClientUnregisterEventCallback(_senderIDClient);
    IOHIDEventSystemClientUnscheduleWithRunLoop(_senderIDClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    CFRelease(_senderIDClient);
    _senderIDClient = NULL;
    NSLog(@"[TSHIDEventTouch] senderID 已就绪, 已释放监听 client");
}

/// 当前屏幕逻辑尺寸
- (CGSize)_screenSize {
    return [UIScreen mainScreen].bounds.size;
}

/// 发送一次触摸事件。
///
/// 双通道依次尝试 (对齐原版 TrollAutoScript 2.2.0 / ZXTouch 13):
///   1. [第一通道] senderID 已就绪 → app 进程内 IOHID 直发
///      (_dispatchIOHIDTouchAtPoint:), 不需要注入, 原版 iOS16 实测可用;
///   2. [兜底] 本应用点击 fallback (AX 辅助功能 > 进程内 UIControl), 只在
///      down 时触发一次元素级点击, Moved/Ended 忽略 (无连续触摸流)。
///   (原三级通道中的"注入 SpringBoard"不可行, 已整体移除, 见文件头注释。)
- (void)_sendFingerEventAtPoint:(CGPoint)point
                          index:(uint32_t)index
                          phase:(TSTouchPhase)phase
                       pressure:(CGFloat)pressure
                         radius:(CGFloat)radius {
    // 同步按压状态，供 releaseAllTouches 清理残留触摸
    @synchronized (self) {
        if (phase == TSTouchPhaseEnded) {
            [_pressedIndexes removeObject:@(index)];
            [_lastPoints removeObjectForKey:@(index)];
        } else {
            [_pressedIndexes addObject:@(index)];
            _lastPoints[@(index)] = [NSValue valueWithCGPoint:point];
        }
    }

    // ── 1. 第一通道: app 进程内 IOHID 直发 (senderID 就绪即可) ──
    if (s_senderID != 0) {
        [self _dispatchIOHIDTouchAtPoint:point index:index phase:phase
                                pressure:pressure radius:radius];
        return;
    }

    // ── 2. 兜底: 本应用点击 fallback (借鉴无忧辅助触控) ──
    static BOOL s_loggedFallback = NO;
    if (!s_loggedFallback) {
        s_loggedFallback = YES;
        NSLog(@"[TSHIDEventTouch] IOHID 直发不可用, 进入本应用点击模式 (AX/进程内)");
    }
    if (phase == TSTouchPhaseBegan) {
        if (!TSAXTapAt(point.x, point.y)) {
            [self _localTapAtPoint:point];
        }
    }
}

/// app 进程内 IOHID 直发 (ZXTouch performTouchFromRawData 同款实现)。
/// 构造一个 parent digitizer 事件 (Hand 容器) + 一个 child finger 事件,
/// 设置 senderID 后由 IOHIDEventSystemClientDispatchEvent 直发 backboardd。
/// 坐标归一化: 输入为逻辑点坐标, 除以屏幕 bounds 得到 0~1 比例 (ZXTouch 同款)。
/// 注意: pressure/radius 为 API 兼容占位 (Lua 层 touchDownAtPoint: 签名透传),
/// 事件构造使用已验证的固定值 (tipPressure=0, radius=0.04), 暂未映射。
- (void)_dispatchIOHIDTouchAtPoint:(CGPoint)point
                             index:(uint32_t)index
                             phase:(TSTouchPhase)phase
                          pressure:(__unused CGFloat)pressure
                            radius:(__unused CGFloat)radius {
    if (!_client) {
        NSLog(@"[TSHIDEventTouch] 直发失败: HID client 未创建");
        return;
    }

    CGSize screen = [self _screenSize];
    CGFloat nx = screen.width  > 0 ? (point.x / screen.width)  : 0;
    CGFloat ny = screen.height > 0 ? (point.y / screen.height) : 0;

    // parent: Hand 容器事件 (ZXTouch 参数逐一对齐)
    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, mach_absolute_time(),
        3,      // kIOHIDDigitizerTransducerTypeHand
        99,     // 父容器固定 index (ZXTouch 同款)
        1,      // identity
        0, 0,   // eventMask, buttonMask
        0.0f, 0.0f, 0.0f, 0.0f, 0.0f,  // x, y, z, tipPressure, barrelPressure
        0, 0,   // range, touch
        0);     // options
    if (!parent) {
        NSLog(@"[TSHIDEventTouch] 直发失败: 创建 parent 事件失败");
        return;
    }
    IOHIDEventSetIntegerValue(parent, 0xb0019, 1);  // parent flags
    IOHIDEventSetIntegerValue(parent, 0x4, 1);      // parent flags

    // child: 单根手指子事件 (ZXTouch 同款 13 参)
    uint32_t eventMask;
    Boolean range, touch;
    switch (phase) {
        case TSTouchPhaseBegan:
            eventMask = kIOHIDDigitizerEventTouch;  // 2
            range = true; touch = true;
            break;
        case TSTouchPhaseMoved:
            eventMask = kIOHIDDigitizerEventPosition;  // 4
            range = true; touch = true;
            break;
        case TSTouchPhaseEnded:
        default:
            eventMask = kIOHIDDigitizerEventTouch;  // 2
            range = false; touch = false;
            break;
    }
    IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, mach_absolute_time(),
        index,          // finger index
        3,              // identity (ZXTouch 同款, 与 down/move/up 无关)
        eventMask,
        nx, ny, 0.0f,   // x, y, z
        0.0f, 0.0f,     // tipPressure, twist
        range, touch,
        0);             // options
    if (child) {
        IOHIDEventSetFloatValue(child, 0xb0014, 0.04f);  // majorRadius
        IOHIDEventSetFloatValue(child, 0xb0015, 0.04f);  // minorRadius
        IOHIDEventAppendEvent(parent, child, 0);
        CFRelease(child);
    }

    // parent 尾部字段 (ZXTouch 同款)
    IOHIDEventSetIntegerValue(parent, 0xb0007, 0x23);  // eventMask 0x23
    IOHIDEventSetIntegerValue(parent, 0xb0008, 0x1);   // range
    IOHIDEventSetIntegerValue(parent, 0xb0009, 0x1);   // touch

    // senderID 必须非 0, 否则 backboardd 丢弃 (直发前置条件已保证非 0)
    IOHIDEventSetSenderID(parent, s_senderID);
    IOHIDEventSystemClientDispatchEvent(_client, parent);
    CFRelease(parent);

    if (phase == TSTouchPhaseBegan) {
        NSLog(@"[TSHIDEventTouch] HID 直发 DOWN #%u @(%.0f,%.0f) senderID=0x%llX",
              index, point.x, point.y, (unsigned long long)s_senderID);
    } else if (phase == TSTouchPhaseMoved) {
        // MOVE 高频触发, NSLog 是同步 I/O, 高速滑动时逐条打印会拖慢触摸线程,
        // 节流为每秒最多一条 (帧率/手感不受影响)。
        static NSTimeInterval s_lastMoveLogTime = 0;
        NSTimeInterval now = CFAbsoluteTimeGetCurrent();
        if (now - s_lastMoveLogTime >= 1.0) {
            s_lastMoveLogTime = now;
            NSLog(@"[TSHIDEventTouch] HID 直发 MOVE #%u @(%.0f,%.0f)",
                  index, point.x, point.y);
        }
    }
}

/// 进程内点击 fallback: 仅对本 app 前台 UI 有效。
/// 主线程 hitTest 找到坐标处的视图, 若命中 UIControl 则触发 TouchDown + TouchUpInside。
/// AX 策略找不到元素时兜底; 必须在主线程执行, 非主线程调用会同步派发到主线程。
- (BOOL)_localTapAtPoint:(CGPoint)point {
    __block BOOL handled = NO;
    void (^block)(void) = ^{
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        if (!window) return;
        UIView *view = [window hitTest:point withEvent:nil];
        if (!view) return;
        UIView *candidate = view;
        while (candidate && ![candidate isKindOfClass:[UIControl class]]) {
            candidate = candidate.superview;
        }
        if ([candidate isKindOfClass:[UIControl class]]) {
            UIControl *ctl = (UIControl *)candidate;
            [ctl sendActionsForControlEvents:UIControlEventTouchDown];
            [ctl sendActionsForControlEvents:UIControlEventTouchUpInside];
            handled = YES;
            NSLog(@"[TSHIDEventTouch] 进程内点击成功: %@ @(%.0f,%.0f)",
                  NSStringFromClass(candidate.class), point.x, point.y);
        }
    };
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return handled;
}

#pragma mark - 公共 API

- (void)touchDownAtPoint:(CGPoint)point index:(NSInteger)index
                pressure:(CGFloat)pressure radius:(CGFloat)radius {
    [self _sendFingerEventAtPoint:point index:(uint32_t)index phase:TSTouchPhaseBegan
                         pressure:pressure radius:radius];
}

- (void)touchMoveAtPoint:(CGPoint)point index:(NSInteger)index
                pressure:(CGFloat)pressure radius:(CGFloat)radius {
    [self _sendFingerEventAtPoint:point index:(uint32_t)index phase:TSTouchPhaseMoved
                         pressure:pressure radius:radius];
}

- (void)touchUpAtPoint:(CGPoint)point index:(NSInteger)index {
    [self _sendFingerEventAtPoint:point index:(uint32_t)index phase:TSTouchPhaseEnded
                         pressure:0 radius:0];
}

// 便捷封装
- (void)touchDownAtPoint:(CGPoint)point index:(NSInteger)index {
    [self touchDownAtPoint:point index:index pressure:1.0 radius:0];
}

- (void)touchMoveAtPoint:(CGPoint)point index:(NSInteger)index {
    [self touchMoveAtPoint:point index:index pressure:1.0 radius:0];
}

- (void)tapAtPoint:(CGPoint)point duration:(NSTimeInterval)pressDuration {
    [self tapAtPoint:point duration:pressDuration pressure:1.0 radius:0];
}

- (void)swipeFromPoint:(CGPoint)from toPoint:(CGPoint)to
              duration:(NSTimeInterval)duration steps:(NSInteger)steps {
    [self swipeFromPoint:from toPoint:to duration:duration steps:steps pressure:1.0 radius:0];
}

- (void)releaseAllTouches {
    // 先快照当前按下的手指及其最后位置，再清空记录，最后逐个补发 touchUp。
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    @synchronized (self) {
        for (NSNumber *idx in [_pressedIndexes allObjects]) {
            NSValue *v = _lastPoints[idx];
            CGPoint p = v ? v.CGPointValue : CGPointZero;
            [items addObject:@{
                @"index": idx,
                @"point": [NSValue valueWithCGPoint:p],
            }];
        }
        [_pressedIndexes removeAllObjects];
        [_lastPoints removeAllObjects];
    }
    for (NSDictionary *item in items) {
        NSNumber *idx = item[@"index"];
        NSValue *pv = item[@"point"];
        [self _sendFingerEventAtPoint:pv.CGPointValue
                                index:idx.unsignedIntValue
                                phase:TSTouchPhaseEnded
                             pressure:0 radius:0];
    }
}

- (uint64_t)senderID {
    return s_senderID;
}

- (NSString *)statusDescription {
    NSMutableString *s = [NSMutableString string];
    // 第一通道: app 进程内 IOHID 直发 (senderID 就绪即可)
    if (s_senderID != 0) {
        [s appendFormat:@", touch=直发(senderID=0x%llX)", (unsigned long long)s_senderID];
    } else {
        [s appendString:@", touch=直发未就绪(需手动触摸一次屏幕)"];
    }
    // 本应用点击 fallback 状态 (AX 辅助功能 / 进程内 UIControl)
    TSAXSetup();
    if (s_tsAXReady) {
        [s appendString:@", 本应用点击=AX可用"];
    } else {
        [s appendString:@", 本应用点击=AX不可用"];
    }
    return s;
}

- (void)tapAtPoint:(CGPoint)point duration:(NSTimeInterval)pressDuration
          pressure:(CGFloat)pressure radius:(CGFloat)radius {
    [self touchDownAtPoint:point index:0 pressure:pressure radius:radius];
    // 纯 sleep 保证 down/up 有足够时间间隔（HID 事件经 backboardd 异步处理）。
    // 此前在 Lua 后台线程调用 _yieldRunLoopForSeconds 无意义，且 down/up 间隔仅 20ms，
    // backboardd 可能把两者合并处理导致点击无效。
    [NSThread sleepForTimeInterval:MAX(pressDuration, 0.05)];
    [self touchUpAtPoint:point index:0];
}

- (void)swipeFromPoint:(CGPoint)from toPoint:(CGPoint)to
              duration:(NSTimeInterval)duration steps:(NSInteger)steps
              pressure:(CGFloat)pressure radius:(CGFloat)radius {
    if (steps < 2) { steps = 2; }
    NSTimeInterval dt = duration / (NSTimeInterval)steps;

    [self touchDownAtPoint:from index:0 pressure:pressure radius:radius];
    [self _yieldRunLoopForSeconds:dt];

    for (NSInteger i = 1; i < steps; i++) {
        CGFloat t = (CGFloat)i / (CGFloat)steps;
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * t,
                                from.y + (to.y - from.y) * t);
        [self touchMoveAtPoint:p index:0 pressure:pressure radius:radius];
        [self _yieldRunLoopForSeconds:dt];
    }
    [self touchMoveAtPoint:to index:0 pressure:pressure radius:radius];
    [self _yieldRunLoopForSeconds:dt];
    [self touchUpAtPoint:to index:0];
}

/// 让主 RunLoop 跑一会儿，保证 HID 事件被 backboardd 即时处理
- (void)_yieldRunLoopForSeconds:(NSTimeInterval)seconds {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}

@end
