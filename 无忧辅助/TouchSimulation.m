//
//  TouchSimulation.m
//  无忧辅助 - 通过 IOHIDUserDevice 进行触控模拟（TrollStore 跨应用方案）
//

#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdlib.h>
#import <math.h>
#import <unistd.h>
#import <dlfcn.h>

static CGSize _screenSize = {0, 0};
static uint32_t _fingerSeq = 1000;

typedef struct {
    uint8_t reportId;
    uint8_t fingers;
    uint8_t fingerId;
    uint16_t x;
    uint16_t y;
    uint8_t pressure;
    uint8_t eventType;
} TouchReport;

typedef void* IOHIDUserDeviceRef;

typedef IOHIDUserDeviceRef (*IOHIDUserDeviceCreateFn)(CFAllocatorRef allocator, CFDictionaryRef properties);
typedef void (*IOHIDUserDeviceScheduleWithRunLoopFn)(IOHIDUserDeviceRef device, CFRunLoopRef runLoop, CFStringRef runLoopMode);
typedef void (*IOHIDUserDeviceUnscheduleFromRunLoopFn)(IOHIDUserDeviceRef device, CFRunLoopRef runLoop, CFStringRef runLoopMode);
typedef void (*IOHIDUserDeviceCloseFn)(IOHIDUserDeviceRef device);
typedef CFTypeRef (*IOHIDUserDeviceCopyPropertyFn)(IOHIDUserDeviceRef device, CFStringRef key);
typedef bool (*IOHIDUserDeviceSetReportFn)(IOHIDUserDeviceRef device, IOHIDReportType type, uint32_t reportID, const uint8_t *report, CFIndex reportLength);

static IOHIDUserDeviceCreateFn _IOHIDUserDeviceCreate = NULL;
static IOHIDUserDeviceScheduleWithRunLoopFn _IOHIDUserDeviceScheduleWithRunLoop = NULL;
static IOHIDUserDeviceUnscheduleFromRunLoopFn _IOHIDUserDeviceUnscheduleFromRunLoop = NULL;
static IOHIDUserDeviceCloseFn _IOHIDUserDeviceClose = NULL;
static IOHIDUserDeviceSetReportFn _IOHIDUserDeviceSetReport = NULL;

static IOHIDUserDeviceRef _hidDevice = NULL;

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
        [self _initHIDDevice];
        _lastX = 0;
        _lastY = 0;
        _lastIdentity = 0;
    }
    return self;
}

- (void)dealloc {
    [self _closeHIDDevice];
}

- (void)_initScreenInfo {
    _screenSize = [UIScreen mainScreen].bounds.size;
    NSLog(@"[TouchSimulation] Screen: %.0fx%.0f", _screenSize.width, _screenSize.height);
}

- (BOOL)_initHIDDevice {
    void* handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!handle) {
        [self _log:@"[TouchSimulation] ❌ 无法加载 IOKit 框架"];
        return NO;
    }

    _IOHIDUserDeviceCreate = dlsym(handle, "IOHIDUserDeviceCreate");
    _IOHIDUserDeviceScheduleWithRunLoop = dlsym(handle, "IOHIDUserDeviceScheduleWithRunLoop");
    _IOHIDUserDeviceUnscheduleFromRunLoop = dlsym(handle, "IOHIDUserDeviceUnscheduleFromRunLoop");
    _IOHIDUserDeviceClose = dlsym(handle, "IOHIDUserDeviceClose");
    _IOHIDUserDeviceSetReport = dlsym(handle, "IOHIDUserDeviceSetReport");

    if (!_IOHIDUserDeviceCreate || !_IOHIDUserDeviceScheduleWithRunLoop || !_IOHIDUserDeviceClose || !_IOHIDUserDeviceSetReport) {
        [self _log:@"[TouchSimulation] ❌ 无法获取 IOHIDUserDevice 函数"];
        return NO;
    }

    uint8_t reportDescriptor[] = {
        0x05, 0x0D, // Usage Page (Digitizer)
        0x09, 0x01, // Usage (Digitizer)
        0xA1, 0x01, // Collection (Application)
        0x85, 0x01, // Report ID (1)
        
        0x09, 0x42, // Usage (Tip Switch)
        0x09, 0x32, // Usage (In Range)
        0x15, 0x00, // Logical Minimum (0)
        0x25, 0x01, // Logical Maximum (1)
        0x75, 0x01, // Report Size (1)
        0x95, 0x02, // Report Count (2)
        0x81, 0x02, // Input (Data,Var,Abs)
        
        0x95, 0x06, // Report Count (6)
        0x81, 0x01, // Input (Cnst,Ary,Abs)
        
        0x05, 0x01, // Usage Page (Generic Desktop)
        0x09, 0x30, // Usage (X)
        0x09, 0x31, // Usage (Y)
        0x16, 0x00, 0x00, // Logical Minimum (0)
        0x26, 0xFF, 0x7F, // Logical Maximum (32767)
        0x75, 0x10, // Report Size (16)
        0x95, 0x02, // Report Count (2)
        0x81, 0x02, // Input (Data,Var,Abs)
        
        0x05, 0x0D, // Usage Page (Digitizer)
        0x09, 0x47, // Usage (Contact Identifier)
        0x15, 0x00, // Logical Minimum (0)
        0x25, 0x7F, // Logical Maximum (127)
        0x75, 0x08, // Report Size (8)
        0x95, 0x01, // Report Count (1)
        0x81, 0x02, // Input (Data,Var,Abs)
        
        0x09, 0x30, // Usage (Tip Pressure)
        0x15, 0x00, // Logical Minimum (0)
        0x25, 0xFF, // Logical Maximum (255)
        0x75, 0x08, // Report Size (8)
        0x95, 0x01, // Report Count (1)
        0x81, 0x02, // Input (Data,Var,Abs)
        
        0xC0        // End Collection
    };

    CFDataRef reportDesc = CFDataCreate(NULL, reportDescriptor, sizeof(reportDescriptor));

    NSDictionary *properties = @{
        (__bridge NSString *)kIOHIDReportDescriptorKey: (__bridge id)reportDesc,
        (__bridge NSString *)kIOHIDPhysicalDeviceUniqueIDKey: @"WuyouTouchDevice001",
        (__bridge NSString *)kIOHIDManufacturerKey: @"Wuyou",
        (__bridge NSString *)kIOHIDProductKey: @"Touch Helper",
        (__bridge NSString *)kIOHIDProductIDKey: @(0x0001),
        (__bridge NSString *)kIOHIDVendorIDKey: @(0x1234),
    };

    _hidDevice = _IOHIDUserDeviceCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)properties);

    CFRelease(reportDesc);

    if (!_hidDevice) {
        [self _log:@"[TouchSimulation] ❌ IOHIDUserDeviceCreate 失败"];
        return NO;
    }

    _IOHIDUserDeviceScheduleWithRunLoop(_hidDevice, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    [self _log:@"[TouchSimulation] ✅ IOHIDUserDevice 创建成功"];
    return YES;
}

- (void)_closeHIDDevice {
    if (_hidDevice && _IOHIDUserDeviceUnscheduleFromRunLoop && _IOHIDUserDeviceClose) {
        _IOHIDUserDeviceUnscheduleFromRunLoop(_hidDevice, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        _IOHIDUserDeviceClose(_hidDevice);
        _hidDevice = NULL;
    }
}

- (void)_log:(NSString *)msg {
    if (self.logHandler) {
        self.logHandler(msg);
    }
    NSLog(@"%@", msg);
}

- (void)logDiagnostic {
    if (_hidDevice) {
        [self _log:@"[TouchSimulation] ✅ HID设备已初始化"];
    } else {
        [self _log:@"[TouchSimulation] ❌ HID设备未初始化"];
    }
}

// MARK: - HID 报告发送

- (void)_sendTouchReport:(BOOL)down atX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    if (!_hidDevice || !_IOHIDUserDeviceSetReport) {
        [self _log:@"[TouchSimulation] ❌ HID设备不可用"];
        return;
    }

    uint16_t scaledX = (uint16_t)(x * 32767.0 / _screenSize.width);
    uint16_t scaledY = (uint16_t)(y * 32767.0 / _screenSize.height);

    uint8_t report[10] = {0};
    report[0] = 0x01;
    report[1] = down ? 0x03 : 0x00;
    report[2] = (scaledX >> 8) & 0xFF;
    report[3] = scaledX & 0xFF;
    report[4] = (scaledY >> 8) & 0xFF;
    report[5] = scaledY & 0xFF;
    report[6] = (uint8_t)(fingerID & 0x7F);
    report[7] = down ? 0x80 : 0x00;

    bool result = _IOHIDUserDeviceSetReport(_hidDevice, kIOHIDReportTypeInput, 1, report, sizeof(report));

    const char *typeName = down ? "DOWN" : "UP";
    if (result) {
        [self _log:[NSString stringWithFormat:@"[TouchSimulation] 📱 %s x=%.0f y=%.0f finger=%u", typeName, x, y, fingerID]];
    } else {
        [self _log:[NSString stringWithFormat:@"[TouchSimulation] ❌ %s 失败 x=%.0f y=%.0f", typeName, x, y]];
    }
}

// MARK: - 内部核心方法

- (void)_sendTouchAtX:(CGFloat)x y:(CGFloat)y isTouching:(BOOL)isTouching fingerID:(uint32_t)fingerID {
    _lastX = x;
    _lastY = y;
    
    if (isTouching) {
        _lastIdentity = _fingerSeq++;
    }
    
    [self _sendTouchReport:isTouching atX:x y:y fingerID:fingerID];
    usleep(5000);
}

- (void)_sendMoveAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    _lastX = x;
    _lastY = y;
    
    [self _sendTouchReport:YES atX:x y:y fingerID:fingerID];
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
