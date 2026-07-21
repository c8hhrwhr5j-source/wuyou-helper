//
//  TouchSimulation.m
//  无忧辅助 - 通过 IOHIDEvent 进行触控模拟（与触控精灵逐字一致）
//

#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdlib.h>
#import <math.h>
#import <unistd.h>

// ---- IOHIDEvent 私有声明 ----
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

// 事件类型
#define kIOHIDEventTypeDigitizer 11

// Digitizer transducer flags
enum {
    kIOHIDDigitizerTransducerTouch       = (1 << 0),
    kIOHIDDigitizerTransducerIdentity    = (1 << 2),
    kIOHIDDigitizerTransducerRange       = (1 << 3),
};

// 触摸阶段
enum {
    kIOHIDDigitizerTransducerFingerPhaseBegan      = 0x01,
    kIOHIDDigitizerTransducerFingerPhaseMoved       = 0x02,
    kIOHIDDigitizerTransducerFingerPhaseStationary  = 0x04,
    kIOHIDDigitizerTransducerFingerPhaseEnded       = 0x08,
};

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator,
    uint64_t timestamp,
    uint32_t type,
    uint32_t index,
    uint32_t identity,
    uint32_t eventMask,
    uint32_t buttonMask,
    double x, double y, double z,
    uint8_t tipPressure, uint8_t barrelPressure,
    uint8_t range, uint8_t touch,
    uint32_t options
);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEventWithQuality(
    CFAllocatorRef allocator,
    uint64_t timestamp,
    uint32_t index,
    uint32_t identity,
    uint32_t eventMask,
    double x, double y, double z,
    uint8_t tipPressure, uint8_t twist,
    uint8_t range, uint8_t touch,
    uint32_t quality,
    uint32_t density,
    uint32_t irregularity,
    uint32_t majorRadius,
    uint32_t minorRadius,
    double accuracy
);
extern void IOHIDEventAppendEvent(IOHIDEventRef event, IOHIDEventRef child, uint32_t unused);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);

// Digitizer 事件子类型
enum {
    kIOHIDDigitizerEventRange       = 0x00,
    kIOHIDDigitizerEventTouch       = 0x01,
    kIOHIDDigitizerEventAttribute   = 0x02,
};

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
    CGFloat _lastX;
    CGFloat _lastY;
    CGFloat _screenScale;
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
        _screenScale = [UIScreen mainScreen].scale;
        if (!_client) {
            [self _log:@"[TouchSimulation] ❌ IOHIDEventSystemClientCreate 返回 NULL！触控注入将完全失效"];
        } else {
            [self _log:[NSString stringWithFormat:@"[TouchSimulation] ✅ IOHIDEventSystemClient 创建成功: %p scale=%.1f", _client, _screenScale]];
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
    return (uint64_t)([[NSDate date] timeIntervalSince1970] * 1e9);
}

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

    uint8_t touchVal = (phase == kIOHIDDigitizerTransducerFingerPhaseEnded) ? 0 : 1;

    const char *phaseName = (phase == kIOHIDDigitizerTransducerFingerPhaseBegan) ? "DOWN" :
                            (phase == kIOHIDDigitizerTransducerFingerPhaseMoved) ? "MOVE" :
                            (phase == kIOHIDDigitizerTransducerFingerPhaseEnded) ? "UP" : "???";

    CGFloat logicalX = x / _screenScale;
    CGFloat logicalY = y / _screenScale;

    IOHIDEventRef fingerEvent = IOHIDEventCreateDigitizerFingerEventWithQuality(
        kCFAllocatorDefault,
        ts,
        0,                          // index
        2,                          // identity
        kIOHIDDigitizerTransducerTouch | kIOHIDDigitizerTransducerIdentity | kIOHIDDigitizerTransducerRange,
        logicalX, logicalY, 0,      // x, y, z — 转换为逻辑坐标（点坐标）
        30,                         // tipPressure
        0,                          // twist
        80,                         // range
        touchVal,                   // touch
        1,                          // quality
        500,                        // density
        0,                          // irregularity
        5,                          // majorRadius
        5,                          // minorRadius
        1.0                         // accuracy
    );

    if (!fingerEvent) {
        [self _log:[NSString stringWithFormat:@"[TouchSimulation] ❌ 创建手指事件失败！phase=%d x=%.0f y=%.0f", phase, x, y]];
        return;
    }

    IOHIDEventRef rangeEvent = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault,
        ts,
        kIOHIDDigitizerEventRange,
        0,
        0,
        kIOHIDDigitizerTransducerRange,
        0,
        0, 0, 0,
        0, 0,
        80,
        touchVal,
        0
    );

    if (!rangeEvent) {
        [self _log:@"[TouchSimulation] ❌ 创建 Range 事件失败！"];
        CFRelease(fingerEvent);
        return;
    }

    IOHIDEventAppendEvent(rangeEvent, fingerEvent, 0);
    CFRelease(fingerEvent);

    [self _log:[NSString stringWithFormat:@"[TouchSimulation] 📱 %s finger=%d x=%.0f y=%.0f (logical: %.1f, %.1f) ts=%llu",
              phaseName, fingerID, x, y, logicalX, logicalY, ts]];

    IOHIDEventSystemClientDispatchEvent(_client, rangeEvent);
    CFRelease(rangeEvent);

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
    [self tapAtX:x y:y delayMs:10 fingerID:0];
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
