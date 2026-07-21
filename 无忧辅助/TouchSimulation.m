//
//  TouchSimulation.m
//  无忧辅助 - 通过 CGEvent 进行触控模拟（TrollStore 跨应用方案）
//

#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AXUIElement.h>
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
        [self _initScreenInfo];
        _lastX = 0;
        _lastY = 0;
        _lastIdentity = 0;
    }
    return self;
}

- (void)_initScreenInfo {
    _screenSize = [UIScreen mainScreen].bounds.size;
    NSLog(@"[TouchSimulation] Screen: %.0fx%.0f", _screenSize.width, _screenSize.height);
}

- (void)_log:(NSString *)msg {
    if (self.logHandler) {
        self.logHandler(msg);
    }
    NSLog(@"%@", msg);
}

- (void)logDiagnostic {
    BOOL isTrusted = AXIsProcessTrusted();
    if (isTrusted) {
        [self _log:@"[TouchSimulation] ✅ 辅助功能信任权限已获取 - CGEvent 可跨应用投递"];
    } else {
        [self _log:@"[TouchSimulation] ⚠️ 辅助功能信任权限未获取 - CGEvent 仅能投递到自身 App"];
    }
    
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source) {
        [self _log:@"[TouchSimulation] ✅ CGEventSource 创建成功"];
        CFRelease(source);
    } else {
        [self _log:@"[TouchSimulation] ❌ CGEventSource 创建失败"];
    }
}

// MARK: - CGEvent 核心实现

- (void)_postMouseEvent:(CGEventType)type atX:(CGFloat)x y:(CGFloat)y {
    CGPoint point = CGPointMake(x, y);
    
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, point, kCGMouseButtonLeft);
    if (!event) {
        [self _log:@"[TouchSimulation] ❌ CGEventCreateMouseEvent 失败"];
        return;
    }
    
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
    
    const char *typeName = (type == kCGEventLeftMouseDown) ? "DOWN" : 
                           (type == kCGEventLeftMouseUp) ? "UP" : 
                           (type == kCGEventMouseMoved) ? "MOVE" : "UNKNOWN";
    
    [self _log:[NSString stringWithFormat:@"[TouchSimulation] 📱 %s x=%.0f y=%.0f", typeName, x, y]];
}

// MARK: - 内部核心方法

- (void)_sendTouchAtX:(CGFloat)x y:(CGFloat)y isTouching:(BOOL)isTouching fingerID:(uint32_t)fingerID {
    _lastX = x;
    _lastY = y;
    
    if (isTouching) {
        _lastIdentity = _fingerSeq++;
        [self _postMouseEvent:kCGEventLeftMouseDown atX:x y:y];
    } else {
        [self _postMouseEvent:kCGEventLeftMouseUp atX:x y:y];
    }
    
    usleep(5000);
}

- (void)_sendMoveAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    _lastX = x;
    _lastY = y;
    
    [self _postMouseEvent:kCGEventMouseMoved atX:x y:y];
}

// MARK: - 底层原子操作

- (void)downAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    [self _sendTouchAtX:x y:y isTouching:YES fingerID:fingerID];
}

- (void)moveAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    [self _sendMoveAtX:x y:y fingerID:fingerID];
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