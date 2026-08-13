//
//  TSHIDEventTouch.m
//  TrollAutoTouch
//
//  IOHIDEvent 系统级触摸注入实现（复刻 ZXTouch pccontrol/Touch.xm 权威写法）。
//
//  逆向依据: 原 TrollAutoScript 的 luaLib 二进制中提取到如下触摸注入符号:
//    _IOHIDEventSystemClientCreate
//    _IOHIDEventSystemClientDispatchEvent
//    _IOHIDEventSystemClientScheduleWithRunLoop
//    _IOHIDEventSystemClientRegisterEventCallback   (senderID 动态获取)
//    _IOHIDEventCreateDigitizerEvent
//    _IOHIDEventCreateDigitizerFingerEventWithQuality   (iOS 15+ 完整 18 参签名)
//    _IOHIDEventAppendEvent
//    _IOHIDEventSetSenderID
//    _IOHIDEventSetFloatValue / SetIntegerValue      (私有字段显式写入)
//
//  关键要点（依据 ZXTouch Touch.xm + 私有头 IOHIDEvent.h）:
//  1. iOS 13+ 签名：IOHIDEventCreateDigitizerEvent 为 15 参
//     (allocator, timeStamp, type, index, identity, eventMask, buttonMask,
//      x, y, z, tipPressure, barrelPressure, range, touch, options)
//     旧签名(≤iOS12, 14参)是 (allocator, timeStamp, eventMask, eventType, ...)。
//  2. senderID 必须动态获取：注册事件回调读取系统真实触摸屏事件的 senderID
//     (IOHIDEventGetSenderID)。硬编码 0x8000000800 在 iOS 13+ 会被 backboardd
//     当作非法发送者丢弃 —— 这就是"能找色但点击无效"的真正根因。
//     获取到的 senderID 持久化保存，设备未重启时直接复用。
//  3. 子事件用 18 参 IOHIDEventCreateDigitizerFingerEventWithQuality（原版 luaLib
//     实际使用的 iOS 15+ 完整签名）：identity 固定 3；Began mask=Range|Touch(3)/
//     range=1/touch=1；Moved mask=Position(4)/range=1/touch=1；Ended mask=Touch(2)/
//     range=0/touch=0。quality=1 density=1 irregularity=1 minor/majorRadius=5mm
//     tipPressure=0。
//  4. 父事件补 flags: 0xb0019=1、0x4=1；发送前写 0xb0007=0x23、0xb0008=1、0xb0009=1。
//  5. 坐标按屏幕 bounds 归一化到 0.0~1.0；触摸半径用私有字段 0xb0014/0xb0015。
//
//  需要 entitlements: com.apple.private.hid.client.event-dispatch / event-monitor、
//  com.apple.backboard.client 等（TrollStore 签名后生效）。
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

/// 构造并发送一次手指 HID 事件。
/// pressure=压力(0~1 通常), radius=触摸半径(毫米, 0 用默认 4.5)。
- (void)_sendFingerEventAtPoint:(CGPoint)point
                          index:(uint32_t)index
                          phase:(TSTouchPhase)phase
                       pressure:(CGFloat)pressure
                         radius:(CGFloat)radius {
    if (!_client) { return; }

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

    // 坐标：HID digitizer 事件使用 0.0~1.0 归一化坐标（逻辑点除以屏幕 bounds 宽高）。
    CGSize screenBounds = [UIScreen mainScreen].bounds.size;
    IOHIDFloat x = (screenBounds.width  > 0) ? (IOHIDFloat)(point.x / screenBounds.width)  : 0;
    IOHIDFloat y = (screenBounds.height > 0) ? (IOHIDFloat)(point.y / screenBounds.height) : 0;

    // ZXTouch 阶段掩码: Began mask=3(Range|Touch) range=1 touch=1;
    //                   Moved mask=4(Position)    range=1 touch=1;
    //                   Ended mask=2(Touch)       range=0 touch=0。
    Boolean fingerRange, fingerTouch;
    uint32_t fingerMask;
    switch (phase) {
        case TSTouchPhaseBegan:
            fingerRange = true; fingerTouch = true;
            fingerMask = kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange;   // 3
            break;
        case TSTouchPhaseMoved:
            fingerRange = true; fingerTouch = true;
            fingerMask = kIOHIDDigitizerEventPosition;                            // 4
            break;
        case TSTouchPhaseEnded:
        default:
            fingerRange = false; fingerTouch = false;
            fingerMask = kIOHIDDigitizerEventTouch;                               // 2
            break;
    }

    uint64_t timeStamp = mach_absolute_time();
    // tipPressure: 普通设备(无 3D Touch)恒为 0 —— 原版 luaLib / ZXTouch 均传 0。
    // 写入非零压力可能被 backboardd 当作异常压力事件丢弃。
    float p = 0.0f;
    float q = 1.0f;                       // quality
    float d = 1.0f;                       // density
    float irr = 1.0f;                     // irregularity
    float r = (radius > 0) ? (float)radius : 5.0f;  // major/minor radius (mm, 原版默认 5.0)
    float twist = 0.0f;
    float z = 0.0f;

    // 1) 父事件: 整只手(digitizer)事件容器 —— iOS 13+ 新签名(15 参)。
    //    ZXTouch: type=Hand(3) 作父容器、index=99、identity=1、eventMask=0、buttonMask=0；
    //    坐标与掩码交给子手指事件，父事件随后显式补写关键字段。
    IOHIDEventRef digitizer = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, timeStamp,
        /*type*/       kIOHIDDigitizerTransducerTypeHand,   // Hand=3 父容器
        /*index*/      99,
        /*identity*/   1,
        /*eventMask*/  0,
        /*buttonMask*/ 0,
        /*x,y,z*/      0, 0, 0,
        /*tip,barrel*/ 0, 0,
        /*range,touch*/0, 0,
        /*options*/    0);
    if (!digitizer) { return; }

    // ZXTouch: 父事件 flags 需补写 0xb0019=1、0x4=1
    IOHIDEventSetIntegerValue(digitizer, 0xb0019, 1);
    IOHIDEventSetIntegerValue(digitizer, 0x4, 1);

    // 2) 子事件: 单根手指 —— 原版 luaLib 实际使用 WithQuality 18 参版本:
    //    (allocator, timeStamp, index, identity, eventMask,
    //     x, y, z, tipPressure, twist, minorRadius, majorRadius,
    //     quality, density, irregularity, range, touch, options)
    //    quality=1 density=1 irregularity=1 radius=5mm tipPressure=0, 对齐原版。
    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEventWithQuality(
        kCFAllocatorDefault, timeStamp,
        index,      // 手指索引
        3,          // identity 固定 3 (ZXTouch/原版)
        fingerMask,
        x, y, z,
        p, twist,   // tipPressure=0
        r, r,       // minorRadius, majorRadius
        q, d, irr,  // quality, density, irregularity
        fingerRange, fingerTouch, 0);

    // 3) 触摸半径字段（ZXTouch 同款：仅显式写 0xb0014/0xb0015，
    //    其余字段在 WithQuality 创建时已带正确值，无需重复覆盖）
    if (finger) {
        IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerMajorRadius, r);
        IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerMinorRadius, r);
        IOHIDEventAppendEvent(digitizer, finger, 0);
        CFRelease(finger);
    }

    // 父事件显式写入关键字段 (ZXTouch 固定值: EventMask=0x23, Range=1, Touch=1)
    IOHIDEventSetIntegerValue(digitizer, kIOHIDEventFieldDigitizerEventMask,
                              kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventIdentity);
    IOHIDEventSetIntegerValue(digitizer, kIOHIDEventFieldDigitizerRange, 1);
    IOHIDEventSetIntegerValue(digitizer, kIOHIDEventFieldDigitizerTouch, 1);

    // 4) 标记发送者: 必须使用系统真实 senderID，否则 iOS 13+ backboardd 会丢弃事件。
    if (s_senderID != 0) {
        IOHIDEventSetSenderID(digitizer, s_senderID);
    } else {
        NSLog(@"[TSHIDEventTouch] 警告: senderID 未就绪(0)，使用兜底值 0x%llX 尝试发送，"
              @"若点击仍无效请先在设备上手动触摸一次屏幕。", (unsigned long long)kTouchSenderIDFallback);
        IOHIDEventSetSenderID(digitizer, kTouchSenderIDFallback);
    }

    // 5) 投递
    IOHIDEventSystemClientDispatchEvent(_client, digitizer);
    CFRelease(digitizer);
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
    if (_client) {
        [s appendString:@"client=OK"];
    } else {
        [s appendString:@"client=FAIL(创建失败, entitlement 可能未生效)"];
    }
    if (s_senderID != 0) {
        [s appendFormat:@", senderID=0x%llX(就绪)", (unsigned long long)s_senderID];
    } else {
        [s appendString:@", senderID=0(未就绪! 请先手动触摸一次屏幕, 再重跑脚本)"];
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
