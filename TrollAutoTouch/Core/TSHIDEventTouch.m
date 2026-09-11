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
//       以及有效 senderID (默认固定触屏值 0x8000000800, 见 _setupSenderID)。
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
//  senderID 策略 (2026-09-11 修正 "点击不生效 / 需手动触摸屏幕 / 重启多次无效"):
//    1. 默认使用固定触屏 senderID 0x8000000800 (原版 HUDServices / ZXTouch 同款伪装值):
//       立即可以直发, **不需要任何真实手指触摸**, 设备重启后依然有效;
//    2. 若历史上监听到过"真实 senderID"并已持久化, 则优先复用真实值;
//    3. 启动时仍挂一个短暂监听做自动纠错: 系统一旦产生 digitizer 事件, 若真实值与
//       当前使用值不同(固定值在本机被拒 / 保存值过期), 立即覆盖并重新持久化, 随后释放监听。
//  旧实现"设备重启(uptime 回退)即丢弃保存值、重新等真实触摸"是点击失效根因:
//  senderID 是触屏服务的稳定标识, 重启不变; 而脚本挂机时无人触摸屏幕, 该路径永远
//  拿不到值 → 直发失效 → 落到只对本 app 有效的 AX/进程内兜底 → 点击无反应。
//

#import "TSHIDEventTouch.h"
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <dlfcn.h>
#import "../Common/TSLogStore.h"   // 触摸链路诊断日志直接落盘 touch.log

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

// 默认(伪装)触屏 senderID —— 原版 TrollAutoScript HUDServices / ZXTouch 同款固定值。
// 伪装成系统触摸屏设备使 backboardd 接受直发事件; 因为它是常量, 直发链路不依赖
// 任何真实手指触摸, 也不受设备重启影响 (这是原版"随时可点"的根本原因)。
static const uint64_t kTSHIDSenderIDDefault = 0x8000000800ULL;

// 保存值的合理性判断: 真实 senderID 是 64 位设备标识(常见 0x80000008xx / 0x1000000xx,
// 量级 >= 2^32); 历史版本曾误把"开机 Unix 时间戳"(约 1.6e9~4.1e9)写进该键, 这里排除,
// 避免复用垃圾值导致事件被 backboardd 静默丢弃。
static BOOL TSHIDIsPlausibleSenderID(uint64_t v) {
    return v >= 0x100000000ULL;   // >= 2^32
}

// ---------- 诊断: senderID 来源 ----------
// "直发就绪"曾经只看 s_senderID != 0, 但真正的失败模式是:
//   * NSUserDefaults 里存着一个"别的设备/别的系统版本"监听到的 senderID(非 0 但本机无效);
//   * IOHIDEventSystemClientCreate 返回 NULL(client 都没建起来)。
// 两种情况下 statusDescription 都照样显示"直发", 而实际事件被静默丢弃、永不回退 AX,
// 表现就是"界面完全没反应且没有任何日志"。这里把来源/client/通道/下发次数全部暴露出来。
typedef NS_ENUM(NSInteger, TSSenderIDSource) {
    TSSenderIDSourceNone    = 0,
    TSSenderIDSourceDefault = 1,   // 固定伪装值
    TSSenderIDSourceSaved   = 2,   // NSUserDefaults 历史保存值
    TSSenderIDSourceProbed  = 3,   // 启动时枚举本机 HID 服务得到(真实值)
    TSSenderIDSourceLive    = 4,   // 运行中监听到真实 digitizer 事件
    TSSenderIDSourceManual  = 5,   // 脚本手动指定
};

static NSString *TSSenderIDSourceName(TSSenderIDSource s) {
    switch (s) {
        case TSSenderIDSourceDefault: return @"固定伪装值";
        case TSSenderIDSourceSaved:   return @"历史保存值";
        case TSSenderIDSourceProbed:  return @"服务枚举";
        case TSSenderIDSourceLive:    return @"运行时监听";
        case TSSenderIDSourceManual:  return @"手动指定";
        default:                      return @"无";
    }
}

static NSString *TSChannelName(TSTouchChannel c) {
    switch (c) {
        case TSTouchChannelHIDOnly: return @"仅直发";
        case TSTouchChannelAXOnly:  return @"仅本应用点击";
        default:                    return @"自动";
    }
}

// 私有属性的数值读取(Some IOHID 属性是 CFNumber, 个别是 CFString)
static long TSHIDPropToLong(CFTypeRef v) {
    if (!v) return -1;
    CFTypeID t = CFGetTypeID(v);
    if (t == CFNumberGetTypeID())  return (long)[(__bridge NSNumber *)v longValue];
    if (t == CFStringGetTypeID())  return (long)[(__bridge NSString *)v integerValue];
    return -1;
}

// 私有属性的文本读取(Product / Transport 等, 用于日志区分"哪一个是真触屏")
static NSString *TSHIDPropToString(CFTypeRef v) {
    if (!v) return @"";
    CFTypeID t = CFGetTypeID(v);
    if (t == CFStringGetTypeID())  return [(__bridge NSString *)v copy];   // copy: 与 CFRelease 解耦
    if (t == CFNumberGetTypeID())  return [(__bridge NSNumber *)v stringValue];
    if (t == CFBooleanGetTypeID()) return [(__bridge NSNumber *)v boolValue] ? @"1" : @"0";
    return @"?";
}

// digitizer 服务优先级: 触屏(usage 0x04) 最优先。
// 真机实测(iPhone / iOS 16.6): 触屏服务 PrimaryUsage = 0x04。
// 注意 0x22 并不是 kHIDUsage_Dig_TouchScreen —— 上一版按 0x22 过滤, 结果"枚举到了
// 却判定未探测到", 继续复用历史保存值, 这正是点击无效的直接原因。
//   0x04 = kHIDUsage_Dig_TouchScreen ; 0x22 仅为历史兼容(个别系统/文档写法)
static int TSDigitizerPriority(long usage) {
    if (usage == 0x04) return 0;
    if (usage == 0x22) return 1;
    return 2;
}

// 触摸链路关键节点直接写入 touch.log(与 lua_log 同一落盘通道)。
// 此前这些信息只走 NSLog, 而 NSLog 不进 touch.log —— 用户在设置页导出的"系统日志"里
// 完全看不到点击是否发生、坐标多少、走哪条通道, 导致"不点击"无法定位。
#define TS_TOUCH_LOG(fmt, ...) do { \
    [[TSLogStore shared] append:[NSString stringWithFormat:@"[touch] " fmt, ##__VA_ARGS__]]; \
} while (0)

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
// 诊断: HID client 是否创建成功(IOHIDEventSystemClientCreate 返回非空)。
// 为 NO 时直发通道实际不可用, 必须回退本应用点击, 不能只靠 senderID != 0 判断。
@property (nonatomic, assign) BOOL clientReady;
// 诊断: 直发事件已下发次数(成功调用 dispatch 的次数; 系统是否受理无法在此确认)
@property (nonatomic, assign) NSUInteger dispatchCount;
// 本机枚举到的 digitizer(触屏)服务(每项: rid/usage/product/transport), 供候选列表与日志
@property (nonatomic, strong) NSArray<NSDictionary *> *digitizerServices;
// 显式监听模式(脚本调用 watchSenderIDsForMilliseconds:): 期间不自动释放监听 client,
// 并把每次收到的 digitizer 事件 senderID 收集到 watchedSenderIDs 供脚本读取。
@property (nonatomic, assign) BOOL watchingSenderID;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *watchedSenderIDs;
- (void)_setupClient;
- (void)_setupSenderID;
- (void)_releaseSenderIDClient;
- (uint64_t)_probeSenderIDWithClient;
- (void)_armSenderIDWatcherIfNeeded;
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
// 触摸事件发送者 ID：启动即设为默认固定触屏值(或已保存的真实值), 因此恒非 0;
// 监听系统 digitizer 事件只用于自动纠错。多线程共享, 故用静态全局(ZXTouch 亦为全局)。
static uint64_t s_senderID = 0;
// 当前值来源(诊断用): 见 TSSenderIDSourceName()
static TSSenderIDSource s_senderIDSource = TSSenderIDSourceNone;
// 最近一次直发(IOHIDEventSystemClientDispatchEvent)的时间戳, 用于过滤"自身回显":
// 我们派发的事件会再次流经事件系统, 监听 client 可能收到自己刚发出去的那一颗
// (其 senderID 正是我们自己设进去的值)。若据此"纠正", 就形成自证循环 ——
// 保存值永远等于上次自己用的值, 真实值永远学不到、脏值永远洗不掉。
// 这正是日志里"直发 DOWN 之后紧跟一条运行时监听到同一 senderID"的真相。
static NSTimeInterval s_lastDispatchTime = 0;

// 监听系统触摸屏(digitizer)事件，读取真实 senderID（ZXTouch setSenderIdCallback 同款）。
// 回调通过 ScheduleWithRunLoop 调度到主 RunLoop，可安全访问 NSUserDefaults。
// 该监听只做"自动纠错": 直发已经用默认固定值就绪, 这里等一次真实触摸确认/纠正即可,
// 确认后立即释放监听 client(不会常驻)。target 传入 self (见 _setupSenderID)。
static void TSHIDSenderIDCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event) {
    if (!event) return;
    if (IOHIDEventGetType(event) != kIOHIDEventTypeDigitizer) return;
    uint64_t sid = IOHIDEventGetSenderID(event);
    if (sid == 0) return;

    // 自身回显过滤: 见 s_lastDispatchTime 说明 —— 少这道闸, 监听学到的永远是"自己上次设的值"。
    if (s_lastDispatchTime > 0) {
        NSTimeInterval dt = CFAbsoluteTimeGetCurrent() - s_lastDispatchTime;
        if (dt >= 0 && dt < 1.5) {
            static BOOL s_loggedEchoOnce = NO;
            if (!s_loggedEchoOnce) {
                s_loggedEchoOnce = YES;
                TS_TOUCH_LOG(@"监听: 忽略疑似自身回显的 digitizer 事件(senderID=0x%llX, 距上次下发 %.2fs)",
                             sid, dt);
            }
            return;
        }
    }

    TSHIDEventTouch *self = (__bridge TSHIDEventTouch *)target;

    // 显式监听(脚本 touch.watch): 只记录真实触摸的 senderID, 不改动当前生效值。
    if (self.watchingSenderID) {
        if (![self.watchedSenderIDs containsObject:@(sid)]) {
            [self.watchedSenderIDs addObject:@(sid)];
            TS_TOUCH_LOG(@"监听: 捕获真实触摸 senderID=0x%llX (累计 %lu 个不同值)",
                         sid, (unsigned long)self.watchedSenderIDs.count);
        }
        return;
    }

    if (sid != s_senderID) {
        // 真实值与当前使用值不同(当前多为默认固定值, 或保存值已过期)
        // → 真实值优先: 覆盖并持久化, 供下次启动直接复用。
        s_senderID = sid;
        s_senderIDSource = TSSenderIDSourceLive;
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setDouble:(double)sid forKey:kSenderIDDefaultsKey];
        [ud synchronize];
        TS_TOUCH_LOG(@"运行时监听到真实触摸 senderID: 0x%llX (已覆盖并持久化)", sid);
        // 通知 Lua 桥接层，让"已获取 senderID"直接显示在脚本日志中
        [[NSNotificationCenter defaultCenter] postNotificationName:TSHIDSenderIDDidChangeNotification
                                                            object:nil
                                                          userInfo:@{@"senderID": @(sid)}];
    } else {
        TS_TOUCH_LOG(@"运行时监听到真实触摸 senderID 0x%llX, 与当前使用值一致, 无需纠正", sid);
    }

    // 已确认一次真实触摸值 → 监听使命完成, 释放监听 client(省掉每次系统触摸事件的回调检查)。
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
        TS_TOUCH_LOG(@"本应用点击(AX)成功 @逻辑点(%.1f,%.1f)", (double)x, (double)y);
    } else {
        TS_TOUCH_LOG(@"本应用点击(AX)失败 @逻辑点(%.1f,%.1f) (err=%d, 目标可能无 accessibility 元素)",
                     (double)x, (double)y, (int)err);
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
        _clientReady = YES;
        TS_TOUCH_LOG(@"HID client 创建成功, 直发通道可用");
    } else {
        _clientReady = NO;
        TS_TOUCH_LOG(@"HID client 创建失败(IOHIDEventSystemClientCreate 返回 NULL): 直发不可用, 点击将回退本应用点击(AX/进程内)");
        NSLog(@"[TSHIDEventTouch] IOHIDEventSystemClientCreate 失败，请确认已用 TrollStore 安装且权限生效。");
    }
}

/// 主动枚举本机 HID 服务, 找出 digitizer(触屏)服务的 senderID —— 不需要任何真实手指触摸。
///
/// 为什么必须做这一步: 历史"保存值"完全可能来自另一台设备/另一个系统版本/非触屏服务,
/// 它非 0 却在本机无效 —— backboardd 会把事件静默丢弃, 表现为"完全点不动且无任何报错"。
/// 本机当前真实的触屏服务 registryID 才是唯一可信的值
/// (iOS 上 IOHIDEventGetSenderID 返回的正是发送该事件的 IOHIDService 的 registryID)。
- (uint64_t)_probeSenderIDWithClient {
    if (!_client) return 0;

    static CFArrayRef (*fnCopyServices)(IOHIDEventSystemClientRef) = NULL;
    static uint64_t (*fnGetRegistryID)(IOHIDServiceRef) = NULL;
    static CFTypeRef (*fnCopyProperty)(IOHIDServiceRef, CFStringRef) = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 全部走 dlsym: 私有符号缺失时不能把整个二进制拖成链接失败
        fnCopyServices  = (CFArrayRef (*)(IOHIDEventSystemClientRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCopyServices");
        fnGetRegistryID = (uint64_t (*)(IOHIDServiceRef))dlsym(RTLD_DEFAULT, "IOHIDServiceClientGetRegistryID");
        if (!fnGetRegistryID) fnGetRegistryID = (uint64_t (*)(IOHIDServiceRef))dlsym(RTLD_DEFAULT, "IOHIDServiceGetRegistryID");
        fnCopyProperty  = (CFTypeRef (*)(IOHIDServiceRef, CFStringRef))dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyProperty");
        if (!fnCopyProperty) fnCopyProperty = (CFTypeRef (*)(IOHIDServiceRef, CFStringRef))dlsym(RTLD_DEFAULT, "IOHIDServiceGetProperty");
    });
    if (!fnCopyServices) {
        TS_TOUCH_LOG(@"senderID 探测: IOHIDEventSystemClientCopyServices 不可用, 跳过探测");
        return 0;
    }

    CFArrayRef services = fnCopyServices(_client);
    if (!services) {
        TS_TOUCH_LOG(@"senderID 探测: IOHIDEventSystemClientCopyServices 返回空");
        return 0;
    }

    // 收集本机所有 digitizer 服务。实测(iPhone / iOS 16.6):
    //   触屏服务 PrimaryUsagePage=0x0D, PrimaryUsage=0x04 (= kHIDUsage_Dig_TouchScreen),
    //   且通常有两个(不同传输/不同扫描面), 需要按优先级排序逐个试。
    //   ★ 上一版的 bug: 判据写成 usage == 0x22, 真机是 0x04 →
    //     "枚举到了却判定未探测到", 于是继续复用历史保存值(日志里两句自相矛盾)。
    NSMutableArray<NSDictionary *> *collected = [NSMutableArray array];
    CFIndex n = CFArrayGetCount(services);
    for (CFIndex i = 0; i < n; i++) {
        IOHIDServiceRef svc = (IOHIDServiceRef)CFArrayGetValueAtIndex(services, i);
        if (!svc || !fnCopyProperty) continue;
        CFTypeRef p = fnCopyProperty(svc, CFSTR("PrimaryUsagePage"));
        long page = p ? TSHIDPropToLong(p) : -1;
        if (p) CFRelease(p);
        if (page != 0x0D) continue;                 // 只保留 digitizer 页
        uint64_t rid = fnGetRegistryID ? fnGetRegistryID(svc) : 0;
        CFTypeRef u = fnCopyProperty(svc, CFSTR("PrimaryUsage"));
        long usage = u ? TSHIDPropToLong(u) : -1;
        if (u) CFRelease(u);
        NSString *product = @"", *transport = @"";
        CFTypeRef pr = fnCopyProperty(svc, CFSTR("Product"));
        if (pr) { product = TSHIDPropToString(pr); CFRelease(pr); }
        CFTypeRef tr = fnCopyProperty(svc, CFSTR("Transport"));
        if (tr) { transport = TSHIDPropToString(tr); CFRelease(tr); }
        [collected addObject:@{@"rid": @(rid), @"usage": @(usage),
                               @"product": product, @"transport": transport}];
    }

    // 排序: 触屏(usage 0x04) 优先 → 0x22(历史写法) → 其他
    NSArray<NSDictionary *> *candidates =
        [collected sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            int pa = TSDigitizerPriority([a[@"usage"] longValue]);
            int pb = TSDigitizerPriority([b[@"usage"] longValue]);
            if (pa != pb) return pa < pb ? NSOrderedAscending : NSOrderedDescending;
            return NSOrderedSame;
        }];
    self.digitizerServices = candidates;

    NSMutableString *dump = [NSMutableString string];
    for (NSDictionary *d in candidates) {
        [dump appendFormat:@" [rid=0x%llX usage=0x%lX %@/%@]",
             (unsigned long long)[d[@"rid"] unsignedLongLongValue], [d[@"usage"] longValue],
             d[@"product"], d[@"transport"]];
    }
    if (candidates.count > 0) {
        TS_TOUCH_LOG(@"senderID 探测: 本机 digitizer(触屏)服务 %lu 个:%@",
                     (unsigned long)candidates.count, dump);
    } else {
        TS_TOUCH_LOG(@"senderID 探测: %ld 个 HID 服务中未发现 digitizer(page=0xD) 服务", (long)n);
    }
    CFRelease(services);
    return candidates.count > 0 ? [candidates[0][@"rid"] unsignedLongLongValue] : 0;
}

/// 候选列表: 优先用本机枚举到的 digitizer 服务; 枚举不到时退化为"保存值 + 固定伪装值"。
/// 脚本可用它逐个试, 找出本机真正被受理的那一个(见 touch_selftest.lua)。
- (NSArray<NSDictionary *> *)senderIDCandidates {
    if (self.digitizerServices.count == 0) {
        [self _probeSenderIDWithClient];   // 刷新一次(可能之前 client 还没建好)
    }
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSDictionary *d in self.digitizerServices) {
        [out addObject:@{@"value": d[@"rid"] ?: @(0), @"usage": d[@"usage"] ?: @(-1),
                         @"product": d[@"product"] ?: @"", @"transport": d[@"transport"] ?: @""}];
    }
    if (out.count == 0) {
        uint64_t saved = (uint64_t)[[NSUserDefaults standardUserDefaults] doubleForKey:kSenderIDDefaultsKey];
        if (saved != 0) {
            [out addObject:@{@"value": @(saved), @"usage": @(-1),
                             @"product": @"保存值", @"transport": @""}];
        }
        [out addObject:@{@"value": @(kTSHIDSenderIDDefault), @"usage": @(-1),
                         @"product": @"固定伪装值", @"transport": @""}];
    }
    return out;
}

- (uint64_t)useSenderIDCandidateAtIndex:(NSInteger)index {
    NSArray<NSDictionary *> *list = [self senderIDCandidates];
    if (index < 0 || index >= (NSInteger)list.count) {
        TS_TOUCH_LOG(@"候选序号 %ld 越界(共 %lu 个候选)", (long)index, (unsigned long)list.count);
        return 0;
    }
    NSDictionary *d = list[index];
    uint64_t v = [d[@"value"] unsignedLongLongValue];
    s_senderID = v;
    s_senderIDSource = TSSenderIDSourceProbed;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setDouble:(double)v forKey:kSenderIDDefaultsKey];
    [ud synchronize];
    TS_TOUCH_LOG(@"启用候选 %ld/%lu: senderID=0x%llX (usage=0x%lX %@/%@), 已持久化",
                 (long)(index + 1), (unsigned long)list.count, v,
                 [d[@"usage"] longValue], d[@"product"], d[@"transport"]);
    return v;
}

/// 确保监听 client 存在(可能已被 _releaseSenderIDClient 释放过)
- (void)_armSenderIDWatcherIfNeeded {
    if (_senderIDClient) return;
    _senderIDClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!_senderIDClient) {
        TS_TOUCH_LOG(@"监听: 创建监听 client 失败, 无法学习真实 senderID");
        return;
    }
    IOHIDEventSystemClientScheduleWithRunLoop(_senderIDClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDEventSystemClientRegisterEventCallback(_senderIDClient, TSHIDSenderIDCallback, (__bridge void *)self, NULL);
}

- (NSArray<NSNumber *> *)watchSenderIDsForMilliseconds:(NSInteger)ms {
    if (ms < 500) ms = 500;
    if (ms > 30000) ms = 30000;

    [self _armSenderIDWatcherIfNeeded];
    if (!_senderIDClient) return @[];

    self.watchedSenderIDs = [NSMutableArray array];
    self.watchingSenderID = YES;
    TS_TOUCH_LOG(@"监听: 开始 %.1f 秒真实触摸采样 —— 请用肉手在屏幕上点/滑几下(不要跑脚本点击)",
                 ms / 1000.0);

    // 当前线程是 Lua 脚本线程(后台), 睡眠期间主 RunLoop 照常派发监听回调, 不阻塞界面。
    [NSThread sleepForTimeInterval:ms / 1000.0];

    self.watchingSenderID = NO;
    NSArray<NSNumber *> *got = [self.watchedSenderIDs copy];
    self.watchedSenderIDs = nil;

    if (got.count == 0) {
        TS_TOUCH_LOG(@"监听: 采样期内没有捕获到任何真实触摸事件(手指没点? 或触摸事件不下发到本进程?)");
    } else {
        NSMutableString *s = [NSMutableString string];
        for (NSNumber *n in got) {
            [s appendFormat:@" 0x%llX", n.unsignedLongLongValue];
        }
        TS_TOUCH_LOG(@"监听: 捕获到 %lu 个真实 senderID:%@", (unsigned long)got.count, s);
    }
    return got;
}

/// 初始化 senderID。优先级(高 → 低):
///   1. 主动枚举本机 digitizer 服务的真实 senderID(免触摸, 不受历史脏数据影响);
///   2. NSUserDefaults 历史保存值;
///   3. 固定伪装值 0x8000000800(原版 HUDServices 同款)。
/// 之后仍挂一个短暂监听做自动纠错(见 TSHIDSenderIDCallback): 系统产生真实 digitizer
/// 事件后复核当前值, 确认后释放监听 client。
- (void)_setupSenderID {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    uint64_t saved = (uint64_t)[ud doubleForKey:kSenderIDDefaultsKey];
    BOOL savedPlausible = (saved != 0 && TSHIDIsPlausibleSenderID(saved));

    uint64_t probed = [self _probeSenderIDWithClient];

    if (TSHIDIsPlausibleSenderID(probed)) {
        // 探测到本机 digitizer 服务 → 用它的 registryID 作为当前值, 但【不覆盖保存值】:
        // 保存值可能是"真实手指触摸"学到的(见 touch.watch / 监听回调), 是另一个独立线索,
        // 覆盖掉就再也找不回真实值了。哪个对由 touch_selftest.lua 逐候选实测决定。
        s_senderID = probed;
        s_senderIDSource = TSSenderIDSourceProbed;
        TS_TOUCH_LOG(@"采用服务枚举 senderID: 0x%llX (保存值 0x%llX 保留备用, 未覆盖)",
                     probed, saved);
    } else if (savedPlausible) {
        // 探测不到(部分系统版本不开放服务枚举) → 退回历史保存值
        s_senderID = saved;
        s_senderIDSource = TSSenderIDSourceSaved;
        TS_TOUCH_LOG(@"未探测到 digitizer 服务, 复用已保存 senderID: 0x%llX", saved);
    } else {
        s_senderID = kTSHIDSenderIDDefault;
        s_senderIDSource = TSSenderIDSourceDefault;
        TS_TOUCH_LOG(@"无探测值也无保存值, 使用固定伪装 senderID: 0x%llX", s_senderID);
    }

    // 监听纠错: 与直发是否就绪无关, 真实值一旦可用就覆盖, 确认后释放监听 client。
    _senderIDClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!_senderIDClient) {
        TS_TOUCH_LOG(@"创建 senderID 监听 client 失败 (不影响已就绪的直发)");
        return;
    }
    IOHIDEventSystemClientScheduleWithRunLoop(_senderIDClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    // target 传 self: 回调确认真实值后经 _releaseSenderIDClient 注销回调并释放 client
    IOHIDEventSystemClientRegisterEventCallback(_senderIDClient, TSHIDSenderIDCallback, (__bridge void *)self, NULL);
    TS_TOUCH_LOG(@"直发: client=%@ senderID=0x%llX(来源=%@) 通道=%@; 后台监听真实值用于自动纠错",
                 _client ? @"OK" : @"NULL", (unsigned long long)s_senderID,
                 TSSenderIDSourceName(s_senderIDSource), TSChannelName(_channel));
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

    // ── 1. 第一通道: app 进程内 IOHID 直发 ──
    // 就绪条件 = client 成功创建 且 senderID 非 0。
    // 只判断 senderID 会把"client 为 NULL"误判成"直发就绪": 事件发不出去, 又因为这里
    // 提前 return 而永远回退不到本应用点击 —— 表现正是"界面完全没反应且无任何日志"。
    BOOL hidUsable = (_clientReady && _client != NULL && s_senderID != 0);
    if (_channel != TSTouchChannelAXOnly && hidUsable) {
        [self _dispatchIOHIDTouchAtPoint:point index:index phase:phase
                                pressure:pressure radius:radius];
        return;
    }

    // 仅直发模式: 直发不可用也不回退, 只报一次(用于判定"直发本身是否可用")
    if (_channel == TSTouchChannelHIDOnly) {
        static BOOL s_loggedHIDOnlyUnavailable = NO;
        if (!s_loggedHIDOnlyUnavailable) {
            s_loggedHIDOnlyUnavailable = YES;
            TS_TOUCH_LOG(@"仅直发模式但直发不可用(client=%@, senderID=0x%llX): 事件未下发",
                         _client ? @"OK" : @"NULL", (unsigned long long)s_senderID);
        }
        return;
    }

    // ── 2. 兜底: 本应用点击 fallback (借鉴无忧辅助触控) ──
    static BOOL s_loggedFallback = NO;
    if (!s_loggedFallback) {
        s_loggedFallback = YES;
        TS_TOUCH_LOG(@"IOHID 直发不可用(client=%@, senderID=0x%llX), 进入本应用点击模式 (AX/进程内)",
                     _client ? @"OK" : @"NULL", (unsigned long long)s_senderID);
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
            // ZXTouch generateChildEventTouchDown 同款: 按下掩码 = Range|Touch (0x3)。
            // 缺少 Range(1<<0) 位时系统不认为手指已进入"在屏"连续流, 导致后续
            // Position 型 move 事件无法关联拖动, 表现为 swipe 只有按下/抬起、
            // 效果近似"在终点位置点了一下"。tap 不受影响(无需中间 move)。
            eventMask = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch;  // 3
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
    _dispatchCount += 1;
    // 记录下发时刻: 监听回调据此过滤"自身回显"(见 s_lastDispatchTime 注释)
    s_lastDispatchTime = CFAbsoluteTimeGetCurrent();

    if (phase == TSTouchPhaseBegan) {
        // 每次按下都落盘一条: 界面"点了没反应"时, 靠这行区分
        // "脚本根本没点" 与 "点了但系统没受理"。
        TS_TOUCH_LOG(@"直发 DOWN #%u 逻辑点(%.1f,%.1f) 归一化(%.4f,%.4f) senderID=0x%llX",
                     index, (double)point.x, (double)point.y, (double)nx, (double)ny,
                     (unsigned long long)s_senderID);
    } else if (phase == TSTouchPhaseMoved) {
        // MOVE 高频触发, 落盘是同步 I/O, 高速滑动时逐条打印会拖慢触摸线程,
        // 节流为每秒最多一条 (帧率/手感不受影响)。
        static NSTimeInterval s_lastMoveLogTime = 0;
        NSTimeInterval now = CFAbsoluteTimeGetCurrent();
        if (now - s_lastMoveLogTime >= 1.0) {
            s_lastMoveLogTime = now;
            TS_TOUCH_LOG(@"直发 MOVE #%u 逻辑点(%.1f,%.1f) 归一化(%.4f,%.4f)",
                         index, (double)point.x, (double)point.y, (double)nx, (double)ny);
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
            TS_TOUCH_LOG(@"本应用点击(进程内 UIControl)成功: %@ @逻辑点(%.1f,%.1f)",
                         NSStringFromClass(candidate.class), (double)point.x, (double)point.y);
        }
    };
    if ([NSThread isMainThread]) {
        block();
    } else {
        // 异步派发 + 500ms 超时: 即使主线程繁忙也不挂起 Lua 线程(避免假死)。
        // 超时后 block 稍后照常执行并 signal, 信号量计数无害。
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            block();
            dispatch_semaphore_signal(sema);
        });
        dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC));
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

- (NSString *)senderIDSourceDescription {
    return TSSenderIDSourceName(s_senderIDSource);
}

- (uint64_t)probeSenderID {
    uint64_t probed = [self _probeSenderIDWithClient];
    if (TSHIDIsPlausibleSenderID(probed)) {
        TS_TOUCH_LOG(@"手动探测: 本机 digitizer senderID = 0x%llX (当前使用 0x%llX, 来源=%@)",
                     (unsigned long long)probed, (unsigned long long)s_senderID,
                     TSSenderIDSourceName(s_senderIDSource));
    } else {
        TS_TOUCH_LOG(@"手动探测: 未取到 digitizer senderID (当前使用 0x%llX, 来源=%@)",
                     (unsigned long long)s_senderID, TSSenderIDSourceName(s_senderIDSource));
    }
    return probed;
}

- (void)resetSenderID {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud removeObjectForKey:kSenderIDDefaultsKey];
    [ud synchronize];
    // 清掉可疑脏数据: 优先回到"本机枚举值", 枚举不到才用固定伪装值(不依赖任何真实触摸)
    uint64_t probed = [self _probeSenderIDWithClient];
    if (TSHIDIsPlausibleSenderID(probed)) {
        s_senderID = probed;
        s_senderIDSource = TSSenderIDSourceProbed;
        TS_TOUCH_LOG(@"已清除保存的 senderID, 重置为本机枚举值 0x%llX", (unsigned long long)s_senderID);
    } else {
        s_senderID = kTSHIDSenderIDDefault;
        s_senderIDSource = TSSenderIDSourceDefault;
        TS_TOUCH_LOG(@"已清除保存的 senderID, 重置为固定伪装值 0x%llX", (unsigned long long)s_senderID);
    }
}

- (uint64_t)setSenderIDValue:(uint64_t)sid {
    if (sid == 0) {
        // 恢复自动: 服务枚举 > 保存值 > 固定值
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        uint64_t saved = (uint64_t)[ud doubleForKey:kSenderIDDefaultsKey];
        uint64_t probed = [self _probeSenderIDWithClient];
        if (TSHIDIsPlausibleSenderID(probed)) {
            s_senderID = probed;
            s_senderIDSource = TSSenderIDSourceProbed;
        } else if (saved != 0 && TSHIDIsPlausibleSenderID(saved)) {
            s_senderID = saved;
            s_senderIDSource = TSSenderIDSourceSaved;
        } else {
            s_senderID = kTSHIDSenderIDDefault;
            s_senderIDSource = TSSenderIDSourceDefault;
        }
        TS_TOUCH_LOG(@"senderID 恢复自动: 0x%llX (来源=%@)",
                     (unsigned long long)s_senderID, TSSenderIDSourceName(s_senderIDSource));
        return s_senderID;
    }
    s_senderID = sid;
    s_senderIDSource = TSSenderIDSourceManual;
    TS_TOUCH_LOG(@"senderID 已手动设为 0x%llX (通道=%@)", (unsigned long long)s_senderID,
                 TSChannelName(_channel));
    return s_senderID;
}

- (NSString *)statusDescription {
    NSMutableString *s = [NSMutableString string];
    NSString *chan = TSChannelName(_channel);
    // 直发的"就绪"必须同时满足 client 创建成功 + senderID 非 0;
    // 只看 senderID 会把 client 为 NULL 的情况显示成"就绪"(事件其实发不出去)。
    if (_clientReady && _client != NULL && s_senderID != 0) {
        [s appendFormat:@", touch=直发就绪(senderID=0x%llX 来源=%@, client=OK, 通道=%@, 候选=%lu 个, 已下发=%lu 次)",
                    (unsigned long long)s_senderID, TSSenderIDSourceName(s_senderIDSource),
                    chan, (unsigned long)self.digitizerServices.count, (unsigned long)_dispatchCount];
    } else if (!_client) {
        [s appendFormat:@", touch=直发不可用(HID client 创建失败, 通道=%@)", chan];
    } else {
        [s appendFormat:@", touch=直发未就绪(senderID=0, 通道=%@)", chan];
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

/// 触摸序列的间隔等待: 纯线程睡眠(与 tap 一致)。
// HID 事件经 backboardd 异步处理, 无需等待 app 主 RunLoop;
// 此前用 CFRunLoopRunInMode 在 Lua 后台线程(该线程 RunLoop 无 source)上会立即返回,
// 导致 swipe 的 down/所有 move/up 在几微秒内连发、滑动间隔(dt)完全失效。
- (void)_yieldRunLoopForSeconds:(NSTimeInterval)seconds {
    [NSThread sleepForTimeInterval:seconds];
}

@end
