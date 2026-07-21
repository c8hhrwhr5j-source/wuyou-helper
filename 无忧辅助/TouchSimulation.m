//
//  TouchSimulation.m
//  无忧辅助 - 通过 CGEvent 无障碍方案进行跨应用触控模拟（TrollStore 特权版）
//

#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdlib.h>
#import <math.h>
#import <unistd.h>
#import <dlfcn.h>

static CGSize _screenSize = {0, 0};
static uint32_t _fingerSeq = 1000;

// CGEvent 类型常量（与 macOS 一致，iOS 私有 API 同样使用）
#define kCGHIDEventTap           0
#define kCGEventLeftMouseDown    1
#define kCGEventLeftMouseUp      2
#define kCGEventMouseMoved       5
#define kCGEventSourceStateHIDSystemState 1
#define kCGMouseButtonLeft       0

// 关键：设置鼠标事件子类型为 Touch（必须设置，否则 iOS 会忽略）
#define kCGMouseEventSubType     2  // field code for subType
#define kCGMouseEventSubTypeTouch 1  // touch subType

typedef void* CGEventRef;
typedef void* CGEventSourceRef;
typedef uint32_t CGEventType;
typedef uint32_t CGMouseButton;
typedef uint32_t CGEventTapLocation;
typedef uint32_t CGEventSourceStateID;
typedef uint64_t CGEventField;

typedef struct {
    double x;
    double y;
} CGPointStruct;

typedef CGEventRef (*CGEventCreateMouseEventFn)(CGEventSourceRef source, CGEventType type, CGPointStruct point, CGMouseButton button);
typedef void (*CGEventPostFn)(CGEventTapLocation tap, CGEventRef event);
typedef CGEventSourceRef (*CGEventSourceCreateFn)(CGEventSourceStateID stateID);
typedef void (*CGEventSetIntegerValueFieldFn)(CGEventRef event, CGEventField field, int64_t value);

static CGEventCreateMouseEventFn _CGEventCreateMouseEvent = NULL;
static CGEventPostFn _CGEventPost = NULL;
static CGEventSourceCreateFn _CGEventSourceCreate = NULL;
static CGEventSetIntegerValueFieldFn _CGEventSetIntegerValueField = NULL;

static CGEventSourceRef _eventSource = NULL;

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
    }
    return self;
}

- (void)_log:(NSString *)msg {
    if (self.logHandler) {
        self.logHandler(msg);
    }
    NSLog(@"%@", msg);
}

- (BOOL)_initCGEvent {
    [self _log:@"[TouchSimulation] 🔧 开始初始化 CGEvent 无障碍方案..."];

    // CGEvent 函数在 CoreGraphics framework 中（iOS 私有 API）
    void* handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
    if (!handle) {
        // 尝试 ApplicationServices
        handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY);
    }
    if (!handle) {
        [self _log:@"[TouchSimulation] ❌ dlopen CoreGraphics 失败"];
        return NO;
    }
    [self _log:@"[TouchSimulation] ✅ dlopen CoreGraphics 成功"];

    _CGEventCreateMouseEvent = dlsym(handle, "CGEventCreateMouseEvent");
    _CGEventPost = dlsym(handle, "CGEventPost");
    _CGEventSourceCreate = dlsym(handle, "CGEventSourceCreate");
    _CGEventSetIntegerValueField = dlsym(handle, "CGEventSetIntegerValueField");

    [self _log:[NSString stringWithFormat:@"[TouchSimulation] 函数指针: CreateMouseEvent=%p Post=%p SourceCreate=%p SetInteger=%p",
        _CGEventCreateMouseEvent, _CGEventPost, _CGEventSourceCreate, _CGEventSetIntegerValueField]];

    if (!_CGEventCreateMouseEvent || !_CGEventPost) {
        [self _log:@"[TouchSimulation] ❌ CGEvent 核心函数获取失败"];
        return NO;
    }
    [self _log:@"[TouchSimulation] ✅ CGEvent 核心函数获取成功"];
    if (_CGEventSetIntegerValueField) {
        [self _log:@"[TouchSimulation] ✅ CGEventSetIntegerValueField 获取成功"];
    } else {
        [self _log:@"[TouchSimulation] ⚠️ CGEventSetIntegerValueField 获取失败（可能影响点击效果）"];
    }

    // 创建事件源（如果可用）
    if (_CGEventSourceCreate) {
        _eventSource = _CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        if (_eventSource) {
            [self _log:@"[TouchSimulation] ✅ CGEventSource 创建成功"];
        } else {
            [self _log:@"[TouchSimulation] ⚠️ CGEventSource 创建失败，将使用 NULL source"];
        }
    } else {
        [self _log:@"[TouchSimulation] ⚠️ CGEventSourceCreate 不可用，将使用 NULL source"];
    }

    [self _log:@"[TouchSimulation] ✅ CGEvent 无障碍方案初始化完成"];
    return YES;
}

- (void)logDiagnostic {
    if (_CGEventPost) {
        [self _log:@"[TouchSimulation] ✅ CGEvent 无障碍系统已就绪"];
    } else {
        [self _log:@"[TouchSimulation] ❌ CGEvent 无障碍系统未初始化"];
    }
}

// MARK: - CGEvent 发送

- (void)_sendMouseEvent:(CGEventType)type atX:(CGFloat)x y:(CGFloat)y {
    if (![self _initCGEvent]) {
        [self _log:@"[TouchSimulation] ❌ CGEvent 系统不可用"];
        return;
    }

    CGPointStruct point;
    point.x = x;
    point.y = y;

    CGEventRef event = _CGEventCreateMouseEvent(_eventSource, type, point, kCGMouseButtonLeft);
    if (!event) {
        [self _log:@"[TouchSimulation] ❌ CGEvent 创建失败"];
        return;
    }

    // 设置鼠标事件子类型为 Touch
    if (_CGEventSetIntegerValueField) {
        _CGEventSetIntegerValueField(event, kCGMouseEventSubType, kCGMouseEventSubTypeTouch);
    }

    _CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

- (void)_sendTouchEvent:(BOOL)isDown atX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    if (![self _initCGEvent]) {
        [self _log:@"[TouchSimulation] ❌ CGEvent 系统不可用"];
        return;
    }

    CGPointStruct point;
    point.x = x;
    point.y = y;

    CGEventType type = isDown ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;
    CGEventRef event = _CGEventCreateMouseEvent(_eventSource, type, point, kCGMouseButtonLeft);
    if (!event) {
        [self _log:@"[TouchSimulation] ❌ CGEvent 创建失败"];
        return;
    }

    // 关键：设置鼠标事件子类型为 Touch，否则 iOS 会将其视为纯鼠标点击并忽略
    if (_CGEventSetIntegerValueField) {
        _CGEventSetIntegerValueField(event, kCGMouseEventSubType, kCGMouseEventSubTypeTouch);
    }

    _CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);

    const char *typeName = isDown ? "DOWN" : "UP";
    [self _log:[NSString stringWithFormat:@"[TouchSimulation] 📱 %s x=%.0f y=%.0f finger=%u", typeName, x, y, fingerID]];
}

- (void)_sendMoveEventAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    if (![self _initCGEvent]) {
        [self _log:@"[TouchSimulation] ❌ CGEvent 系统不可用"];
        return;
    }

    CGPointStruct point;
    point.x = x;
    point.y = y;

    CGEventRef event = _CGEventCreateMouseEvent(_eventSource, kCGEventMouseMoved, point, kCGMouseButtonLeft);
    if (!event) return;

    // 设置鼠标事件子类型为 Touch
    if (_CGEventSetIntegerValueField) {
        _CGEventSetIntegerValueField(event, kCGMouseEventSubType, kCGMouseEventSubTypeTouch);
    }

    _CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
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
