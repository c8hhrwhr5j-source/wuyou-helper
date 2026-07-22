//
//  TouchSimulation.m
//  无忧辅助 - BackBoardServices HID 事件注入（TrollStore 跨进程点击方案）
//

#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <stdlib.h>
#import <math.h>
#import <unistd.h>

static CGSize _screenSize = {0, 0};
static CGFloat _scale = 1.0;
static uint32_t _fingerSeq = 1000;

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventQueue *IOHIDEventQueueRef;
typedef struct __IOHIDEventServiceClient *IOHIDEventServiceClientRef;

typedef void* (*BKSHIDEventRouterInstanceFunc)(void);
typedef void (*BKSHIDEventRouterRouteEventFunc)(void*, IOHIDEventRef);

static void *_backBoardServicesHandle = NULL;
static BKSHIDEventRouterInstanceFunc _bkRouterInstance = NULL;
static BKSHIDEventRouterRouteEventFunc _bkRouteEvent = NULL;

static BOOL _backBoardInitialized = NO;

@interface TouchSimulation ()
- (BOOL)_initializeBackBoardServices;
- (IOHIDEventRef)_createDigitizerEventWithPhase:(uint32_t)phase 
                                              x:(CGFloat)x 
                                              y:(CGFloat)y 
                                         fingerID:(uint32_t)fingerID;
- (void)_sendHIDEvent:(IOHIDEventRef)event;
@end

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

@implementation TouchSimulation {
    CGFloat _lastX;
    CGFloat _lastY;
    BOOL _initialized;
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
        _scale = [UIScreen mainScreen].scale;
        _lastX = 0;
        _lastY = 0;
        _initialized = YES;
        [self _initializeBackBoardServices];
    }
    return self;
}

- (void)_log:(NSString *)msg {
    if (self.logHandler) {
        self.logHandler(msg);
    }
    NSLog(@"%@", msg);
}

- (BOOL)_initializeBackBoardServices {
    if (_backBoardInitialized) return YES;
    
    _backBoardServicesHandle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
    if (!_backBoardServicesHandle) {
        [self _log:@"[TouchSimulation] ❌ 加载 BackBoardServices 失败"];
        return NO;
    }
    
    _bkRouterInstance = (BKSHIDEventRouterInstanceFunc)dlsym(_backBoardServicesHandle, "BKSHIDEventRouterInstance");
    if (!_bkRouterInstance) {
        [self _log:@"[TouchSimulation] ❌ 获取 BKSHIDEventRouterInstance 失败"];
        dlclose(_backBoardServicesHandle);
        _backBoardServicesHandle = NULL;
        return NO;
    }
    
    _bkRouteEvent = (BKSHIDEventRouterRouteEventFunc)dlsym(_backBoardServicesHandle, "BKSHIDEventRouterRouteEvent");
    if (!_bkRouteEvent) {
        [self _log:@"[TouchSimulation] ❌ 获取 BKSHIDEventRouterRouteEvent 失败"];
        dlclose(_backBoardServicesHandle);
        _backBoardServicesHandle = NULL;
        return NO;
    }
    
    void *router = _bkRouterInstance();
    if (!router) {
        [self _log:@"[TouchSimulation] ❌ BKSHIDEventRouterInstance() 返回 NULL"];
        return NO;
    }
    
    _backBoardInitialized = YES;
    [self _log:@"[TouchSimulation] ✅ BackBoardServices HID 路由初始化成功"];
    return YES;
}

- (IOHIDEventRef)_createDigitizerEventWithPhase:(uint32_t)phase 
                                              x:(CGFloat)x 
                                              y:(CGFloat)y 
                                         fingerID:(uint32_t)fingerID {
    typedef IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEventFunc)(CFAllocatorRef, IOHIDEventRef, uint32_t, uint32_t, uint32_t, uint32_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
    typedef IOHIDEventRef (*IOHIDEventCreateDigitizerEventFunc)(CFAllocatorRef, uint32_t, uint64_t);
    
    static IOHIDEventCreateDigitizerEventFunc createDigitizerEvent = NULL;
    static IOHIDEventCreateDigitizerFingerEventFunc createFingerEvent = NULL;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *iohid = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (iohid) {
            createDigitizerEvent = (IOHIDEventCreateDigitizerEventFunc)dlsym(iohid, "IOHIDEventCreateDigitizerEvent");
            createFingerEvent = (IOHIDEventCreateDigitizerFingerEventFunc)dlsym(iohid, "IOHIDEventCreateDigitizerFingerEvent");
        }
    });
    
    if (!createDigitizerEvent || !createFingerEvent) {
        [self _log:@"[TouchSimulation] ❌ 获取 IOHIDEvent 创建函数失败"];
        return NULL;
    }
    
    uint64_t timestamp = (uint64_t)([[NSDate date] timeIntervalSinceReferenceDate] * 1000000000ULL);
    
    IOHIDEventRef digitizerEvent = createDigitizerEvent(NULL, 0, timestamp);
    if (!digitizerEvent) {
        [self _log:@"[TouchSimulation] ❌ 创建 DigitizerEvent 失败"];
        return NULL;
    }
    
    uint32_t touchPhase = phase;
    uint64_t xInt = (uint64_t)(x * 1000);
    uint64_t yInt = (uint64_t)(y * 1000);
    uint64_t zInt = (uint64_t)(phase == 0 ? 50 : 0);
    
    IOHIDEventRef fingerEvent = createFingerEvent(NULL, digitizerEvent, fingerID, touchPhase, 0, 0,
                                                  xInt, yInt, zInt, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    
    CFRelease(digitizerEvent);
    
    return fingerEvent;
}

- (void)_sendHIDEvent:(IOHIDEventRef)event {
    if (!event) return;
    
    void *router = _bkRouterInstance();
    if (!router) {
        [self _log:@"[TouchSimulation] ❌ 获取路由实例失败"];
        CFRelease(event);
        return;
    }
    
    _bkRouteEvent(router, event);
    CFRelease(event);
}

- (void)logDiagnostic {
    UIApplication *app = [UIApplication sharedApplication];
    if (app && app.keyWindow) {
        [self _log:[NSString stringWithFormat:@"[TouchSimulation] 📱 逻辑尺寸: %.0fx%.0f, 缩放: %.1f, 物理尺寸: %.0fx%.0f", 
            _screenSize.width, _screenSize.height, _scale,
            _screenSize.width * _scale, _screenSize.height * _scale]];
        if (_backBoardInitialized) {
            [self _log:@"[TouchSimulation] ✅ BackBoardServices HID 注入已就绪（跨进程模式）"];
        } else {
            [self _log:@"[TouchSimulation] ⚠️ BackBoardServices 未初始化，使用进程内模式"];
        }
    } else {
        [self _log:@"[TouchSimulation] ⚠️ UIApplication 尚未完全初始化"];
    }
}

- (void)_sendTouchEventAtX:(CGFloat)x y:(CGFloat)y phase:(uint32_t)phase fingerID:(uint32_t)fingerID {
    if (_backBoardInitialized) {
        IOHIDEventRef event = [self _createDigitizerEventWithPhase:phase x:x y:y fingerID:fingerID];
        if (event) {
            [self _sendHIDEvent:event];
            
            const char *phaseName = "UNKNOWN";
            switch (phase) {
                case 0: phaseName = "DOWN"; break;
                case 1: phaseName = "MOVE"; break;
                case 2: phaseName = "UP"; break;
                case 3: phaseName = "CANCEL"; break;
            }
            [self _log:[NSString stringWithFormat:@"[TouchSimulation] 🎯 HID %s x=%.0f y=%.0f finger=%u", phaseName, x, y, fingerID]];
            return;
        }
    }
    
    [self _log:@"[TouchSimulation] ⚠️ 回退到进程内模式"];
    
    CGPoint logicalPoint = CGPointMake(x / _scale, y / _scale);
    UIWindow *keyWindow = [[UIApplication sharedApplication] keyWindow];
    if (!keyWindow) return;
    
    UIView *hitView = [keyWindow hitTest:logicalPoint withEvent:nil];
    if (!hitView) hitView = keyWindow.rootViewController.view;
    
    if ([hitView respondsToSelector:@selector(sendActionsForControlEvents:)]) {
        [hitView sendActionsForControlEvents:phase == 2 ? UIControlEventTouchUpInside : UIControlEventTouchDown];
        [self _log:[NSString stringWithFormat:@"[TouchSimulation] ✅ 触发控件: %@", NSStringFromClass([hitView class])]];
    }
}

- (void)downAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    _lastX = x;
    _lastY = y;
    [self _sendTouchEventAtX:x y:y phase:0 fingerID:fingerID];
    usleep(5000);
}

- (void)moveAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    _lastX = x;
    _lastY = y;
    [self _sendTouchEventAtX:x y:y phase:1 fingerID:fingerID];
}

- (void)upFinger:(uint32_t)fingerID {
    [self _sendTouchEventAtX:_lastX y:_lastY phase:2 fingerID:fingerID];
    usleep(5000);
}

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

- (void)clickAtX:(CGFloat)x y:(CGFloat)y {
    [self tapAtX:x y:y delayMs:10 fingerID:0];
}

- (void)holdAtX:(CGFloat)x y:(CGFloat)y duration:(NSInteger)ms {
    [self downAtX:x y:y fingerID:0];
    usleep((useconds_t)(ms * 1000));
    [self upFinger:0];
}

- (void)swipeFromX:(CGFloat)x1 y:(CGFloat)y1 toX:(CGFloat)x2 y:(CGFloat)y2 duration:(NSInteger)ms {
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