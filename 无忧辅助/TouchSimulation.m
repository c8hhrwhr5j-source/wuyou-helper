//
//  TouchSimulation.m
//  无忧辅助 - BackBoardServices HID 事件注入（TrollStore 跨进程点击方案）
//

#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <math.h>
#import <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"

static CGSize _screenSize = {0, 0};
static CGFloat _scale = 1.0;

// 全部使用 void* 避免与任何 SDK 类型冲突
typedef void* (*BKS_RouterInstance)(void);
typedef void  (*BKS_RouteEvent)(void*, void*);
typedef void* (*HID_CreateDigitizerEvent)(void*, uint32_t, uint64_t);
typedef void* (*HID_CreateDigitizerFingerEvent)(void*, void*, uint32_t, uint32_t, uint32_t, uint32_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);

static void *_bksHandle      = NULL;
static void *_ioKitHandle    = NULL;
static BKS_RouterInstance    _routerInstance = NULL;
static BKS_RouteEvent        _routeEvent     = NULL;
static HID_CreateDigitizerEvent       _createDigitizerEvent = NULL;
static HID_CreateDigitizerFingerEvent _createFingerEvent    = NULL;

static BOOL _bksReady = NO;

// CFRelease 的函数指针，避免类型不匹配
static void (*_releaseCF)(void*) = NULL;

@interface TouchSimulation ()
- (BOOL)_initBKS;
- (void*)_makeDigitizerEvent:(uint32_t)phase x:(CGFloat)x y:(CGFloat)y finger:(uint32_t)fid;
- (void)_routeEvent:(void*)event;
@end

// ============================================================
// TouchSlide
// ============================================================
@implementation TouchSlide {
    TouchSimulation *_sim;
    uint32_t _fid;
    int _step, _delayMs;
    CGFloat _cx, _cy;
}
- (instancetype)initWithSim:(TouchSimulation *)s fingerID:(uint32_t)fid {
    if (self = [super init]) { _sim = s; _fid = fid; _step = 10; _delayMs = 5; }
    return self;
}
- (TouchSlide *)step:(int)s   { _step = s;    return self; }
- (TouchSlide *)delay:(int)d  { _delayMs = d; return self; }
- (TouchSlide *)on:(CGFloat)x y:(CGFloat)y { _cx=x; _cy=y; [_sim downAtX:x y:y fingerID:_fid]; return self; }
- (TouchSlide *)move:(CGFloat)x y:(CGFloat)y {
    CGFloat dx = x - _cx, dy = y - _cy;
    CGFloat dist = sqrt(dx*dx + dy*dy);
    int steps = (int)(dist / _step); if (steps < 1) steps = 1;
    for (int i = 1; i <= steps; i++) {
        CGFloat r = (CGFloat)i / (CGFloat)steps;
        [_sim moveAtX:(_cx + dx*r) y:(_cy + dy*r) fingerID:_fid];
        usleep((useconds_t)(_delayMs * 1000));
    }
    _cx = x; _cy = y; return self;
}
- (TouchSlide *)up { [_sim upFinger:_fid]; return self; }
@end

// ============================================================
// TouchSimulation
// ============================================================
@implementation TouchSimulation {
    CGFloat _lx, _ly;
    BOOL _initd;
}

+ (instancetype)sharedInstance {
    static TouchSimulation *inst;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{ inst = [[TouchSimulation alloc] init]; });
    return inst;
}

- (instancetype)init {
    if (self = [super init]) {
        _screenSize = [UIScreen mainScreen].bounds.size;
        _scale      = [UIScreen mainScreen].scale;
        _lx = _ly   = 0;
        _initd      = YES;
        // 初始化 CFRelease 函数指针
        _releaseCF  = (void(*)(void*))CFRelease;
        [self _initBKS];
    }
    return self;
}

- (void)_log:(NSString *)m {
    if (self.logHandler) self.logHandler(m);
    NSLog(@"%@", m);
}

// ---- BKS 初始化 -------------------------------------------------
- (BOOL)_initBKS {
    if (_bksReady) return YES;
    _bksHandle = dlopen(
        "/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
        RTLD_NOW);
    if (!_bksHandle) {
        [self _log:@"[TouchSimulation] ❌ 加载 BackBoardServices 失败"]; return NO;
    }
    _routerInstance = (BKS_RouterInstance)dlsym(_bksHandle, "BKSHIDEventRouterInstance");
    if (!_routerInstance) {
        [self _log:@"[TouchSimulation] ❌ BKSHIDEventRouterInstance 缺失"];
        dlclose(_bksHandle); _bksHandle = NULL; return NO;
    }
    _routeEvent     = (BKS_RouteEvent)dlsym(_bksHandle, "BKSHIDEventRouterRouteEvent");
    if (!_routeEvent) {
        [self _log:@"[TouchSimulation] ❌ BKSHIDEventRouterRouteEvent 缺失"];
        dlclose(_bksHandle); _bksHandle = NULL; return NO;
    }
    if (!_routerInstance()) {
        [self _log:@"[TouchSimulation] ❌ 路由实例为 NULL"]; return NO;
    }
    _bksReady = YES;
    [self _log:@"[TouchSimulation] ✅ BackBoardServices HID 路由就绪"];
    return YES;
}

// ---- 构造 IOHIDEvent --------------------------------------------
- (void*)_makeDigitizerEvent:(uint32_t)phase x:(CGFloat)x y:(CGFloat)y finger:(uint32_t)fid {
    if (!_createDigitizerEvent || !_createFingerEvent) {
        if (!_ioKitHandle)
            _ioKitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (_ioKitHandle) {
            _createDigitizerEvent = (HID_CreateDigitizerEvent)dlsym(_ioKitHandle, "IOHIDEventCreateDigitizerEvent");
            _createFingerEvent    = (HID_CreateDigitizerFingerEvent)dlsym(_ioKitHandle, "IOHIDEventCreateDigitizerFingerEvent");
        }
    }
    if (!_createDigitizerEvent || !_createFingerEvent) {
        [self _log:@"[TouchSimulation] ❌ IOHIDEvent 创建函数不可用"]; return NULL;
    }

    uint64_t ts = (uint64_t)([[NSDate date] timeIntervalSinceReferenceDate] * 1000000000ULL);
    void *digi = _createDigitizerEvent(NULL, (uint32_t)0, ts);
    if (!digi) { [self _log:@"[TouchSimulation] ❌ DigitizerEvent 创建失败"]; return NULL; }

    uint64_t xi = (uint64_t)(x * 1000.0);
    uint64_t yi = (uint64_t)(y * 1000.0);
    uint32_t mask = (phase == 0) ? 1 : 0;

    void *finger = _createFingerEvent(NULL, digi,
        fid, mask,              // finger index, touch mask
        (uint32_t)0,            // identifier
        (uint32_t)0,            // quality
        xi, yi,                 // x, y
        (uint64_t)(phase == 0 ? 50 : 0),  // z pressure
        (uint64_t)0, (uint64_t)0, (uint64_t)0, (uint64_t)0,  // twist, radii
        (uint64_t)0, (uint64_t)0, (uint64_t)0, (uint64_t)0, (uint64_t)0);

    _releaseCF(digi);
    return finger;
}

// ---- 发送 HID 事件 ----------------------------------------------
- (void)_routeEvent:(void*)ev {
    if (!ev) return;
    void *r = _routerInstance();
    if (!r) { [self _log:@"[TouchSimulation] ❌ 路由实例不可用"]; _releaseCF(ev); return; }
    _routeEvent(r, ev);
    _releaseCF(ev);
}

// ---- 诊断 -------------------------------------------------------
- (void)logDiagnostic {
    [self _log:[NSString stringWithFormat:
        @"[TouchSimulation] 📱 逻辑: %.0fx%.0f 缩放: %.1f 物理: %.0fx%.0f",
        _screenSize.width, _screenSize.height, _scale,
        _screenSize.width*_scale, _screenSize.height*_scale]];
    [self _log:_bksReady
        ? @"[TouchSimulation] ✅ HID 注入就绪（跨进程）"
        : @"[TouchSimulation] ⚠️ 未初始化，使用进程内模式"];
}

// ---- 核心触摸发送 ------------------------------------------------
- (void)_send:(CGFloat)x y:(CGFloat)y phase:(uint32_t)ph finger:(uint32_t)fid {
    if (_bksReady) {
        void *ev = [self _makeDigitizerEvent:ph x:x y:y finger:fid];
        if (ev) {
            [self _routeEvent:ev];
            static const char *names[] = {"DOWN","MOVE","UP","CANCEL"};
            [self _log:[NSString stringWithFormat:
                @"[TouchSimulation] 🎯 HID %s x=%.0f y=%.0f f=%u",
                ph < 4 ? names[ph] : "?", x, y, fid]];
            return;
        }
    }
    // 回退：进程内模式
    [self _log:@"[TouchSimulation] ⚠️ 回退进程内模式"];
    CGPoint pt = CGPointMake(x/_scale, y/_scale);
    UIWindow *kw = [[UIApplication sharedApplication] keyWindow];
    if (!kw) return;
    UIView *v = [kw hitTest:pt withEvent:nil] ?: kw.rootViewController.view;
    if ([v respondsToSelector:@selector(sendActionsForControlEvents:)])
        [v sendActionsForControlEvents:ph == 2 ? UIControlEventTouchUpInside : UIControlEventTouchDown];
}

// ---- 原子操作 ----------------------------------------------------
- (void)downAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fid { _lx=x; _ly=y; [self _send:x y:y phase:0 finger:fid]; usleep(5000); }
- (void)moveAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fid { _lx=x; _ly=y; [self _send:x y:y phase:1 finger:fid]; }
- (void)upFinger:(uint32_t)fid                                { [self _send:_lx y:_ly phase:2 finger:fid]; usleep(5000); }

// ---- 高级封装 ----------------------------------------------------
- (void)tapAtX:(CGFloat)x y:(CGFloat)y delayMs:(int)ms fingerID:(uint32_t)fid {
    [self downAtX:x y:y fingerID:fid]; usleep((useconds_t)(ms*1000)); [self upFinger:fid];
}
- (void)tapRandomAtX:(CGFloat)x y:(CGFloat)y range:(int)r delayMs:(int)ms fingerID:(uint32_t)fid {
    int ox = (int)arc4random_uniform((uint32_t)(r*2+1)) - r;
    int oy = (int)arc4random_uniform((uint32_t)(r*2+1)) - r;
    [self tapAtX:(x+ox) y:(y+oy) delayMs:ms fingerID:fid];
}
- (TouchSlide *)slideWithFingerID:(uint32_t)fid { return [[TouchSlide alloc] initWithSim:self fingerID:fid]; }

// ---- 兼容旧接口 --------------------------------------------------
- (void)clickAtX:(CGFloat)x y:(CGFloat)y                    { [self tapAtX:x y:y delayMs:10 fingerID:0]; }
- (void)holdAtX:(CGFloat)x y:(CGFloat)y duration:(NSInteger)ms { [self downAtX:x y:y fingerID:0]; usleep((useconds_t)(ms*1000)); [self upFinger:0]; }
- (void)swipeFromX:(CGFloat)x1 y:(CGFloat)y1 toX:(CGFloat)x2 y:(CGFloat)y2 duration:(NSInteger)ms {
    TouchSlide *s = [self slideWithFingerID:0]; [s step:5];
    CGFloat d = fmax(fabs(x2-x1), fabs(y2-y1));
    [s delay:(int)(ms / (d/5 > 5 ? d/5 : 5))];
    [s on:x1 y:y1]; [s move:x2 y:y2]; [s up];
}

#pragma clang diagnostic pop
@end
