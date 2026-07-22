//
//  Tweak.xm
//  WuyouTweak - 无忧辅助触摸事件拦截与注入 Tweak
//
//  原理：在目标 App 进程内通过 Runtime Hook 拦截触摸事件，
//       通过进程内 UIEvent 构造实现虚拟点击注入
//  适用：iOS 14-16.6.1，TrollStore 静态 Dylib 注入
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "TouchSimulation.h"
#import "ScriptEngine.h"
#import "LuaBridge.h"
#import "ScreenCapture.h"
#import "DeviceInfo.h"

static TouchSimulation *_touchSim = nil;
static ScriptEngine *_scriptEngine = nil;
static ScreenCapture *_screenCapture = nil;

// 点击拦截回调
static void (*_onTouchEvent)(int type, CGFloat x, CGFloat y) = NULL;

// 设置点击拦截回调
void setTouchEventCallback(void (*callback)(int type, CGFloat x, CGFloat y)) {
    _onTouchEvent = callback;
}

// 全局触摸事件拦截
%hook UIWindow

- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        NSSet *touches = [event allTouches];
        for (UITouch *touch in touches) {
            CGPoint location = [touch locationInView:self];
            UITouchPhase phase = touch.phase;
            
            int type = 0;
            switch (phase) {
                case UITouchPhaseBegan: type = 1; break;
                case UITouchPhaseMoved: type = 2; break;
                case UITouchPhaseEnded: type = 3; break;
                case UITouchPhaseCancelled: type = 4; break;
                default: break;
            }
            
            if (_onTouchEvent && type != 0) {
                _onTouchEvent(type, location.x, location.y);
            }
            
            NSLog(@"[WuyouTweak] 拦截触摸事件: type=%d x=%.0f y=%.0f", type, location.x, location.y);
        }
    }
    
    %orig;
}

%end

// UIButton 点击拦截
%hook UIButton

- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    if (event) {
        NSSet *touches = [event allTouches];
        if (touches.count > 0) {
            UITouch *touch = [touches anyObject];
            CGPoint location = [touch locationInView:self];
            NSLog(@"[WuyouTweak] 拦截按钮点击: %@ at x=%.0f y=%.0f", NSStringFromSelector(action), location.x, location.y);
        }
    }
    
    %orig;
}

%end

// 应用启动完成后初始化
%hook UIApplication

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    %orig;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self _initWuyouTweak];
    });
}

- (void)_initWuyouTweak {
    NSLog(@"[WuyouTweak] 🚀 开始初始化无忧辅助 Tweak...");
    
    // 初始化设备信息
    DeviceInfo *deviceInfo = [DeviceInfo sharedInstance];
    NSLog(@"[WuyouTweak] 📱 设备信息: %@", deviceInfo.description);
    
    // 初始化屏幕捕获
    _screenCapture = [ScreenCapture sharedInstance];
    [_screenCapture startCapture];
    NSLog(@"[WuyouTweak] 📷 屏幕捕获已启动");
    
    // 初始化触摸模拟
    _touchSim = [TouchSimulation sharedInstance];
    [_touchSim logDiagnostic];
    
    // 初始化脚本引擎
    _scriptEngine = [ScriptEngine sharedInstance];
    _scriptEngine.logHandler = ^(NSString *msg) {
        NSLog(@"[WuyouTweak][ScriptEngine] %@", msg);
    };
    
    // 注册 Lua 接口
    [LuaBridge registerFunctions];
    
    NSLog(@"[WuyouTweak] ✅ 无忧辅助 Tweak 初始化完成");
}

%end

// 导出给 Lua 调用的 C 接口

extern "C" {

void native_tap(CGFloat x, CGFloat y) {
    NSLog(@"[WuyouTweak] native_tap: x=%.0f y=%.0f", x, y);
    dispatch_async(dispatch_get_main_queue(), ^{
        [_touchSim tapAtX:x y:y delayMs:10 fingerID:0];
    });
}

void native_swipe(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2, CGFloat duration) {
    NSLog(@"[WuyouTweak] native_swipe: (%0.f,%0.f)->(%0.f,%0.f) dur=%.2fs", x1, y1, x2, y2, duration);
    dispatch_async(dispatch_get_main_queue(), ^{
        [_touchSim swipeFromX:x1 y:y1 toX:x2 y:y2 duration:(NSInteger)(duration * 1000)];
    });
}

void native_hold(CGFloat x, CGFloat y, CGFloat duration) {
    NSLog(@"[WuyouTweak] native_hold: x=%.0f y=%.0f dur=%.2fs", x, y, duration);
    dispatch_async(dispatch_get_main_queue(), ^{
        [_touchSim holdAtX:x y:y duration:(NSInteger)(duration * 1000)];
    });
}

int native_get_screen_width() {
    return (int)[UIScreen mainScreen].bounds.size.width;
}

int native_get_screen_height() {
    return (int)[UIScreen mainScreen].bounds.size.height;
}

int native_get_color_at(CGFloat x, CGFloat y, int *r, int *g, int *b) {
    if (!_screenCapture) return 0;
    return [_screenCapture getColorAtX:x y:y r:r g:g b:b];
}

void native_delay(CGFloat seconds) {
    usleep((useconds_t)(seconds * 1000000));
}

void native_log(const char *msg) {
    NSLog(@"[WuyouTweak][Lua] %s", msg);
}

void native_set_touch_callback(void (*callback)(int type, CGFloat x, CGFloat y)) {
    _onTouchEvent = callback;
}

} // extern "C"