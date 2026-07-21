//
//  TouchSimulation.m
//  无忧辅助 - 通过 IOHIDEvent 进行触控模拟（多指支持）
//

#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach_time.h>
#import <stdlib.h>
#import <math.h>
#import <unistd.h>

// IOHIDEvent 私有 API
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator,
    uint64_t timeStamp, uint32_t type, uint32_t index, uint32_t identity,
    uint32_t eventMask, uint32_t buttonMask, uint32_t range, uint32_t touch,
    uint32_t pressure, ...);
extern int IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client,
                                                IOHIDEventRef event);

// 触摸阶段
#define kDigitizerPhaseBegan     0
#define kDigitizerPhaseMoved     1
#define kDigitizerPhaseEnded     2

// 触摸类型
#define kDigitizerTypeHand       2

// 事件掩码
#define kDigitizerEventMaskTouch       0x0001
#define kDigitizerEventMaskAttribute   0x0002

// 字段键
#define kIOHIDEventFieldDigitizerX     0x00040001
#define kIOHIDEventFieldDigitizerY     0x00040002

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
    uint64_t _baseTimestamp;
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
        _baseTimestamp = 0;
        if (!_client) {
            NSLog(@"[TouchSimulation] IOHIDEventSystemClientCreate failed");
        }
    }
    return self;
}

- (void)dealloc {
    if (_client) CFRelease(_client);
}

// MARK: - 内部核心方法

/// 发送单个 IOHIDEvent
- (void)_sendEventAtX:(CGFloat)x y:(CGFloat)y
                 phase:(uint32_t)phase
             fingerID:(uint32_t)fingerID
         touchContact:(uint32_t)touchContact {

    if (!_client) return;

    if (_baseTimestamp == 0) {
        _baseTimestamp = mach_absolute_time();
    } else {
        _baseTimestamp += 1000000;  // +1ms
    }

    uint32_t eventMask = kDigitizerEventMaskTouch;
    if (phase == kDigitizerPhaseBegan) {
        eventMask |= kDigitizerEventMaskAttribute;
    }

    IOHIDEventRef event = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault,
        _baseTimestamp,
        kDigitizerTypeHand,
        (uint32_t)fingerID,   // index — 每个手指用不同 index
        fingerID + 2,         // identity — 用 fingerID+2 区分不同手指
        eventMask,
        0,                    // buttonMask
        0,                    // range
        touchContact,         // touch (1=接触, 0=离开)
        0,                    // pressure
        kIOHIDEventFieldDigitizerX, (int)(x * 1000),
        kIOHIDEventFieldDigitizerY, (int)(y * 1000),
        0                     // sentinel
    );

    if (event) {
        IOHIDEventSystemClientDispatchEvent(_client, event);
        CFRelease(event);
    }
}

// MARK: - 底层原子操作

- (void)downAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    [self _sendEventAtX:x y:y phase:kDigitizerPhaseBegan fingerID:fingerID touchContact:1];
}

- (void)moveAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    [self _sendEventAtX:x y:y phase:kDigitizerPhaseMoved fingerID:fingerID touchContact:1];
}

- (void)upFinger:(uint32_t)fingerID {
    [self _sendEventAtX:0 y:0 phase:kDigitizerPhaseEnded fingerID:fingerID touchContact:0];
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
    CGFloat travelDist = ((x2 - x1) + (y2 - y1)) / 5;
    [slide delay:(int)(ms / (travelDist > 5 ? travelDist : 5))];

    [slide on:x1 y:y1];
    [slide move:x2 y:y2];
    [slide up];
}

@end
