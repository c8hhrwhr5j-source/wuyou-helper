//
//  TSHIDEventTouch.m
//  TrollAutoTouch
//
//  系统级触摸注入（注入式架构，对齐原版 TrollAutoScript / ZXTouch 13）。
//
//  背景:
//    backboardd 只接受来自 SpringBoard 等受信 HID 服务进程的 IOHID 触摸事件。
//    普通 app 进程即使拥有 event-dispatch entitlement，IOHIDEventSystemClientDispatchEvent
//    发出的事件也会被 backboardd 丢弃。已实测验证: finger 事件用 13 参
//    (ZXTouch) 与 18 参 WithQuality (原版 luaLib) 两种签名、radius/quality/
//    tipPressure 参数完全对齐后，app 进程直接发送依旧"找色成功但点击无效"。
//
//  当前架构（与原版 TrollAutoScript 2.2.0 相同）:
//    1. app 启动/首次触摸时，用 opainject (OpenInject, PAC bypass) 把
//       TSInjectedTouchService.dylib 注入 SpringBoard 进程;
//    2. 该 dylib 在 SpringBoard 进程内启动 TCP server (127.0.0.1:23333) 并
//       用 IOHID 事件系统向 backboardd 注入触摸;
//    3. 本类通过 TSInjectedTouchClient 走 socket 把触摸指令发往 SpringBoard。
//
//  senderID 动态获取机制保留（信息展示），真正发送端的 senderID 由
//  TSInjectedTouchService.dylib 在 SpringBoard 进程内自行获取。
//

#import "TSHIDEventTouch.h"
#import "TSInjectedTouchClient.h"
#import "TSInjectedTouchService.h"
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
#define kIOHIDDigitizerEventIdentity   (1 << 5)   // 0x20, ZXTouch 父事件掩码含此位

// IOHIDDigitizerTransducerType (iOS 13+ 私有头 IOHIDEventTypes.h)
#define kIOHIDDigitizerTransducerTypeFinger   2   // 单根手指
#define kIOHIDDigitizerTransducerTypeHand     3   // 整只手 (父事件容器)

// 未获取到真实 senderID 时的兜底值（iOS 13 以下常用；iOS 13+ 大概率被丢弃，
// 仅作 fallback，正式值来自系统事件回调）。
#define kTouchSenderIDFallback 0x8000000800ULL

// senderID 持久化键 (NSUserDefaults)
static NSString * const kSenderIDDefaultsKey        = @"TSHIDSenderID";
static NSString * const kSenderIDBootTimeDefaultsKey = @"TSHIDSenderIDBootTime";

// senderID 获取成功通知（userInfo 带 senderID），供 Lua 桥接层输出可见日志
NSString * const TSHIDSenderIDDidChangeNotification = @"TSHIDSenderIDDidChangeNotification";

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
extern void IOHIDEventSetFloatValueWithOptions(IOHIDEventRef event, uint32_t field, IOHIDFloat value, IOHIDEventOptionBits options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, int value);
extern void IOHIDEventSetIntegerValueWithOptions(IOHIDEventRef event, uint32_t field, int64_t value, IOHIDEventOptionBits options);

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
}

// ---------- 实现 ----------

@interface TSHIDEventTouch ()
@property (nonatomic, assign) IOHIDEventSystemClientRef client;          // 事件投递 client
@property (nonatomic, assign) IOHIDEventSystemClientRef senderIDClient;  // senderID 监听 client
// 当前仍处于按下状态的手指 index 集合，及每个手指的最后位置。
// 用于 releaseAllTouches 在脚本停止时补发 touchUp，避免幽灵手指。
@property (nonatomic, strong) NSMutableSet<NSNumber *> *pressedIndexes;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSValue *> *lastPoints;
@end

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
    IOHIDEventSystemClientRegisterEventCallback(_senderIDClient, TSHIDSenderIDCallback, NULL, NULL);
    NSLog(@"[TSHIDEventTouch] 正在监听系统触摸事件获取 senderID……（若迟迟不生效请先在设备上手动触摸一次屏幕）");
}

/// 当前屏幕逻辑尺寸
- (CGSize)_screenSize {
    return [UIScreen mainScreen].bounds.size;
}

/// 发送一次触摸事件。
///
/// 触摸不再由本 app 进程直接构造 IOHID 事件 dispatch（实测 13 参/18 参 finger 事件、
/// senderID 动态获取、radius/quality/tipPressure 等参数完全对齐 ZXTouch 与原版
/// luaLib 后依旧无效），而是:
///   1. 启动时用 opainject 把 TSInjectedTouchService.dylib 注入 SpringBoard 进程;
///   2. 本方法把触摸指令通过 TCP socket (127.0.0.1:23333) 发往 SpringBoard;
///   3. 服务端在 SpringBoard 进程内用 IOHID 向 backboardd 注入事件。
///
/// backboardd 只接受来自 SpringBoard 等受信 HID 服务进程的事件 —— 这是
/// "找色成功但点击无效" 的根因。
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

    if (![[TSInjectedTouchClient shared] ensureInjected]) {
        static BOOL s_loggedInjectFail = NO;
        if (!s_loggedInjectFail) {
            s_loggedInjectFail = YES;
            NSLog(@"[TSHIDEventTouch] 注入 SpringBoard 失败: %@",
                  [[TSInjectedTouchClient shared] statusDescription]);
        }
        return;
    }

    // Lua 层已是逻辑点坐标; TSInjectedTouchClient 内部会按屏幕 bounds 归一化为 0~1。
    uint8_t type;
    switch (phase) {
        case TSTouchPhaseBegan: type = TS_TOUCH_TYPE_DOWN; break;
        case TSTouchPhaseMoved: type = TS_TOUCH_TYPE_MOVE; break;
        case TSTouchPhaseEnded:
        default:                type = TS_TOUCH_TYPE_UP;   break;
    }
    [[TSInjectedTouchClient shared] sendTouchType:type index:(uint8_t)index point:point];
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
    // 触摸通道: 注入 SpringBoard 的 socket 服务
    [s appendFormat:@"touch=%@", [[TSInjectedTouchClient shared] statusDescription]];
    // senderID 状态 (仅信息展示, 发送已不依赖它)
    if (s_senderID != 0) {
        [s appendFormat:@", senderID=0x%llX(就绪)", (unsigned long long)s_senderID];
    } else {
        [s appendString:@", senderID=0(可先在设备上手动触摸一次屏幕)"];
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
