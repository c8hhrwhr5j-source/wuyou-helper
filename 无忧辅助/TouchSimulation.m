//
//  TouchSimulation.m
//  无忧辅助 - 通过 IOHIDEvent 进行触控模拟（参考 AutoGo-iOS）
//

#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdlib.h>
#import <math.h>
#import <unistd.h>
#import <mach/mach_time.h>
#import <dlfcn.h>

// ---- IOHIDEvent 动态加载 ----
typedef void* IOHIDEventRef;
typedef void* IOHIDEventSystemClientRef;

typedef IOHIDEventRef (*IOHIDEventCreateDigitizerEventFn)(
    CFAllocatorRef, uint64_t, int32_t, uint32_t, uint32_t,
    uint32_t, uint32_t, double, double, double, double, double,
    bool, bool, uint32_t);

typedef IOHIDEventSystemClientRef (*IOHIDEventSystemClientCreateFn)(CFAllocatorRef);
typedef int32_t (*IOHIDEventSystemClientDispatchEventFn)(IOHIDEventSystemClientRef, IOHIDEventRef);

static IOHIDEventCreateDigitizerEventFn _createDigitizerEvent = NULL;
static IOHIDEventSystemClientCreateFn _createClient = NULL;
static IOHIDEventSystemClientDispatchEventFn _dispatchEvent = NULL;
static IOHIDEventSystemClientRef _hidClient = NULL;
static uint32_t _fingerSeq = 1000;

// Digitizer event mask (与 AutoGo-iOS 一致)
#define kDigitizerEventRange    0x01
#define kDigitizerEventTouch    0x02
#define kDigitizerEventPosition 0x04
#define kDigitizerEventIdentity 0x20

static uint64_t mach_abs_time_us(void) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    uint64_t abs = mach_absolute_time();
    return abs * info.numer / info.denom;
}

static bool dispatch_digitizer(double x, double y, bool touch, uint32_t fingerIndex, uint32_t identity) {
    if (!_createDigitizerEvent || !_dispatchEvent || !_hidClient) return false;
    
    uint32_t mask = kDigitizerEventRange | kDigitizerEventTouch | kDigitizerEventPosition | kDigitizerEventIdentity;
    IOHIDEventRef event = _createDigitizerEvent(kCFAllocatorDefault, mach_abs_time_us(),
        0, fingerIndex, identity, mask, 0, x, y, 0, 0, 0, true, touch, 0);
    if (!event) return false;
    
    int32_t result = _dispatchEvent(_hidClient, event);
    CFRelease(event);
    
    static bool logged = false;
    if (!logged) {
        NSLog(@"[TouchSimulation] dispatch result=%d", result);
        logged = true;
    }
    
    return result == 0;
}

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
        [self _initHID];
        _lastX = 0;
        _lastY = 0;
        _lastIdentity = 0;
    }
    return self;
}

- (void)_initHID {
    void* handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!handle) {
        handle = dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", RTLD_LAZY);
    }
    if (!handle) {
        [self _log:@"[TouchSimulation] ❌ 无法加载 IOKit.framework"];
        return;
    }
    
    _createDigitizerEvent = dlsym(handle, "IOHIDEventCreateDigitizerEvent");
    _createClient = dlsym(handle, "IOHIDEventSystemClientCreate");
    _dispatchEvent = dlsym(handle, "IOHIDEventSystemClientDispatchEvent");
    
    if (_createClient) {
        _hidClient = _createClient(kCFAllocatorDefault);
    }
    
    if (_createDigitizerEvent && _hidClient && _dispatchEvent) {
        [self _log:@"[TouchSimulation] ✅ IOHIDEvent 初始化成功"];
    } else {
        [self _log:@"[TouchSimulation] ❌ IOHIDEvent 初始化失败"];
    }
}

- (void)dealloc {
    if (_hidClient) CFRelease(_hidClient);
}

- (void)_log:(NSString *)msg {
    if (self.logHandler) {
        self.logHandler(msg);
    }
    NSLog(@"%@", msg);
}

- (void)logDiagnostic {
    if (_hidClient && _createDigitizerEvent && _dispatchEvent) {
        [self _log:@"[TouchSimulation] ✅ HID Client 有效"];
    } else {
        [self _log:@"[TouchSimulation] ❌ HID 初始化不完整——触摸注入完全无效！"];
    }
}

// MARK: - 内部核心方法

- (void)_sendTouchAtX:(CGFloat)x y:(CGFloat)y isTouching:(bool)isTouching fingerID:(uint32_t)fingerID {
    _lastX = x;
    _lastY = y;
    
    const char *phaseName = isTouching ? "DOWN" : "UP";
    
    uint32_t identity = isTouching ? (_fingerSeq++) : 0;
    _lastIdentity = isTouching ? identity : _lastIdentity;
    
    [self _log:[NSString stringWithFormat:@"[TouchSimulation] 📱 %s finger=%d x=%.0f y=%.0f identity=%u",
              phaseName, fingerID, x, y, identity]];
    
    bool success = dispatch_digitizer((double)x, (double)y, isTouching, 0, identity);
    
    [self _log:[NSString stringWithFormat:@"[TouchSimulation] %s %@", phaseName, success ? @"✅ 已派发" : @"❌ 派发失败"]];
}

- (void)_sendMoveAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    _lastX = x;
    _lastY = y;
    
    [self _log:[NSString stringWithFormat:@"[TouchSimulation] 📱 MOVE finger=%d x=%.0f y=%.0f", fingerID, x, y]];
    
    bool success = dispatch_digitizer((double)x, (double)y, true, 0, _lastIdentity);
    
    [self _log:[NSString stringWithFormat:@"[TouchSimulation] MOVE %@", success ? @"✅ 已派发" : @"❌ 派发失败"]];
}

// MARK: - 底层原子操作

- (void)downAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    [self _sendTouchAtX:x y:y isTouching:true fingerID:fingerID];
}

- (void)moveAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    [self _sendMoveAtX:x y:y fingerID:fingerID];
}

- (void)upFinger:(uint32_t)fingerID {
    [self _sendTouchAtX:_lastX y:_lastY isTouching:false fingerID:fingerID];
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
