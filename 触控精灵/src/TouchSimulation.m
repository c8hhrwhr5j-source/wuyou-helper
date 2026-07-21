/**
 *  TouchSimulation.m
 *  屏幕触控模拟实现
 *
 *  技术路线: IOHIDEvent 底层事件发送
 *  通过 IOHIDEventSystemClientDispatchEvent 直接向系统注入触控事件
 *  无需辅助功能权限弹窗，无需注入进程
 */

#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

// ---- IOHIDEvent 私有声明 ----
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

// 事件类型
#define kIOHIDEventTypeDigitizer 11

// Digitizer 事件子类型
enum {
    kIOHIDDigitizerEventRange       = 0x00,
    kIOHIDDigitizerEventTouch       = 0x01,
    kIOHIDDigitizerEventAttribute   = 0x02,
};

// Digitizer 事件掩码位
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
extern void IOHIDEventSetFloatValue(IOHIDEventRef event, uint32_t field, float value);
extern void IOHIDEventAppendEvent(IOHIDEventRef event, IOHIDEventRef child, uint32_t unused);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);

@interface TouchSimulation () {
    IOHIDEventSystemClientRef _client;
    uint64_t _timestamp;
}
@end

@implementation TouchSimulation

+ (instancetype)shared {
    static TouchSimulation *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[TouchSimulation alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        _timestamp = 0;
    }
    return self;
}

- (uint64_t)_now {
    return (uint64_t)([[NSDate date] timeIntervalSince1970] * 1e9);
}

- (CGSize)screenSize {
    return [UIScreen mainScreen].nativeBounds.size;
}

- (void)_sendTouchAtX:(CGFloat)x y:(CGFloat)y phase:(uint8_t)phase {
    uint64_t ts = [self _now];

    // 创建一个 digitizer touch 事件
    IOHIDEventRef touchEvent = IOHIDEventCreateDigitizerFingerEventWithQuality(
        kCFAllocatorDefault,
        ts,
        0,      // index
        2,      // identity
        kIOHIDDigitizerTransducerTouch | kIOHIDDigitizerTransducerIdentity | kIOHIDDigitizerTransducerRange,
        x, y, 0,  // x, y, z
        30,     // tipPressure
        0,      // twist
        80,     // range
        phase == kIOHIDDigitizerTransducerFingerPhaseEnded ? 0 : 1,  // touch (1=touching, 0=not)
        1,      // quality
        500,    // density
        0,      // irregularity
        5,      // majorRadius
        5,      // minorRadius
        1.0     // accuracy
    );

    if (touchEvent) {
        IOHIDEventSystemClientDispatchEvent(_client, touchEvent);
        CFRelease(touchEvent);
    }
}

#pragma mark - 公开接口

- (void)clickAtX:(CGFloat)x y:(CGFloat)y {
    // Touch down
    [self _sendTouchAtX:x y:y phase:kIOHIDDigitizerTransducerFingerPhaseBegan];
    // Touch up (极短间隔模拟点击)
    usleep(10000); // 10ms
    [self _sendTouchAtX:x y:y phase:kIOHIDDigitizerTransducerFingerPhaseEnded];
}

- (void)longClickAtX:(CGFloat)x y:(CGFloat)y durationMs:(int)durationMs {
    // Touch down
    [self _sendTouchAtX:x y:y phase:kIOHIDDigitizerTransducerFingerPhaseBegan];
    // 按住指定时长
    usleep(durationMs * 1000);
    // Touch up
    [self _sendTouchAtX:x y:y phase:kIOHIDDigitizerTransducerFingerPhaseEnded];
}

- (void)swipeFromX:(CGFloat)x1 y:(CGFloat)y1
              toX:(CGFloat)x2 y:(CGFloat)y2
        durationMs:(int)durationMs
{
    int steps = MAX(5, durationMs / 5);  // 每 5ms 一步，最少 5 步
    CGFloat stepDx = (x2 - x1) / steps;
    CGFloat stepDy = (y2 - y1) / steps;
    int stepDelayUs = (durationMs * 1000) / steps;

    // Touch down at start
    [self _sendTouchAtX:x1 y:y1 phase:kIOHIDDigitizerTransducerFingerPhaseBegan];

    // Move through intermediate points
    for (int i = 1; i < steps; i++) {
        usleep(stepDelayUs);
        CGFloat cx = x1 + stepDx * i;
        CGFloat cy = y1 + stepDy * i;
        [self _sendTouchAtX:cx y:cy phase:kIOHIDDigitizerTransducerFingerPhaseMoved];
    }

    // Touch up at end
    usleep(stepDelayUs);
    [self _sendTouchAtX:x2 y:y2 phase:kIOHIDDigitizerTransducerFingerPhaseEnded];
}

@end
