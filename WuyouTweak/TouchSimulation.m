//
//  TouchSimulation.m
//  无忧辅助 - 进程内原生触摸事件注入（TrollStore 静态 Dylib 方案）
//
//  原理：在目标 App 进程内直接构造 UITouch/UIEvent，通过 UIApplication sendEvent 派发
//  优势：完全绕开系统 HID 层权限限制，无需 CGEvent/IOHID，函数指针不会归零
//  适用：iOS 14-16.6.1，TrollStore 静态 Dylib 注入
//

#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdlib.h>
#import <math.h>
#import <unistd.h>

static CGSize _screenSize = {0, 0};
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
        _initialized = YES;
    }
    return self;
}

- (void)_log:(NSString *)msg {
    if (self.logHandler) {
        self.logHandler(msg);
    }
    NSLog(@"%@", msg);
}

- (uint64_t)_now {
    return (uint64_t)([[NSDate date] timeIntervalSince1970] * 1e9);
}

// 核心：构造原生 UITouch 对象
- (UITouch *)_createTouchAtX:(CGFloat)x y:(CGFloat)y 
                        phase:(UITouchPhase)phase 
                     fingerID:(uint32_t)fingerID {
    UIWindow *keyWindow = [[UIApplication sharedApplication] keyWindow];
    if (!keyWindow) return nil;
    
    CGPoint location = CGPointMake(x, y);
    
    // 找到触摸目标视图
    UIView *hitView = [keyWindow hitTest:location withEvent:nil];
    if (!hitView) hitView = keyWindow.rootViewController.view;
    
    // 创建 UITouch 对象
    UITouch *touch = [[UITouch alloc] init];
    
    // 设置触摸属性（通过 KVC 或直接内存操作）
    [touch setValue:[NSNumber numberWithInteger:fingerID + 1] forKey:@"_identity"];
    [touch setValue:[NSNumber numberWithInteger:0] forKey:@"_phase"];
    
    // 使用私有 API 设置位置和目标
    SEL setLocationSEL = NSSelectorFromString(@"setLocation:inView:");
    if ([touch respondsToSelector:setLocationSEL]) {
        ((void (*)(id, SEL, CGPoint, UIView *))objc_msgSend)(
            touch, setLocationSEL, location, hitView);
    }
    
    // 设置触摸阶段
    SEL setPhaseSEL = NSSelectorFromString(@"_setPhase:");
    if ([touch respondsToSelector:setPhaseSEL]) {
        ((void (*)(id, SEL, UITouchPhase))objc_msgSend)(touch, setPhaseSEL, phase);
    }
    
    return touch;
}

// 核心：构造 UIEvent 对象
- (UIEvent *)_createEventWithTouches:(NSArray *)touches phase:(UITouchPhase)phase {
    UIEvent *event = [[UIEvent alloc] init];
    
    // 设置事件类型
    [event setValue:[NSNumber numberWithInteger:UIEventTypeTouches] forKey:@"_eventType"];
    
    // 设置触摸集合
    NSMutableSet *touchSet = [NSMutableSet setWithArray:touches];
    SEL setTouchesForPhaseSEL = NSSelectorFromString(@"_setTouches:forPhase:");
    if ([event respondsToSelector:setTouchesForPhaseSEL]) {
        ((void (*)(id, SEL, NSSet *, UITouchPhase))objc_msgSend)(
            event, setTouchesForPhaseSEL, touchSet, phase);
    }
    
    // 设置时间戳
    [event setValue:[NSNumber numberWithDouble:[[NSDate date] timeIntervalSinceReferenceDate]] 
             forKey:@"_timestamp"];
    
    return event;
}

// 核心：向系统派发触摸事件
- (void)_dispatchEventWithTouchAtX:(CGFloat)x y:(CGFloat)y 
                             phase:(UITouchPhase)phase 
                          fingerID:(uint32_t)fingerID {
    UITouch *touch = [self _createTouchAtX:x y:y phase:phase fingerID:fingerID];
    if (!touch) {
        [self _log:@"[TouchSimulation] ❌ 创建 UITouch 失败"];
        return;
    }
    
    NSArray *touches = @[touch];
    UIEvent *event = [self _createEventWithTouches:touches phase:phase];
    if (!event) {
        [self _log:@"[TouchSimulation] ❌ 创建 UIEvent 失败"];
        return;
    }
    
    // 通过 UIApplication 派发事件
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
    [self _log:[NSString stringWithFormat:@"[TouchSimulation] 📱 %s x=%.0f y=%.0f finger=%u", 
        phaseName, x, y, fingerID]];
}

// 备用方案：直接向视图层派发 touches 消息
- (void)_dispatchDirectToViewAtX:(CGFloat)x y:(CGFloat)y 
                           phase:(UITouchPhase)phase 
                        fingerID:(uint32_t)fingerID {
    UIWindow *keyWindow = [[UIApplication sharedApplication] keyWindow];
    if (!keyWindow) return;
    
    CGPoint location = CGPointMake(x, y);
    UIView *hitView = [keyWindow hitTest:location withEvent:nil];
    if (!hitView) hitView = keyWindow.rootViewController.view;
    
    UITouch *touch = [self _createTouchAtX:x y:y phase:phase fingerID:fingerID];
    if (!touch) return;
    
    NSArray *touches = @[touch];
    UIEvent *event = [self _createEventWithTouches:touches phase:phase];
    
    switch (phase) {
        case UITouchPhaseBegan:
            [hitView touchesBegan:touches withEvent:event];
            break;
        case UITouchPhaseMoved:
            [hitView touchesMoved:touches withEvent:event];
            break;
        case UITouchPhaseEnded:
            [hitView touchesEnded:touches withEvent:event];
            break;
        case UITouchPhaseCancelled:
            [hitView touchesCancelled:touches withEvent:event];
            break;
        default:
            break;
    }
}

- (void)logDiagnostic {
    UIApplication *app = [UIApplication sharedApplication];
    if (app && app.keyWindow) {
        [self _log:@"[TouchSimulation] ✅ 进程内触摸系统已就绪"];
        [self _log:[NSString stringWithFormat:@"[TouchSimulation] 📱 屏幕尺寸: %.0fx%.0f", 
            _screenSize.width, _screenSize.height]];
    } else {
        [self _log:@"[TouchSimulation] ⚠️ UIApplication 尚未完全初始化"];
    }
}

// MARK: - 底层原子操作

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
    usleep(5000);
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