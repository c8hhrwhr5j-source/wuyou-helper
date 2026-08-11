//
//  TSHIDEventTouch.m
//  TrollAutoTouch
//
//  IOHIDEvent 系统级触摸注入实现。
//
//  逆向依据: 原 TrollAutoScript 的 HUDServices 二进制中提取到如下符号:
//    _IOHIDEventSystemClientCreate
//    _IOHIDEventSystemClientDispatchEvent
//    _IOHIDEventSystemClientScheduleWithRunLoop
//    _IOHIDEventCreateDigitizerEvent
//    _IOHIDEventCreateDigitizerFingerEventWithQuality
//    _IOHIDEventAppendEvent
//    _IOHIDEventSetSenderID
//  且链接 BackBoardServices / FrontBoard 私有框架。本实现复刻该路径。
//
//  注意: 这些是 IOKit 私有/未公开 C 接口，其参数签名随 iOS 版本略有差异。
//  下面采用的声明是 ZXTouch / SimulateTouch 等开源项目长期验证过的版本，
//  在 iOS 13~16 (越狱/TrollStore 环境) 上普遍可用。如遇新版本签名不符，
//  请按头文件 <IOKit/hid/IOHIDEvent.h> (macOS SDK) 校正。
//

#import "TSHIDEventTouch.h"
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <dlfcn.h>

// ---------- 私有类型与常量 ----------
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef double IOHIDFloat;
typedef uint32_t IOHIDEventOptionBits;

// IOHIDDigitizerEventMask 位 (来自 IOKit 私有头)
#define kIOHIDDigitizerEventRange      (1 << 0)
#define kIOHIDDigitizerEventTouch      (1 << 1)
#define kIOHIDDigitizerEventPosition   (1 << 2)

// 模仿触摸屏上报者的 senderID (ZXTouch 常用值，使事件被识别为真实触屏)
#define kTouchSenderID  0x8000000800ULL

// ---------- 私有函数声明 ----------
// 这些符号来自 IOKit.framework (CoreFoundation 的一部分，随系统存在)。
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef client, CFRunLoopRef runLoop, CFStringRef mode);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);

extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t type, uint32_t subtype,
    uint32_t index, uint32_t identity, uint32_t mask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure,
    Boolean range, Boolean touch,
    IOHIDEventOptionBits options);

extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEventWithQuality(
    CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t index, uint32_t identity, uint32_t mask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist,
    IOHIDFloat quality, IOHIDFloat density,
    Boolean range, Boolean touch);

extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, IOHIDEventOptionBits options);
extern void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t senderID);

// ---------- 实现 ----------

@interface TSHIDEventTouch ()
@property (nonatomic, assign) IOHIDEventSystemClientRef client;
@end

@implementation TSHIDEventTouch

+ (instancetype)shared {
    static TSHIDEventTouch *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TSHIDEventTouch alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self _setupClient];
    }
    return self;
}

- (void)_setupClient {
    // 创建 HID 事件系统客户端并挂到主 RunLoop，使 dispatch 的事件被 backboardd 处理。
    // 需要 entitlements: com.apple.backboard.client / task_for_pid-allow 等(TrollStore 签名后生效)。
    _client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (_client) {
        IOHIDEventSystemClientScheduleWithRunLoop(_client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    } else {
        NSLog(@"[TSHIDEventTouch] IOHIDEventSystemClientCreate 失败，请确认已用 TrollStore 安装且权限生效。");
    }
}

/// 当前屏幕逻辑尺寸
- (CGSize)_screenSize {
    return [UIScreen mainScreen].bounds.size;
}

/// 构造并发送一次手指 HID 事件
- (void)_sendFingerEventAtPoint:(CGPoint)point
                          index:(uint32_t)index
                          phase:(TSTouchPhase)phase {
    if (!_client) { return; }

    // 坐标：使用屏幕逻辑点(左上为原点)。
    // 部分机型需按屏幕宽高归一化；此处先按绝对点处理(与 ZXTouch 默认一致)。
    IOHIDFloat x = (IOHIDFloat)point.x;
    IOHIDFloat y = (IOHIDFloat)point.y;

    Boolean range, touch;
    uint32_t mask;
    switch (phase) {
        case TSTouchPhaseBegan:
            range = true;  touch = true;  mask = kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange;
            break;
        case TSTouchPhaseMoved:
            range = true;  touch = true;  mask = kIOHIDDigitizerEventPosition;
            break;
        case TSTouchPhaseEnded:
        default:
            range = false; touch = false; mask = kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange;
            break;
    }

    uint64_t timeStamp = mach_absolute_time();
    float pressure = (phase == TSTouchPhaseEnded) ? 0.0f : 1.0f;
    float quality  = 1.0f;
    float density  = 1.0f;
    float twist    = 0.0f;
    float z        = 0.0f;

    // 1) 父事件: 数位板(digitizer)事件
    IOHIDEventRef digitizer = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, timeStamp,
        /*type*/     kIOHIDDigitizerEventTouch,
        /*subtype*/  0,
        /*index*/    index,
        /*identity*/ index,
        /*mask*/     mask,
        x, y, z, pressure,
        range, touch, 0);
    if (!digitizer) { return; }

    // 2) 子事件: 单根手指
    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEventWithQuality(
        kCFAllocatorDefault, timeStamp,
        index, index, mask,
        x, y, z, pressure, twist,
        quality, density,
        range, touch);
    if (finger) {
        IOHIDEventAppendEvent(digitizer, finger, 0);
        CFRelease(finger);
    }

    // 3) 标记发送者为触摸屏，避免被丢弃
    IOHIDEventSetSenderID(digitizer, kTouchSenderID);

    // 4) 投递
    IOHIDEventSystemClientDispatchEvent(_client, digitizer);
    CFRelease(digitizer);
}

#pragma mark - 公共 API

- (void)touchDownAtPoint:(CGPoint)point index:(NSInteger)index {
    [self _sendFingerEventAtPoint:point index:(uint32_t)index phase:TSTouchPhaseBegan];
}

- (void)touchMoveAtPoint:(CGPoint)point index:(NSInteger)index {
    [self _sendFingerEventAtPoint:point index:(uint32_t)index phase:TSTouchPhaseMoved];
}

- (void)touchUpAtPoint:(CGPoint)point index:(NSInteger)index {
    [self _sendFingerEventAtPoint:point index:(uint32_t)index phase:TSTouchPhaseEnded];
}

- (void)tapAtPoint:(CGPoint)point duration:(NSTimeInterval)pressDuration {
    [self touchDownAtPoint:point index:0];
    // 让出 RunLoop 让 backboardd 处理 down，再 up
    [NSThread sleepForTimeInterval:MAX(pressDuration, 0.02)];
    [self _yieldRunLoopForSeconds:MAX(pressDuration, 0.02)];
    [self touchUpAtPoint:point index:0];
}

- (void)swipeFromPoint:(CGPoint)from toPoint:(CGPoint)to
              duration:(NSTimeInterval)duration steps:(NSInteger)steps {
    if (steps < 2) { steps = 2; }
    NSTimeInterval dt = duration / (NSTimeInterval)steps;

    [self touchDownAtPoint:from index:0];
    [self _yieldRunLoopForSeconds:dt];

    for (NSInteger i = 1; i < steps; i++) {
        CGFloat t = (CGFloat)i / (CGFloat)steps;
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * t,
                                from.y + (to.y - from.y) * t);
        [self touchMoveAtPoint:p index:0];
        [self _yieldRunLoopForSeconds:dt];
    }
    [self touchMoveAtPoint:to index:0];
    [self _yieldRunLoopForSeconds:dt];
    [self touchUpAtPoint:to index:0];
}

/// 让主 RunLoop 跑一会儿，保证 HID 事件被 backboardd 即时处理
- (void)_yieldRunLoopForSeconds:(NSTimeInterval)seconds {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}

@end
