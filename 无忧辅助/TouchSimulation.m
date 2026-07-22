//
//  TouchSimulation.m
//  无忧辅助 - 进程内原生触摸事件注入（TrollStore 静态 Dylib 方案）
//

#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <stdlib.h>
#import <math.h>
#import <unistd.h>

static CGSize _screenSize = {0, 0};
static CGFloat _scale = 1.0;
static uint32_t _fingerSeq = 1000;

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
    BOOL _initialized;
    NSMutableDictionary *_touchCache;
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
        _lastIdentity = 0;
        _initialized = YES;
        _touchCache = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)_log:(NSString *)msg {
    if (self.logHandler) {
        self.logHandler(msg);
    }
    NSLog(@"%@", msg);
}

- (CGPoint)_convertToLogicalPoint:(CGPoint)physicalPoint {
    return CGPointMake(physicalPoint.x / _scale, physicalPoint.y / _scale);
}

// 设置 UITouch 的关键私有属性
- (void)_configureTouch:(UITouch *)touch 
                  atX:(CGFloat)x 
                  atY:(CGFloat)y 
                phase:(UITouchPhase)phase 
                fingerID:(uint32_t)fingerID {
    UIWindow *keyWindow = [[UIApplication sharedApplication] keyWindow];
    if (!keyWindow) return;
    
    CGPoint logicalPoint = [self _convertToLogicalPoint:CGPointMake(x, y)];
    UIView *hitView = [keyWindow hitTest:logicalPoint withEvent:nil];
    if (!hitView) hitView = keyWindow.rootViewController.view;
    
    NSTimeInterval now = [[NSDate date] timeIntervalSinceReferenceDate];
    
    SEL setLocationSEL = NSSelectorFromString(@"setLocation:inView:");
    if ([touch respondsToSelector:setLocationSEL]) {
        IMP imp = [touch methodForSelector:setLocationSEL];
        void (*setLocation)(id, SEL, CGPoint, UIView *) = (void (*)(id, SEL, CGPoint, UIView *))imp;
        if (setLocation) setLocation(touch, setLocationSEL, logicalPoint, hitView);
    }
    
    SEL setPhaseSEL = NSSelectorFromString(@"_setPhase:");
    if ([touch respondsToSelector:setPhaseSEL]) {
        IMP imp = [touch methodForSelector:setPhaseSEL];
        void (*setPhase)(id, SEL, UITouchPhase) = (void (*)(id, SEL, UITouchPhase))imp;
        if (setPhase) setPhase(touch, setPhaseSEL, phase);
    }
    
    SEL setIdentitySEL = NSSelectorFromString(@"_setIdentity:");
    if ([touch respondsToSelector:setIdentitySEL]) {
        IMP imp = [touch methodForSelector:setIdentitySEL];
        void (*setIdentity)(id, SEL, NSInteger) = (void (*)(id, SEL, NSInteger))imp;
        if (setIdentity) setIdentity(touch, setIdentitySEL, (NSInteger)(fingerID + 1));
    }
    
    SEL setTapCountSEL = NSSelectorFromString(@"_setTapCount:");
    if ([touch respondsToSelector:setTapCountSEL]) {
        IMP imp = [touch methodForSelector:setTapCountSEL];
        void (*setTapCount)(id, SEL, NSInteger) = (void (*)(id, SEL, NSInteger))imp;
        if (setTapCount) setTapCount(touch, setTapCountSEL, 1);
    }
    
    SEL setViewSEL = NSSelectorFromString(@"_setView:");
    if ([touch respondsToSelector:setViewSEL]) {
        IMP imp = [touch methodForSelector:setViewSEL];
        void (*setView)(id, SEL, UIView *) = (void (*)(id, SEL, UIView *))imp;
        if (setView) setView(touch, setViewSEL, hitView);
    }
    
    SEL setWindowSEL = NSSelectorFromString(@"_setWindow:");
    if ([touch respondsToSelector:setWindowSEL]) {
        IMP imp = [touch methodForSelector:setWindowSEL];
        void (*setWindow)(id, SEL, UIWindow *) = (void (*)(id, SEL, UIWindow *))imp;
        if (setWindow) setWindow(touch, setWindowSEL, keyWindow);
    }
    
    SEL setGestureViewSEL = NSSelectorFromString(@"_setGestureView:");
    if ([touch respondsToSelector:setGestureViewSEL]) {
        IMP imp = [touch methodForSelector:setGestureViewSEL];
        void (*setGestureView)(id, SEL, UIView *) = (void (*)(id, SEL, UIView *))imp;
        if (setGestureView) setGestureView(touch, setGestureViewSEL, hitView);
    }
    
    SEL setGestureWindowSEL = NSSelectorFromString(@"_setGestureWindow:");
    if ([touch respondsToSelector:setGestureWindowSEL]) {
        IMP imp = [touch methodForSelector:setGestureWindowSEL];
        void (*setGestureWindow)(id, SEL, UIWindow *) = (void (*)(id, SEL, UIWindow *))imp;
        if (setGestureWindow) setGestureWindow(touch, setGestureWindowSEL, keyWindow);
    }
    
    SEL setTimestampSEL = NSSelectorFromString(@"_setTimestamp:");
    if ([touch respondsToSelector:setTimestampSEL]) {
        IMP imp = [touch methodForSelector:setTimestampSEL];
        void (*setTimestamp)(id, SEL, NSTimeInterval) = (void (*)(id, SEL, NSTimeInterval))imp;
        if (setTimestamp) setTimestamp(touch, setTimestampSEL, now);
    }
    
    SEL setLastUpdateTimestampSEL = NSSelectorFromString(@"_setLastUpdateTimestamp:");
    if ([touch respondsToSelector:setLastUpdateTimestampSEL]) {
        IMP imp = [touch methodForSelector:setLastUpdateTimestampSEL];
        void (*setLastUpdateTimestamp)(id, SEL, NSTimeInterval) = (void (*)(id, SEL, NSTimeInterval))imp;
        if (setLastUpdateTimestamp) setLastUpdateTimestamp(touch, setLastUpdateTimestampSEL, now);
    }
    
    SEL setLocationInWindowSEL = NSSelectorFromString(@"_setLocationInWindow:");
    if ([touch respondsToSelector:setLocationInWindowSEL]) {
        IMP imp = [touch methodForSelector:setLocationInWindowSEL];
        void (*setLocationInWindow)(id, SEL, CGPoint) = (void (*)(id, SEL, CGPoint))imp;
        if (setLocationInWindow) setLocationInWindow(touch, setLocationInWindowSEL, logicalPoint);
    }
}

// 创建或复用 UITouch 对象
- (UITouch *)_getOrCreateTouchForFingerID:(uint32_t)fingerID {
    NSString *key = [NSString stringWithFormat:@"finger_%u", fingerID];
    UITouch *touch = [_touchCache objectForKey:key];
    
    if (!touch) {
        touch = [[UITouch alloc] init];
        [_touchCache setObject:touch forKey:key];
    }
    
    return touch;
}

// 释放 UITouch 对象
- (void)_releaseTouchForFingerID:(uint32_t)fingerID {
    NSString *key = [NSString stringWithFormat:@"finger_%u", fingerID];
    [_touchCache removeObjectForKey:key];
}

- (UIEvent *)_createEventWithTouches:(NSArray *)touches phase:(UITouchPhase)phase {
    UIEvent *event = [[UIEvent alloc] init];
    
    SEL setEventTypeSEL = NSSelectorFromString(@"_setEventType:");
    if ([event respondsToSelector:setEventTypeSEL]) {
        IMP imp = [event methodForSelector:setEventTypeSEL];
        void (*setEventType)(id, SEL, NSInteger) = (void (*)(id, SEL, NSInteger))imp;
        if (setEventType) setEventType(event, setEventTypeSEL, UIEventTypeTouches);
    }
    
    NSMutableSet *touchSet = [NSMutableSet setWithArray:touches];
    SEL setTouchesSEL = NSSelectorFromString(@"_setTouches:forPhase:");
    if ([event respondsToSelector:setTouchesSEL]) {
        IMP imp = [event methodForSelector:setTouchesSEL];
        void (*setTouches)(id, SEL, NSSet *, UITouchPhase) = (void (*)(id, SEL, NSSet *, UITouchPhase))imp;
        if (setTouches) setTouches(event, setTouchesSEL, touchSet, phase);
    }
    
    SEL setTimestampSEL = NSSelectorFromString(@"_setTimestamp:");
    if ([event respondsToSelector:setTimestampSEL]) {
        IMP imp = [event methodForSelector:setTimestampSEL];
        void (*setTimestamp)(id, SEL, NSTimeInterval) = (void (*)(id, SEL, NSTimeInterval))imp;
        if (setTimestamp) setTimestamp(event, setTimestampSEL, [[NSDate date] timeIntervalSinceReferenceDate]);
    }
    
    return event;
}

- (void)_dispatchEventWithTouchAtX:(CGFloat)x y:(CGFloat)y 
                             phase:(UITouchPhase)phase 
                          fingerID:(uint32_t)fingerID {
    UITouch *touch = [self _getOrCreateTouchForFingerID:fingerID];
    if (!touch) {
        [self _log:@"[TouchSimulation] ❌ 获取 UITouch 失败"];
        return;
    }
    
    [self _configureTouch:touch atX:x atY:y phase:phase fingerID:fingerID];
    
    NSArray *touches = @[touch];
    UIEvent *event = [self _createEventWithTouches:touches phase:phase];
    if (!event) {
        [self _log:@"[TouchSimulation] ❌ 创建 UIEvent 失败"];
        return;
    }
    
    UIApplication *app = [UIApplication sharedApplication];
    [app sendEvent:event];
    
    const char *phaseName = "";
    switch (phase) {
        case UITouchPhaseBegan: phaseName = "DOWN"; break;
        case UITouchPhaseMoved: phaseName = "MOVE"; break;
        case UITouchPhaseEnded: phaseName = "UP"; break;
        case UITouchPhaseCancelled: phaseName = "CANCEL"; break;
        default: phaseName = "UNKNOWN";
    }
    [self _log:[NSString stringWithFormat:@"[TouchSimulation] 📱 %s x=%.0f y=%.0f (scaled) finger=%u", 
        phaseName, x / _scale, y / _scale, fingerID]];
}

// 备用方案：直接调用 UIControl 的 sendActionsForControlEvents
- (void)_dispatchDirectToControlAtX:(CGFloat)x y:(CGFloat)y {
    UIWindow *keyWindow = [[UIApplication sharedApplication] keyWindow];
    if (!keyWindow) return;
    
    CGPoint logicalPoint = [self _convertToLogicalPoint:CGPointMake(x, y)];
    UIView *hitView = [keyWindow hitTest:logicalPoint withEvent:nil];
    
    if ([hitView respondsToSelector:@selector(sendActionsForControlEvents:)]) {
        [hitView sendActionsForControlEvents:UIControlEventTouchUpInside];
        [self _log:[NSString stringWithFormat:@"[TouchSimulation] 🎯 直接触发控件: %@", NSStringFromClass([hitView class])]];
    } else {
        UIView *parent = hitView.superview;
        while (parent && ![parent respondsToSelector:@selector(sendActionsForControlEvents:)]) {
            parent = parent.superview;
        }
        if (parent) {
            [parent sendActionsForControlEvents:UIControlEventTouchUpInside];
            [self _log:[NSString stringWithFormat:@"[TouchSimulation] 🎯 触发父控件: %@", NSStringFromClass([parent class])]];
        }
    }
}

- (void)logDiagnostic {
    UIApplication *app = [UIApplication sharedApplication];
    if (app && app.keyWindow) {
        [self _log:[NSString stringWithFormat:@"[TouchSimulation] ✅ 进程内触摸系统已就绪"]];
        [self _log:[NSString stringWithFormat:@"[TouchSimulation] 📱 逻辑尺寸: %.0fx%.0f, 缩放: %.1f, 物理尺寸: %.0fx%.0f", 
            _screenSize.width, _screenSize.height, _scale,
            _screenSize.width * _scale, _screenSize.height * _scale]];
    } else {
        [self _log:@"[TouchSimulation] ⚠️ UIApplication 尚未完全初始化"];
    }
}

- (void)downAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    _lastX = x;
    _lastY = y;
    _lastIdentity = _fingerSeq++;
    [self _dispatchEventWithTouchAtX:x y:y phase:UITouchPhaseBegan fingerID:fingerID];
    usleep(5000);
}

- (void)moveAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    _lastX = x;
    _lastY = y;
    [self _dispatchEventWithTouchAtX:x y:y phase:UITouchPhaseMoved fingerID:fingerID];
}

- (void)upFinger:(uint32_t)fingerID {
    [self _dispatchEventWithTouchAtX:_lastX y:_lastY phase:UITouchPhaseEnded fingerID:fingerID];
    [self _dispatchDirectToControlAtX:_lastX y:_lastY];
    [self _releaseTouchForFingerID:fingerID];
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