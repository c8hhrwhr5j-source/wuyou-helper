//
//  TouchSimulation.m
//  无忧辅助 - 触控模拟
//

#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <math.h>
#import <unistd.h>

// ---- 动态加载的类型 (全部 void* 避免 SDK 冲突) ----
typedef void* (*fn_router_inst)(void);
typedef void  (*fn_route_event)(void*, void*);
typedef void* (*fn_create_digi)(void*, uint32_t, uint64_t);
typedef void* (*fn_create_finger)(void*, void*, uint32_t, uint32_t, uint32_t,
    uint32_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t,
    uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);

// ---- 全局状态 ----
static CGSize  _xs;   // 屏幕逻辑尺寸
static CGFloat _scl;  // 屏幕 scale
static void   *_bks;
static void   *_iok;
static fn_router_inst   _ri;
static fn_route_event   _re;
static fn_create_digi   _cd;
static fn_create_finger _cf;
static BOOL   _bksOK;

// 用函数指针绕过 ARC / CFRelease 类型检查
static void (*_rf)(void*);

// ============ TouchSlide ============
@implementation TouchSlide {
    TouchSimulation *_s;
    uint32_t _fid;
    int _st, _dly;
    CGFloat _cx, _cy;
}
- (instancetype)initWithSim:(TouchSimulation *)s fingerID:(uint32_t)fid {
    if (self = [super init]) { _s = s; _fid = fid; _st = 10; _dly = 5; }
    return self;
}
- (TouchSlide *)step:(int)v   { _st = v;  return self; }
- (TouchSlide *)delay:(int)v  { _dly = v; return self; }
- (TouchSlide *)on:(CGFloat)x y:(CGFloat)y   { _cx=x; _cy=y; [_s downAtX:x y:y fingerID:_fid]; return self; }
- (TouchSlide *)move:(CGFloat)x y:(CGFloat)y {
    CGFloat dx = x - _cx, dy = y - _cy, d = sqrt(dx*dx + dy*dy);
    int n = (int)(d / _st); if (n < 1) n = 1;
    for (int i = 1; i <= n; i++) {
        CGFloat t = (CGFloat)i / (CGFloat)n;
        [_s moveAtX:(_cx + dx*t) y:(_cy + dy*t) fingerID:_fid];
        usleep((useconds_t)(_dly * 1000));
    }
    _cx = x; _cy = y; return self;
}
- (TouchSlide *)up { [_s upFinger:_fid]; return self; }
@end

// ============ TouchSimulation ============
@implementation TouchSimulation {
    CGFloat _lx, _ly;
}

+ (instancetype)sharedInstance {
    static TouchSimulation *i;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ i = [[TouchSimulation alloc] init]; });
    return i;
}

- (instancetype)init {
    if (self = [super init]) {
        _xs  = [UIScreen mainScreen].bounds.size;
        _scl = [UIScreen mainScreen].scale;
        _lx = _ly = 0;
        _rf  = (void(*)(void*))CFRelease;
        [self _bksInit];
    }
    return self;
}

- (void)_log:(NSString *)m {
    if (self.logHandler) self.logHandler(m);
    NSLog(@"%@", m);
}

// ---- BKS 初始化 ----
- (void)_bksInit {
    if (_bksOK) return;
    _bks = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
    if (!_bks) { [self _log:@"[TS] BKS load fail"]; return; }
    _ri = (fn_router_inst)dlsym(_bks, "BKSHIDEventRouterInstance");
    if (!_ri)  { [self _log:@"[TS] RouterInstance missing"]; dlclose(_bks); _bks=NULL; return; }
    _re = (fn_route_event)dlsym(_bks, "BKSHIDEventRouterRouteEvent");
    if (!_re)  { [self _log:@"[TS] RouteEvent missing"];    dlclose(_bks); _bks=NULL; return; }
    if (!_ri()) { [self _log:@"[TS] Router NULL"]; return; }
    _bksOK = YES;
    [self _log:@"[TS] BKS ready"];
}

// ---- IOHIDEvent 构造 ----
- (void*)_mkEvent:(uint32_t)ph x:(CGFloat)x y:(CGFloat)y fid:(uint32_t)fid {
    if (!_cd || !_cf) {
        if (!_iok) _iok = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (_iok) {
            _cd = (fn_create_digi)  dlsym(_iok, "IOHIDEventCreateDigitizerEvent");
            _cf = (fn_create_finger)dlsym(_iok, "IOHIDEventCreateDigitizerFingerEvent");
        }
    }
    if (!_cd || !_cf) { [self _log:@"[TS] IOHID funcs missing"]; return NULL; }
    uint64_t ts = (uint64_t)([[NSDate date] timeIntervalSinceReferenceDate] * 1e9);
    void *d = _cd(NULL, 0, ts);
    if (!d) { [self _log:@"[TS] digitizer fail"]; return NULL; }
    uint32_t m = (ph == 0) ? 1 : 0;
    void *f = _cf(NULL, d, fid, m, 0, 0,
        (uint64_t)(x*1000.0), (uint64_t)(y*1000.0),
        (uint64_t)(ph == 0 ? 50 : 0), 0,0,0,0,0,0,0,0,0);
    _rf(d);
    return f;
}

// ---- 发送事件 ----
- (void)_route:(void*)e {
    if (!e) return;
    void *r = _ri();
    if (!r) { [self _log:@"[TS] no router"]; _rf(e); return; }
    _re(r, e);
    _rf(e);
}

// ---- 诊断 ----
- (void)logDiagnostic {
    [self _log:[NSString stringWithFormat:@"[TS] logic:%.0fx%.0f scale:%.1f phys:%.0fx%.0f",
        _xs.width, _xs.height, _scl, _xs.width*_scl, _xs.height*_scl]];
    [self _log:_bksOK ? @"[TS] HID cross-process OK" : @"[TS] HID NOT ready"];
}

// ---- 从 hitTest 结果向上寻找最近的 UIControl ----
static UIControl *_findControl(UIView *start) {
    UIView *v = start;
    while (v) {
        if ([v isKindOfClass:[UIControl class]]) return (UIControl *)v;
        v = v.superview;
    }
    return nil;
}

// ---- 通过 touchesBegan/Ended 模拟触摸（非 UIControl 回退） ----
static void _simulateTouch(UIView *view, CGPoint locationInWindow, UITouchPhase phase) {
    // 尝试用私有 API 创建 UITouch
    Class UITouchClass = NSClassFromString(@"UITouch");
    if (!UITouchClass) return;
    id touch = [[UITouchClass alloc] init];
    if (!touch) return;

    // _setIsTap: / setPhase: / setTimestamp: / _setLocationInWindow:resetPrevious:
    SEL setPhase = NSSelectorFromString(@"setPhase:");
    SEL setTimestamp = NSSelectorFromString(@"setTimestamp:");
    SEL setLocation = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");
    SEL setWindow = NSSelectorFromString(@"setWindow:");
    SEL setView = NSSelectorFromString(@"setView:");
    SEL setIsTap = NSSelectorFromString(@"_setIsTap:");

    NSTimeInterval ts = [[NSProcessInfo processInfo] systemUptime];
    if ([touch respondsToSelector:setTimestamp]) {
        // Use NSInvocation for double arg
        NSMethodSignature *sig = [touch methodSignatureForSelector:setTimestamp];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:touch];
        [inv setSelector:setTimestamp];
        [inv setArgument:&ts atIndex:2];
        [inv invoke];
    }
    if ([touch respondsToSelector:setWindow]) {
        id win = view.window;
        NSMethodSignature *s = [touch methodSignatureForSelector:setWindow];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:s];
        [inv setTarget:touch]; [inv setSelector:setWindow];
        [inv setArgument:&win atIndex:2]; [inv invoke];
    }
    if ([touch respondsToSelector:setView]) {
        NSMethodSignature *s = [touch methodSignatureForSelector:setView];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:s];
        [inv setTarget:touch]; [inv setSelector:setView];
        [inv setArgument:&view atIndex:2]; [inv invoke];
    }
    if ([touch respondsToSelector:setLocation]) {
        BOOL reset = YES;
        NSMethodSignature *s = [touch methodSignatureForSelector:setLocation];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:s];
        [inv setTarget:touch]; [inv setSelector:setLocation];
        [inv setArgument:&locationInWindow atIndex:2];
        [inv setArgument:&reset atIndex:3]; [inv invoke];
    }
    if ([touch respondsToSelector:setIsTap]) {
        BOOL isTap = (phase == UITouchPhaseEnded);
        NSMethodSignature *s = [touch methodSignatureForSelector:setIsTap];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:s];
        [inv setTarget:touch]; [inv setSelector:setIsTap];
        [inv setArgument:&isTap atIndex:2]; [inv invoke];
    }
    if ([touch respondsToSelector:setPhase]) {
        NSInteger p = (NSInteger)phase;
        NSMethodSignature *sig = [touch methodSignatureForSelector:setPhase];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:touch];
        [inv setSelector:setPhase];
        [inv setArgument:&p atIndex:2];
        [inv invoke];
    }

    // 创建 UIEvent (尽量空事件即可)
    Class UIEventClass = NSClassFromString(@"UIEvent");
    id event = UIEventClass ? [[UIEventClass alloc] init] : nil;
    if ([event respondsToSelector:setTimestamp]) {
        NSMethodSignature *sig = [event methodSignatureForSelector:setTimestamp];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:event];
        [inv setSelector:setTimestamp];
        [inv setArgument:&ts atIndex:2];
        [inv invoke];
    }

    NSSet *touches = [NSSet setWithObject:touch];
    if (phase == UITouchPhaseBegan) {
        [view touchesBegan:touches withEvent:event];
    } else if (phase == UITouchPhaseMoved) {
        [view touchesMoved:touches withEvent:event];
    } else if (phase == UITouchPhaseEnded) {
        [view touchesEnded:touches withEvent:event];
    } else if (phase == UITouchPhaseCancelled) {
        [view touchesCancelled:touches withEvent:event];
    }
}

// ---- 核心发送 ----
- (void)_send:(CGFloat)x y:(CGFloat)y ph:(uint32_t)ph fid:(uint32_t)fid {
    if (_bksOK) {
        void *e = [self _mkEvent:ph x:x y:y fid:fid];
        if (e) { [self _route:e]; return; }
    }
    // 回退：进程内点击
    CGPoint p = CGPointMake(x/_scl, y/_scl);
    UIWindow *w = [[UIApplication sharedApplication] keyWindow];
    if (!w) return;

    UIView *hit = [w hitTest:p withEvent:nil];
    if (!hit) hit = w.rootViewController.view;
    if (!hit) return;

    UIControl *ctrl = _findControl(hit);
    if (ctrl) {
        if (ph == 0) {
            [ctrl sendActionsForControlEvents:UIControlEventTouchDown];
        } else if (ph == 2) {
            [ctrl sendActionsForControlEvents:UIControlEventTouchUpInside];
            [self _log:[NSString stringWithFormat:@"[TS] ✅ clicked %@", ctrl]];
        }
        return;
    }
    // 非 UIControl：使用 touchesBegan/Ended 模拟
    if (ph == 0)
        _simulateTouch(hit, p, UITouchPhaseBegan);
    else if (ph == 2) {
        _simulateTouch(hit, p, UITouchPhaseEnded);
        [self _log:[NSString stringWithFormat:@"[TS] ✅ touched %@ at %.0f,%.0f", hit, x, y]];
    }
}

// ---- 原子操作 ----
- (void)downAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fid  { _lx=x; _ly=y; [self _send:x y:y ph:0 fid:fid]; usleep(5000); }
- (void)moveAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fid  { _lx=x; _ly=y; [self _send:x y:y ph:1 fid:fid]; }
- (void)upFinger:(uint32_t)fid                                  { [self _send:_lx y:_ly ph:2 fid:fid]; usleep(5000); }

// ---- 高级封装 ----
- (void)tapAtX:(CGFloat)x y:(CGFloat)y delayMs:(int)ms fingerID:(uint32_t)fid {
    [self downAtX:x y:y fingerID:fid]; usleep((useconds_t)(ms*1000)); [self upFinger:fid];
}
- (void)tapRandomAtX:(CGFloat)x y:(CGFloat)y range:(int)r delayMs:(int)ms fingerID:(uint32_t)fid {
    [self tapAtX:(x + (int)arc4random_uniform((uint32_t)(r*2+1)) - r)
                y:(y + (int)arc4random_uniform((uint32_t)(r*2+1)) - r)
          delayMs:ms fingerID:fid];
}
- (TouchSlide *)slideWithFingerID:(uint32_t)fid { return [[TouchSlide alloc] initWithSim:self fingerID:fid]; }

// ---- 兼容旧接口 ----
- (void)clickAtX:(CGFloat)x y:(CGFloat)y                      { [self tapAtX:x y:y delayMs:10 fingerID:0]; }
- (void)holdAtX:(CGFloat)x y:(CGFloat)y duration:(NSInteger)m { [self downAtX:x y:y fingerID:0]; usleep((useconds_t)(m*1000)); [self upFinger:0]; }
- (void)swipeFromX:(CGFloat)x1 y:(CGFloat)y1 toX:(CGFloat)x2 y:(CGFloat)y2 duration:(NSInteger)ms {
    TouchSlide *s = [self slideWithFingerID:0]; [s step:5];
    CGFloat d = fmax(fabs(x2-x1), fabs(y2-y1));
    [s delay:(int)(ms / (d/5 > 5 ? d/5 : 5))];
    [s on:x1 y:y1]; [s move:x2 y:y2]; [s up];
}

@end
