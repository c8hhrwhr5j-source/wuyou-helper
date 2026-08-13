//
//  TSHIDEventTouch.m
//  TrollAutoTouch
//
//  IOHIDEvent 系统级触摸注入实现。
//
//  逆向依据: 原 TrollAutoScript 的 luaLib 二进制中提取到如下触摸注入符号:
//    _IOHIDEventSystemClientCreate
//    _IOHIDEventSystemClientDispatchEvent
//    _IOHIDEventSystemClientScheduleWithRunLoop
//    _IOHIDEventCreateDigitizerEvent
//    _IOHIDEventCreateDigitizerFingerEventWithQuality
//    _IOHIDEventAppendEvent
//    _IOHIDEventSetSenderID
//    _IOHIDEventSetFloatValue              (压力/半径 显式写入)
//    _IOHIDEventSetFloatValueWithOptions
//    _IOHIDEventSetIntegerValueWithOptions (eventMask/range/touch 显式写入)
//  原版触摸方法: luaTouch - touchWithFingerPosX:posY:finger:pressure:
//    + initWithPoint:press:radius: / setPressure: (压力、触摸半径必设)。
//  本实现复刻该路径, 且坐标按 HID digitizer 要求归一化到 0.0~1.0。
//
//  注意: 这些是 IOKit 私有/未公开 C 接口，其参数签名随 iOS 版本略有差异。
//  下面采用的声明是 ZXTouch / SimulateTouch 等开源项目长期验证过的版本，
//  在 iOS 13~16 (越狱/TrollStore 环境) 上普遍可用。如遇新版本签名不符，
//  请按头文件 <IOKit/hid/IOHIDEvent.h> (macOS SDK) 校正。
//

#import "TSHIDEventTouch.h"
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <dlfcn.h>

// ---------- 私有类型与常量 ----------
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef double IOHIDFloat;
typedef uint32_t IOHIDEventOptionBits;

// IOHIDDigitizerEventMask 位 (来自 IOKit 私有头)
#define kIOHIDDigitizerEventRange      (1 << 0)
#define kIOHIDDigitizerEventTouch      (1 << 1)
#define kIOHIDDigitizerEventPosition   (1 << 2)

// IOHIDEventType 枚举 (来自 IOKit 私有头 IOHIDEventTypes.h):
//   IOHIDEventCreateDigitizerEvent 的第 3 个参数 "type" 必须是事件类型
//   kIOHIDEventTypeDigitizer (=11)，而不是 digitizer 事件掩码位。
//   若误传 kIOHIDDigitizerEventTouch(=2)，事件会被标记成 kIOHIDEventTypeButton，
//   backboardd 不把它当触摸处理，点击完全不生效 (iOS 13~16 实测)。
#define kIOHIDEventTypeDigitizer       11

// 模仿触摸屏上报者的 senderID (ZXTouch 常用值，使事件被识别为真实触屏)
#define kTouchSenderID  0x8000000800ULL

// ---------- 私有函数声明 ----------
// 这些符号来自 IOKit.framework (CoreFoundation 的一部分，随系统存在)。
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef client, CFRunLoopRef runLoop, CFStringRef mode);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);

extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t type, uint32_t subtype,
    uint32_t index, uint32_t identity, uint32_t mask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure,
    Boolean range, Boolean touch,
    IOHIDEventOptionBits options);

extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEventWithQuality(
    CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t index, uint32_t identity, uint32_t mask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist,
    IOHIDFloat quality, IOHIDFloat density,
    Boolean range, Boolean touch);

extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, IOHIDEventOptionBits options);
extern void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t senderID);

// 原版 luaLib 额外链接的字段设置接口 —— 压力/质量/密度/半径 必须显式写入，
// 否则 backboardd 会因缺省字段把事件当作无效触摸丢弃 (逆向结论)。
extern void IOHIDEventSetFloatValue(IOHIDEventRef event, uint32_t field, IOHIDFloat value);
extern void IOHIDEventSetFloatValueWithOptions(IOHIDEventRef event, uint32_t field, IOHIDFloat value, IOHIDEventOptionBits options);
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

// ---------- 实现 ----------

@interface TSHIDEventTouch ()
@property (nonatomic, assign) IOHIDEventSystemClientRef client;
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
    }
    return self;
}

- (void)_setupClient {
    // 创建 HID 事件系统客户端并挂到主 RunLoop，使 dispatch 的事件被 backboardd 处理。
    // 需要 entitlements: com.apple.backboard.client / task_for_pid-allow 等(TrollStore 签名后生效)。
    _client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (_client) {
        IOHIDEventSystemClientScheduleWithRunLoop(_client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    } else {
        NSLog(@"[TSHIDEventTouch] IOHIDEventSystemClientCreate 失败，请确认已用 TrollStore 安装且权限生效。");
    }
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

    // 坐标：HID digitizer 事件使用 0.0~1.0 归一化坐标 (逆向 iosre/SimulateTouch 确认)，
    // 逻辑点必须先除以屏幕 bounds 宽高，否则 backboardd 会把事件丢弃/坐标溢出。
    CGSize screenBounds = [UIScreen mainScreen].bounds.size;
    IOHIDFloat x = (screenBounds.width  > 0) ? (IOHIDFloat)(point.x / screenBounds.width)  : 0;
    IOHIDFloat y = (screenBounds.height > 0) ? (IOHIDFloat)(point.y / screenBounds.height) : 0;

    Boolean range, touch;
    uint32_t mask;
    switch (phase) {
        case TSTouchPhaseBegan:
            range = true;  touch = true;  mask = kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange;
            break;
        case TSTouchPhaseMoved:
            range = true;  touch = true;  mask = kIOHIDDigitizerEventPosition;
            break;
        case TSTouchPhaseEnded:
        default:
            range = false; touch = false; mask = kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange;
            break;
    }

    uint64_t timeStamp = mach_absolute_time();
    float p = (phase == TSTouchPhaseEnded) ? 0.0f : (float)pressure;
    float q = 1.0f;                       // quality
    float d = 1.0f;                       // density
    float r = (radius > 0) ? (float)radius : 4.5f;  // major/minor radius (mm)
    float twist = 0.0f;
    float z = 0.0f;

    // 1) 父事件: 数位板(digitizer)事件
    //    注意: type 参数必须是 kIOHIDEventTypeDigitizer(11) 事件类型，
    //    而不是 kIOHIDDigitizerEventTouch(2) 掩码位 (见文件头注释)。
    IOHIDEventRef digitizer = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, timeStamp,
        /*type*/     kIOHIDEventTypeDigitizer,
        /*subtype*/  0,
        /*index*/    index,
        /*identity*/ index,
        /*mask*/     mask,
        x, y, z, p,
        range, touch, 0);
    if (!digitizer) { return; }

    // 2) 子事件: 单根手指
    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEventWithQuality(
        kCFAllocatorDefault, timeStamp,
        index, index, mask,
        x, y, z, p, twist,
        q, d,
        range, touch);

    // 3) 显式写入关键字段 (逆向原版 luaLib 确认的缺失环节):
    //    backboardd 根据这些字段判定触摸有效性，缺省时事件会被丢弃。
    if (finger) {
        IOHIDEventSetFloatValueWithOptions(finger, kIOHIDEventFieldDigitizerPressure,  p, 0);
        IOHIDEventSetFloatValueWithOptions(finger, kIOHIDEventFieldDigitizerQuality,     q, 0);
        IOHIDEventSetFloatValueWithOptions(finger, kIOHIDEventFieldDigitizerDensity,     d, 0);
        IOHIDEventSetFloatValueWithOptions(finger, kIOHIDEventFieldDigitizerMajorRadius, r, 0);
        IOHIDEventSetFloatValueWithOptions(finger, kIOHIDEventFieldDigitizerMinorRadius, r, 0);
        IOHIDEventSetIntegerValueWithOptions(finger, kIOHIDEventFieldDigitizerIndex,    index, 0);
        IOHIDEventSetIntegerValueWithOptions(finger, kIOHIDEventFieldDigitizerIdentity, index, 0);
        IOHIDEventSetIntegerValueWithOptions(finger, kIOHIDEventFieldDigitizerEventMask, mask, 0);
        IOHIDEventSetIntegerValueWithOptions(finger, kIOHIDEventFieldDigitizerRange, range ? 1 : 0, 0);
        IOHIDEventSetIntegerValueWithOptions(finger, kIOHIDEventFieldDigitizerTouch, touch ? 1 : 0, 0);
        IOHIDEventAppendEvent(digitizer, finger, 0);
        CFRelease(finger);
    }

    // 父事件同样显式设置关键字段 (ZXTouch / SimulateTouch 均如此)
    IOHIDEventSetIntegerValueWithOptions(digitizer, kIOHIDEventFieldDigitizerEventMask, mask, 0);
    IOHIDEventSetIntegerValueWithOptions(digitizer, kIOHIDEventFieldDigitizerRange, range ? 1 : 0, 0);
    IOHIDEventSetIntegerValueWithOptions(digitizer, kIOHIDEventFieldDigitizerTouch, touch ? 1 : 0, 0);

    // 4) 标记发送者为触摸屏，避免被丢弃
    IOHIDEventSetSenderID(digitizer, kTouchSenderID);

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

- (void)tapAtPoint:(CGPoint)point duration:(NSTimeInterval)pressDuration
          pressure:(CGFloat)pressure radius:(CGFloat)radius {
    [self touchDownAtPoint:point index:0 pressure:pressure radius:radius];
    // 让出 RunLoop 让 backboardd 处理 down，再 up
    [NSThread sleepForTimeInterval:MAX(pressDuration, 0.02)];
    [self _yieldRunLoopForSeconds:MAX(pressDuration, 0.02)];
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
