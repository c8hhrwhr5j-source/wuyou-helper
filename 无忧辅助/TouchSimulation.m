//
//  TouchSimulation.m
//  无忧辅助 - 通过 IOHIDEventSystemClient 进行触控模拟（TrollStore 跨应用方案）
//

#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdlib.h>
#import <math.h>
#import <unistd.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

static CGSize _screenSize = {0, 0};
static uint32_t _fingerSeq = 1000;

typedef void* IOHIDEventSystemClientRef;
typedef void* IOHIDEventRef;

typedef IOHIDEventSystemClientRef (*IOHIDEventSystemClientCreateFn)(CFAllocatorRef allocator);
typedef IOHIDEventRef (*IOHIDEventCreateDigitizerEventFn)(CFAllocatorRef allocator, uint64_t timeStamp, uint32_t type, uint32_t subtype, uint32_t index, uint32_t identity, uint8_t attributeMask, uint8_t range, uint8_t touch, uint32_t options);
typedef IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEventFn)(CFAllocatorRef allocator, uint64_t timeStamp, uint32_t index, uint32_t identity, uint8_t attributeMask, uint8_t range, uint8_t touch, uint32_t type, float x, float y, float z, float tipPressure, float barrelPressure, uint32_t options);
typedef void (*IOHIDEventAppendEventFn)(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
typedef void (*IOHIDEventSystemClientDispatchEventFn)(IOHIDEventSystemClientRef client, IOHIDEventRef event);
typedef void (*IOHIDEventReleaseFn)(IOHIDEventRef event);

static IOHIDEventSystemClientCreateFn _IOHIDEventSystemClientCreate = NULL;
static IOHIDEventCreateDigitizerEventFn _IOHIDEventCreateDigitizerEvent = NULL;
static IOHIDEventCreateDigitizerFingerEventFn _IOHIDEventCreateDigitizerFingerEvent = NULL;
static IOHIDEventAppendEventFn _IOHIDEventAppendEvent = NULL;
static IOHIDEventSystemClientDispatchEventFn _IOHIDEventSystemClientDispatchEvent = NULL;
static IOHIDEventReleaseFn _IOHIDEventRelease = NULL;

static IOHIDEventSystemClientRef _eventClient = NULL;

#define kIOHIDDigitizerEventRange     0
#define kIOHIDDigitizerEventTouch     1
#define kIOHIDDigitizerEventPosition  2
#define kIOHIDDigitizerTransducerFinger 2

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

- (TouchSlide *)step:(int)step { _step = step; return self; }
- (TouchSlide *)delay:(int)delayMs { _delayMs = delayMs; return self; }

- (TouchSlide *)on:(CGFloat)x y:(CGFloat)y {
    _curX = x; _curY = y;
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
    _curX = x; _curY = y;
    return self;
}

- (TouchSlide *)up {
    [_sim upFinger:_fingerID];
    return self;
}

@end

// MARK: - TouchSimulation 实现

@implementation TouchSimulation {
    CGFloat _lastX;
    CGFloat _lastY;
    uint32_t _lastIdentity;
    BOOL _hidInitialized;
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
        _screenSize = [UIScreen mainScreen].bounds.size;
        _lastX = 0;
        _lastY = 0;
        _lastIdentity = 0;
        _hidInitialized = NO;
    }
    return self;
}

- (void)_log:(NSString *)msg {
    if (self.logHandler) {
        self.logHandler(msg);
    }
    NSLog(@"%@", msg);
}

- (BOOL)_initHID {
    if (_hidInitialized) return (_eventClient != NULL);
    _hidInitialized = YES;

    [self _log:@"[TouchSimulation] 🔧 开始初始化 IOHIDEventSystemClient..."];

    void* handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!handle) {
        [self _log:@"[TouchSimulation] ❌ dlopen IOKit 失败"];
        return NO;
    }
    [self _log:@"[TouchSimulation] ✅ dlopen IOKit 成功"];

    _IOHIDEventSystemClientCreate = dlsym(handle, "IOHIDEventSystemClientCreate");
    _IOHIDEventCreateDigitizerEvent = dlsym(handle, "IOHIDEventCreateDigitizerEvent");
    _IOHIDEventCreateDigitizerFingerEvent = dlsym(handle, "IOHIDEventCreateDigitizerFingerEvent");
    _IOHIDEventAppendEvent = dlsym(handle, "IOHIDEventAppendEvent");
    _IOHIDEventSystemClientDispatchEvent = dlsym(handle, "IOHIDEventSystemClientDispatchEvent");
    _IOHIDEventRelease = dlsym(handle, "IOHIDEventRelease");

    [self _log:[NSString stringWithFormat:@"[TouchSimulation] 函数指针: Create=%p Digitizer=%p Finger=%p Append=%p Dispatch=%p Release=%p",
        _IOHIDEventSystemClientCreate, _IOHIDEventCreateDigitizerEvent, _IOHIDEventCreateDigitizerFingerEvent,
        _IOHIDEventAppendEvent, _IOHIDEventSystemClientDispatchEvent, _IOHIDEventRelease]];

    if (!_IOHIDEventSystemClientCreate || !_IOHIDEventCreateDigitizerEvent ||
        !_IOHIDEventCreateDigitizerFingerEvent || !_IOHIDEventAppendEvent ||
        !_IOHIDEventSystemClientDispatchEvent || !_IOHIDEventRelease) {
        [self _log:@"[TouchSimulation] ❌ 部分函数指针获取失败"];
        return NO;
    }
    [self _log:@"[TouchSimulation] ✅ 所有函数指针获取成功"];

    _eventClient = _IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!_eventClient) {
        [self _log:@"[TouchSimulation] ❌ IOHIDEventSystemClientCreate 失败"];
        return NO;
    }
    [self _log:@"[TouchSimulation] ✅ IOHIDEventSystemClient 创建成功"];
    return YES;
}

- (void)logDiagnostic {
    [self _initHID];
    if (_eventClient) {
        [self _log:@"[TouchSimulation] ✅ HID事件系统已就绪"];
    } else {
        [self _log:@"[TouchSimulation] ❌ HID事件系统未初始化"];
    }
}

// MARK: - HID 事件发送

- (void)_sendTouchEvent:(BOOL)isDown atX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    if (![self _initHID]) {
        [self _log:@"[TouchSimulation] ❌ HID事件系统不可用"];
        return;
    }

    uint64_t timestamp = mach_absolute_time();
    float normX = (float)(x / _screenSize.width);
    float normY = (float)(y / _screenSize.height);

    // 创建手指事件
    IOHIDEventRef fingerEvent = _IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault,
        timestamp,
        0,              // index
        fingerID,       // identity
        0,              // attributeMask
        isDown ? 1 : 0, // range
        isDown ? 1 : 0, // touch
        kIOHIDDigitizerTransducerFinger, // type
        normX, normY,
        0.0f,           // z
        isDown ? 1.0f : 0.0f,  // tipPressure
        0.0f,           // barrelPressure
        0               // options
    );

    if (!fingerEvent) {
        [self _log:@"[TouchSimulation] ❌ 手指事件创建失败"];
        return;
    }

    // 创建容器事件（Range 事件）
    IOHIDEventRef digitizerEvent = _IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault,
        timestamp,
        kIOHIDDigitizerEventRange,  // type
        0,                          // subtype
        0,                          // index
        fingerID,                   // identity
        0,                          // attributeMask
        isDown ? 1 : 0,             // range
        isDown ? 1 : 0,             // touch
        0                           // options
    );

    if (!digitizerEvent) {
        [self _log:@"[TouchSimulation] ❌ 容器事件创建失败"];
        _IOHIDEventRelease(fingerEvent);
        return;
    }

    // 将手指事件添加到容器事件
    _IOHIDEventAppendEvent(digitizerEvent, fingerEvent, 0);

    // 派发事件
    _IOHIDEventSystemClientDispatchEvent(_eventClient, digitizerEvent);

    // 释放事件
    _IOHIDEventRelease(digitizerEvent);

    const char *typeName = isDown ? "DOWN" : "UP";
    [self _log:[NSString stringWithFormat:@"[TouchSimulation] 📱 %s x=%.0f y=%.0f finger=%u", typeName, x, y, fingerID]];
}

- (void)_sendMoveEventAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    if (![self _initHID]) {
        [self _log:@"[TouchSimulation] ❌ HID事件系统不可用"];
        return;
    }

    uint64_t timestamp = mach_absolute_time();
    float normX = (float)(x / _screenSize.width);
    float normY = (float)(y / _screenSize.height);

    IOHIDEventRef fingerEvent = _IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault,
        timestamp,
        0, 1,
        0, 1, 1,
        kIOHIDDigitizerTransducerFinger,
        normX, normY,
        0.0f, 1.0f, 0.0f, 0
    );

    if (!fingerEvent) return;

    IOHIDEventRef digitizerEvent = _IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault,
        timestamp,
        kIOHIDDigitizerEventPosition,
        0, 0, 1, 0, 1, 1, 0
    );

    if (!digitizerEvent) {
        _IOHIDEventRelease(fingerEvent);
        return;
    }

    _IOHIDEventAppendEvent(digitizerEvent, fingerEvent, 0);
    _IOHIDEventSystemClientDispatchEvent(_eventClient, digitizerEvent);
    _IOHIDEventRelease(digitizerEvent);
}

// MARK: - 内部核心方法

- (void)_sendTouchAtX:(CGFloat)x y:(CGFloat)y isTouching:(BOOL)isTouching fingerID:(uint32_t)fingerID {
    _lastX = x;
    _lastY = y;
    if (isTouching) {
        _lastIdentity = _fingerSeq++;
    }
    [self _sendTouchEvent:isTouching atX:x y:y fingerID:fingerID];
    usleep(5000);
}

// MARK: - 底层原子操作

- (void)downAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    [self _sendTouchAtX:x y:y isTouching:YES fingerID:fingerID];
}

- (void)moveAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    _lastX = x;
    _lastY = y;
    [self _sendMoveEventAtX:x y:y fingerID:fingerID];
}

- (void)upFinger:(uint32_t)fingerID {
    [self _sendTouchAtX:_lastX y:_lastY isTouching:NO fingerID:fingerID];
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
