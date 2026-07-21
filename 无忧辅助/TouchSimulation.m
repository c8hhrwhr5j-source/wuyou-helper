//
//  TouchSimulation.m
//  无忧辅助 - 通过 IOHIDEvent 进行触控模拟（与触控精灵一致）
//

#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach_time.h>
#import <stdlib.h>
#import <math.h>
#import <unistd.h>

// ---- IOHIDEvent 私有声明 ----
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

// Digitizer 事件子类型
enum {
    kIOHIDDigitizerEventRange       = 0x00,
    kIOHIDDigitizerEventTouch       = 0x01,
    kIOHIDDigitizerEventAttribute   = 0x02,
};

// Digitizer transducer flags
enum {
    kIOHIDDigitizerTransducerTouch       = (1 << 0),
    kIOHIDDigitizerTransducerInvert      = (1 << 1),
    kIOHIDDigitizerTransducerIdentity    = (1 << 2),
    kIOHIDDigitizerTransducerRange       = (1 << 3),
};

// 触摸阶段（用作 buttonMask）
enum {
    kIOHIDDigitizerTransducerFingerPhaseBegan      = 0x01,
    kIOHIDDigitizerTransducerFingerPhaseMoved       = 0x02,
    kIOHIDDigitizerTransducerFingerPhaseStationary  = 0x04,
    kIOHIDDigitizerTransducerFingerPhaseEnded       = 0x08,
};

// Digitizer event field IDs for IOHIDEventSetFloatValue
enum {
    kIOHIDDigitizerEventFieldDidNotUpdateMask       = 0x00000001,
    kIOHIDDigitizerEventFieldDigitizerX             = 0x00100001,
    kIOHIDDigitizerEventFieldDigitizerY             = 0x00100002,
    kIOHIDDigitizerEventFieldDigitizerZ             = 0x00100003,
    kIOHIDDigitizerEventFieldDigitizerButtonMask    = 0x00100004,
    kIOHIDDigitizerEventFieldDigitizerRange         = 0x00100006,
    kIOHIDDigitizerEventFieldDigitizerTouch         = 0x00100007,
    kIOHIDDigitizerEventFieldDigitizerPressure      = 0x00100009,
    kIOHIDDigitizerEventFieldDigitizerAuxiliaryPressure = 0x0010000A,
    kIOHIDDigitizerEventFieldDigitizerTwist          = 0x0010000B,
    kIOHIDDigitizerEventFieldDigitizerCollection     = 0x00100020,
    kIOHIDDigitizerEventFieldDigitizerChildEventMask  = 0x00100022,
    kIOHIDDigitizerEventFieldDigitizerIsDisplayIntegrated = 0x00100024,
    kIOHIDDigitizerEventFieldDigitizerQuality         = 0x00100026,
    kIOHIDDigitizerEventFieldDigitizerDensity         = 0x00100027,
    kIOHIDDigitizerEventFieldDigitizerIrregularity    = 0x00100028,
    kIOHIDDigitizerEventFieldDigitizerMajorRadius     = 0x00100029,
    kIOHIDDigitizerEventFieldDigitizerMinorRadius     = 0x0010002A,
    kIOHIDDigitizerEventFieldDigitizerAccuracy        = 0x0010002B,
};

// 派发方法
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);

extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator,
    uint64_t timestamp,
    uint32_t type,        // kIOHIDDigitizerEventRange / kIOHIDDigitizerEventTouch
    uint32_t index,
    uint32_t identity,
    uint32_t eventMask,   // transducer flags 组合
    uint32_t buttonMask,  // 触摸阶段
    double x, double y, double z,
    uint8_t tipPressure, uint8_t barrelPressure,
    uint8_t range, uint8_t touch,
    uint32_t options
);

extern void IOHIDEventSetFloatValue(IOHIDEventRef event, uint32_t field, float value);
extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);

// MARK: - TouchSlide 实现

@implementation TouchSlide {
    TouchSimulation *_sim;
    uint32_t _fingerID;
    int _step;
    int _delayMs;
    CGFloat _curX, _curY;
}

- (instancetype)initWithSim:(TouchSimulation *)sim fingerID:(uint32_t)fingerID {
    if (self = [super init]) {
        _sim = sim;
        _fingerID = fingerID;
        _step = 10;
        _delayMs = 5;
        _curX = 0;
        _curY = 0;
    }
    return self;
}

- (TouchSlide *)step:(int)step {
    _step = step;
    return self;
}

- (TouchSlide *)delay:(int)delayMs {
    _delayMs = delayMs;
    return self;
}

- (TouchSlide *)on:(CGFloat)x y:(CGFloat)y {
    _curX = x;
    _curY = y;
    [_sim downAtX:x y:y fingerID:_fingerID];
    return self;
}

- (TouchSlide *)move:(CGFloat)x y:(CGFloat)y {
    CGFloat dx = x - _curX;
    CGFloat dy = y - _curY;
    CGFloat dist = sqrt(dx * dx + dy * dy);
    int steps = (int)(dist / _step);
    if (steps < 1) steps = 1;

    for (int i = 1; i <= steps; i++) {
        CGFloat ratio = (CGFloat)i / (CGFloat)steps;
        CGFloat mx = _curX + dx * ratio;
        CGFloat my = _curY + dy * ratio;
        [_sim moveAtX:mx y:my fingerID:_fingerID];
        usleep((useconds_t)(_delayMs * 1000));
    }

    _curX = x;
    _curY = y;
    return self;
}

- (TouchSlide *)up {
    [_sim upFinger:_fingerID];
    return self;
}

@end

// MARK: - TouchSimulation 实现

@implementation TouchSimulation {
    IOHIDEventSystemClientRef _client;
    CGFloat _lastX;   // 记录最后已知坐标，用于 up 事件
    CGFloat _lastY;
}

+ (instancetype)sharedInstance {
    static TouchSimulation *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TouchSimulation alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        _lastX = 0;
        _lastY = 0;
        if (!_client) {
            [self _log:@"[TouchSimulation] ❌ IOHIDEventSystemClientCreate 返回 NULL！触控注入将完全失效"];
        } else {
            [self _log:[NSString stringWithFormat:@"[TouchSimulation] ✅ IOHIDEventSystemClient 创建成功: %p", _client]];
        }
    }
    return self;
}

- (void)dealloc {
    if (_client) CFRelease(_client);
}

- (void)_log:(NSString *)msg {
    if (self.logHandler) {
        self.logHandler(msg);
    }
    NSLog(@"%@", msg);
}

- (void)logDiagnostic {
    if (_client) {
        [self _log:[NSString stringWithFormat:@"[TouchSimulation] ✅ HID Client: %p 有效", _client]];
    } else {
        [self _log:@"[TouchSimulation] ❌ HID Client 为 NULL——触摸注入完全无效！请检查 HID 相关 entitlements"];
    }
}

// MARK: - 内部核心方法

- (uint64_t)_now {
    // 每次取真实系统时间戳，与触控精灵保持一致
    return (uint64_t)([[NSDate date] timeIntervalSince1970] * 1e9);
}

/// 发送单个触摸事件
/// 使用 IOHIDEventCreateDigitizerEvent 创建父子事件结构，
/// 这是 iOS 14-16 TrollStore 环境中最可靠的触摸注入方式。
- (void)_sendTouchAtX:(CGFloat)x y:(CGFloat)y
                phase:(uint8_t)phase
             fingerID:(uint32_t)fingerID {

    if (!_client) {
        [self _log:@"[TouchSimulation] ❌ _client 为 NULL，无法发送触摸事件"];
        return;
    }

    _lastX = x;
    _lastY = y;
    uint64_t ts = [self _now];

    uint8_t touchValue = (phase == kIOHIDDigitizerTransducerFingerPhaseEnded) ? 0 : 1;
    // transducer flags: Touch + Range 是最小集，Identity 可选
    uint32_t transducerFlags = kIOHIDDigitizerTransducerTouch | kIOHIDDigitizerTransducerRange;
    if (phase != kIOHIDDigitizerTransducerFingerPhaseEnded) {
        transducerFlags |= kIOHIDDigitizerTransducerIdentity;
    }

    // 1. 创建父事件（Range 事件 - 定义 digitizer 范围）
    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault,
        ts,
        kIOHIDDigitizerEventRange,
        0,                      // index
        0,                      // identity
        kIOHIDDigitizerTransducerRange,  // eventMask
        0,                      // buttonMask
        x, y, 0,                // x, y, z
        0, 0,                   // tipPressure, barrelPressure
        touchValue,             // range (1 = in range, 0 = out of range)
        0,                      // touch
        0                       // options
    );

    if (!parent) {
        [self _log:@"[TouchSimulation] ❌ 创建父事件(Range)返回 NULL"];
        return;
    }

    // 设置 display integrated 标志（告诉系统这是内建显示器触摸）
    IOHIDEventSetFloatValue(parent, kIOHIDDigitizerEventFieldDigitizerIsDisplayIntegrated, 1.0f);

    // 2. 创建子事件（Touch 事件 - 实际的触摸信息）
    IOHIDEventRef child = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault,
        ts,
        kIOHIDDigitizerEventTouch,
        fingerID,               // index
        fingerID + 2,           // identity
        transducerFlags,        // eventMask
        phase,                  // buttonMask = 触摸阶段
        x, y, 0,                // x, y, z
        30,                     // tipPressure
        0,                      // barrelPressure
        touchValue,             // range
        touchValue,             // touch (1 = touching, 0 = not touching)
        0                       // options
    );

    if (!child) {
        [self _log:@"[TouchSimulation] ❌ 创建子事件(Touch)返回 NULL"];
        CFRelease(parent);
        return;
    }

    // 设置触摸质量属性
    IOHIDEventSetFloatValue(child, kIOHIDDigitizerEventFieldDigitizerDensity, 500.0f);
    IOHIDEventSetFloatValue(child, kIOHIDDigitizerEventFieldDigitizerQuality, 1.0f);
    IOHIDEventSetFloatValue(child, kIOHIDDigitizerEventFieldDigitizerMajorRadius, 5.0f);
    IOHIDEventSetFloatValue(child, kIOHIDDigitizerEventFieldDigitizerMinorRadius, 5.0f);
    IOHIDEventSetFloatValue(child, kIOHIDDigitizerEventFieldDigitizerAccuracy, 1.0f);

    // 3. 将子事件附加到父事件
    IOHIDEventAppendEvent(parent, child, 0);

    const char *phaseName = (phase == kIOHIDDigitizerTransducerFingerPhaseBegan) ? "DOWN" :
                            (phase == kIOHIDDigitizerTransducerFingerPhaseMoved) ? "MOVE" :
                            (phase == kIOHIDDigitizerTransducerFingerPhaseEnded) ? "UP" : "???";

    [self _log:[NSString stringWithFormat:@"[TouchSimulation] 📱 %s finger=%d x=%.0f y=%.0f ts=%llu",
              phaseName, fingerID, x, y, ts]];

    // 4. 派发父事件（系统会同时处理子事件）
    IOHIDEventSystemClientDispatchEvent(_client, parent);
    CFRelease(child);
    CFRelease(parent);

    [self _log:[NSString stringWithFormat:@"[TouchSimulation] ✅ %s 已派发", phaseName]];
}

// MARK: - 底层原子操作

- (void)downAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    [self _sendTouchAtX:x y:y phase:kIOHIDDigitizerTransducerFingerPhaseBegan fingerID:fingerID];
}

- (void)moveAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    [self _sendTouchAtX:x y:y phase:kIOHIDDigitizerTransducerFingerPhaseMoved fingerID:fingerID];
}

- (void)upFinger:(uint32_t)fingerID {
    // up 时传入最后已知坐标（与触控精灵一致）
    [self _sendTouchAtX:_lastX y:_lastY phase:kIOHIDDigitizerTransducerFingerPhaseEnded fingerID:fingerID];
}

// MARK: - 高级封装

- (void)tapAtX:(CGFloat)x y:(CGFloat)y delayMs:(int)ms fingerID:(uint32_t)fingerID {
    [self downAtX:x y:y fingerID:fingerID];
    usleep((useconds_t)(ms * 1000));
    [self upFinger:fingerID];
}

- (void)tapRandomAtX:(CGFloat)x y:(CGFloat)y range:(int)r delayMs:(int)ms fingerID:(uint32_t)fingerID {
    int offsetX = (arc4random_uniform((uint32_t)(r * 2 + 1))) - r;
    int offsetY = (arc4random_uniform((uint32_t)(r * 2 + 1))) - r;
    [self tapAtX:(x + offsetX) y:(y + offsetY) delayMs:ms fingerID:fingerID];
}

- (TouchSlide *)slideWithFingerID:(uint32_t)fingerID {
    return [[TouchSlide alloc] initWithSim:self fingerID:fingerID];
}

// MARK: - 兼容旧接口

- (void)clickAtX:(CGFloat)x y:(CGFloat)y {
    [self tapAtX:x y:y delayMs:50 fingerID:0];
}

- (void)holdAtX:(CGFloat)x y:(CGFloat)y duration:(NSInteger)ms {
    [self downAtX:x y:y fingerID:0];
    usleep((useconds_t)(ms * 1000));
    [self upFinger:0];
}

- (void)swipeFromX:(CGFloat)x1 y:(CGFloat)y1
               toX:(CGFloat)x2 y:(CGFloat)y2
          duration:(NSInteger)ms {

    if (!_client) return;

    TouchSlide *slide = [self slideWithFingerID:0];
    [slide step:5];
    CGFloat dist = fmax(fabs(x2 - x1), fabs(y2 - y1));
    CGFloat travelDist = dist / 5;
    [slide delay:(int)(ms / (travelDist > 5 ? travelDist : 5))];

    [slide on:x1 y:y1];
    [slide move:x2 y:y2];
    [slide up];
}

@end
