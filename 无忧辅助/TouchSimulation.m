//
//  TouchSimulation.m
//  无忧辅助 - 三重触控策略（Accessibility > IOHID > 进程内）
//

#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <math.h>
#import <unistd.h>

// ============================================================
// TouchSlide
// ============================================================
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

// ============================================================
// Accessibility 策略 — 系统级跨进程触摸
// 全部通过 dlsym 动态加载，无需显式链接 ApplicationServices
// ============================================================
typedef const struct __AXUIElement *AXUIElementRef;
typedef int32_t AXError;
#define kAXErrorSuccess 0
static BOOL _axReady = NO;
static AXUIElementRef (*_axSysWide)(void) = NULL;
static AXError (*_axCopyAtPos)(AXUIElementRef, float, float, AXUIElementRef*) = NULL;
static AXError (*_axPerform)(AXUIElementRef, CFStringRef) = NULL;

static void _axSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // iOS Accessibility API 在多个私有框架中，按顺序尝试
        const char *paths[] = {
            "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
            "/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility",
            "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
            "/System/Library/PrivateFrameworks/AccessibilityUI.framework/AccessibilityUI",
            NULL
        };
        for (int i = 0; paths[i]; i++) {
            void *h = dlopen(paths[i], RTLD_NOW);
            if (!h) continue;
            _axSysWide   = (AXUIElementRef (*)(void))dlsym(h, "AXUIElementCreateSystemWide");
            _axCopyAtPos = (AXError (*)(AXUIElementRef, float, float, AXUIElementRef*))dlsym(h, "AXUIElementCopyElementAtPosition");
            _axPerform   = (AXError (*)(AXUIElementRef, CFStringRef))dlsym(h, "AXUIElementPerformAction");
            if (_axSysWide && _axCopyAtPos && _axPerform) {
                NSLog(@"[TS] ✅ AX loaded from %s", paths[i]);
                break;
            }
            _axSysWide = _axCopyAtPos = NULL; _axPerform = NULL;
            dlclose(h);
        }
        _axReady = (_axSysWide && _axCopyAtPos && _axPerform);
        if (_axReady) {
            NSLog(@"[TS] ✅ AX API 就绪");
        } else {
            NSLog(@"[TS] ⚠️ AX API 不可用（所有路径均失败，将仅用 IOHID）");
        }
    });
}

// 通过 AX 找到并点击某个坐标下的元素
static BOOL _axTapAt(CGFloat x, CGFloat y) {
    _axSetup();
    if (!_axReady) return NO;

    AXUIElementRef sysWide = _axSysWide();
    if (!sysWide) return NO;

    CGPoint pt = CGPointMake(x, y);
    AXUIElementRef element = NULL;
    AXError err = _axCopyAtPos(sysWide, (float)pt.x, (float)pt.y, &element);
    CFRelease(sysWide);

    if (err != kAXErrorSuccess || !element) {
        if (element) CFRelease(element);
        return NO;
    }

    // kAXPressAction = CFSTR("AXPress"), kAXPickAction = CFSTR("AXPick")
    err = _axPerform(element, CFSTR("AXPress"));
    if (err == kAXErrorSuccess) {
        NSLog(@"[TS] ⚡ AX press at (%.0f,%.0f) ✅", x, y);
    } else {
        err = _axPerform(element, CFSTR("AXPick"));
        if (err == kAXErrorSuccess) {
            NSLog(@"[TS] ⚡ AX pick at (%.0f,%.0f) ✅", x, y);
        }
    }

    CFRelease(element);
    return (err == kAXErrorSuccess);
}

// ============================================================
// IOHIDEvent 策略 — BackBoardServices 路由
// ============================================================
typedef void* (*BKS_RI)(void);
typedef void  (*BKS_RE)(void*, void*);
typedef void* (*HID_Digi)(void*, uint32_t, uint64_t);
typedef void* (*HID_Finger)(void*, void*, uint32_t, uint32_t, uint32_t, uint32_t,
    uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t,
    uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);

static void  *_bksH, *_iokH;
static BKS_RI   _ri;
static BKS_RE   _re;
static HID_Digi _cd;
static HID_Finger _cf;
static BOOL _bksOK;

static void (*_rf)(void*);

static BOOL _bksInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _rf = (void(*)(void*))CFRelease;
        _bksH = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        if (_bksH) {
            _ri = (BKS_RI)dlsym(_bksH, "BKSHIDEventRouterInstance");
            _re = (BKS_RE)dlsym(_bksH, "BKSHIDEventRouterRouteEvent");
        }
        _iokH = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (_iokH) {
            _cd = (HID_Digi)dlsym(_iokH, "IOHIDEventCreateDigitizerEvent");
            _cf = (HID_Finger)dlsym(_iokH, "IOHIDEventCreateDigitizerFingerEvent");
        }
        if (_ri && _re && _ri() && _cd && _cf) {
            _bksOK = YES;
            NSLog(@"[TS] ✅ IOHIDEvent 路由就绪");
        } else {
            NSLog(@"[TS] ⚠️ IOHIDEvent 路由不可用");
        }
    });
    return _bksOK;
}

static void _hidTap(CGFloat x, CGFloat y) {
    if (!_bksInit()) return;
    uint64_t ts = (uint64_t)([[NSDate date] timeIntervalSinceReferenceDate] * 1e9);
    void *d = _cd(NULL, 0, ts);
    if (!d) return;
    void *fDown = _cf(NULL, d, 0, 1, 0, 0, (uint64_t)(x*1000), (uint64_t)(y*1000), 50, 0,0,0,0,0,0,0,0,0);
    void *router = _ri();
    if (router && fDown) {
        _re(router, fDown);
        _rf(fDown);
    }
    _rf(d);
    usleep(10000);
    d = _cd(NULL, 0, ts + 10000000);
    if (!d) return;
    void *fUp = _cf(NULL, d, 0, 0, 0, 0, (uint64_t)(x*1000), (uint64_t)(y*1000), 0, 0,0,0,0,0,0,0,0,0);
    if (router && fUp) {
        _re(router, fUp);
        _rf(fUp);
        NSLog(@"[TS] ⚡ HID at (%.0f,%.0f)", x, y);
    }
    _rf(d);
}

// ============================================================
// TouchSimulation
// ============================================================
@implementation TouchSimulation {
    CGFloat _lx, _ly;
    CGSize  _xs;
    CGFloat _scl;
}

+ (instancetype)sharedInstance {
    static TouchSimulation *i;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ i = [[TouchSimulation alloc] init]; });
    return i;
}

- (instancetype)init {
    if (self = [super init]) {
        _xs = [UIScreen mainScreen].bounds.size;
        _scl = [UIScreen mainScreen].scale;
        _lx = _ly = 0;
    }
    return self;
}

- (void)_log:(NSString *)m {
    if (self.logHandler) self.logHandler(m);
    NSLog(@"%@", m);
}

- (void)logDiagnostic {
    [self _log:[NSString stringWithFormat:@"[TS] logic:%.0fx%.0f scale:%.1f phys:%.0fx%.0f",
        _xs.width, _xs.height, _scl, _xs.width*_scl, _xs.height*_scl]];
    _axSetup();
    [self _log:_axReady ? @"[TS] ✅ AX 可用（跨进程优先）" : @"[TS] ⚠️ AX 不可用"];
    if (_bksInit()) {
        [self _log:@"[TS] ✅ HID 路由就绪"];
    }
}

// ---- 核心点击逻辑：AX > HID > 进程内 ----
- (void)_doTapAtX:(CGFloat)x y:(CGFloat)y {
    // 策略 1: Accessibility (最可靠，真正的跨进程)
    if (_axTapAt(x, y)) return;

    // 策略 2: IOHIDEvent (BackBoardServices)
    _hidTap(x, y);

    // 策略 3 不需要，因为上面两种都是系统级
}

// ---- 原子操作 ----
- (void)downAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fid {
    _lx = x; _ly = y;
    [self _doTapAtX:x y:y];
    usleep(5000);
}

- (void)moveAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fid {
    _lx = x; _ly = y;
    usleep(5000);
}

- (void)upFinger:(uint32_t)fid {
    usleep(5000);
}

- (void)tapAtX:(CGFloat)x y:(CGFloat)y delayMs:(int)ms fingerID:(uint32_t)fid {
    [self _doTapAtX:x y:y];
    usleep((useconds_t)(ms * 1000));
}

- (void)tapRandomAtX:(CGFloat)x y:(CGFloat)y range:(int)r delayMs:(int)ms fingerID:(uint32_t)fid {
    int ox = (int)arc4random_uniform((uint32_t)(r*2+1)) - r;
    int oy = (int)arc4random_uniform((uint32_t)(r*2+1)) - r;
    [self tapAtX:(x+ox) y:(y+oy) delayMs:ms fingerID:fid];
}

- (TouchSlide *)slideWithFingerID:(uint32_t)fid {
    return [[TouchSlide alloc] initWithSim:self fingerID:fid];
}

- (void)clickAtX:(CGFloat)x y:(CGFloat)y {
    [self _doTapAtX:x y:y];
}

- (void)holdAtX:(CGFloat)x y:(CGFloat)y duration:(NSInteger)ms {
    [self _doTapAtX:x y:y];
    usleep((useconds_t)(ms * 1000));
}

- (void)swipeFromX:(CGFloat)x1 y:(CGFloat)y1 toX:(CGFloat)x2 y:(CGFloat)y2 duration:(NSInteger)ms {
    TouchSlide *s = [self slideWithFingerID:0]; [s step:5];
    CGFloat d = fmax(fabs(x2-x1), fabs(y2-y1));
    [s delay:(int)(ms / (d/5 > 5 ? d/5 : 5))];
    [s on:x1 y:y1]; [s move:x2 y:y2]; [s up];
}

@end
