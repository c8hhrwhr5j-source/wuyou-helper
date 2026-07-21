//
//  TouchSimulation.m
//  无忧辅助 - 通过 IOHIDUserDevice 进行触控模拟
//

#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdlib.h>
#import <math.h>
#import <unistd.h>
#import <mach/mach_time.h>
#import <dlfcn.h>

// ---- IOHIDUserDevice 动态加载 ----
typedef void* IOHIDUserDeviceRef;

typedef IOHIDUserDeviceRef (*IOHIDUserDeviceCreateFn)(
    CFAllocatorRef allocator,
    CFTypeRef properties);

typedef void (*IOHIDUserDeviceScheduleWithRunLoopFn)(
    IOHIDUserDeviceRef device,
    CFRunLoopRef runLoop,
    CFStringRef runLoopMode);

typedef void (*IOHIDUserDeviceUnscheduleFromRunLoopFn)(
    IOHIDUserDeviceRef device,
    CFRunLoopRef runLoop,
    CFStringRef runLoopMode);

typedef bool (*IOHIDUserDeviceHandleReportFn)(
    IOHIDUserDeviceRef device,
    uint8_t *report,
    CFIndex reportLength);

typedef void (*IOHIDUserDeviceRegisterInputReportCallbackFn)(
    IOHIDUserDeviceRef device,
    void *callback,
    void *context);

static IOHIDUserDeviceCreateFn _createUserDevice = NULL;
static IOHIDUserDeviceScheduleWithRunLoopFn _scheduleRunLoop = NULL;
static IOHIDUserDeviceUnscheduleFromRunLoopFn _unscheduleRunLoop = NULL;
static IOHIDUserDeviceHandleReportFn _handleReport = NULL;
static IOHIDUserDeviceRegisterInputReportCallbackFn _registerCallback = NULL;

static IOHIDUserDeviceRef _userDevice = NULL;
static uint32_t _fingerSeq = 1000;
static CGFloat _screenScale = 1.0;
static CGSize _screenSize = {0, 0};

// HID 报告描述符 - 触摸屏（兼容 iOS）
static const uint8_t _hidReportDescriptor[] = {
    0x05, 0x0D,                    // Usage Page (Digitizers)
    0x09, 0x04,                    // Usage (Touch Screen)
    0xA1, 0x01,                    // Collection (Application)
    
    0x85, 0x01,                    // Report ID (1)
    
    0x09, 0x54,                    // Usage (Contact count)
    0x25, 0x0F,                    // Logical Maximum (15)
    0x95, 0x01,                    // Report Count (1)
    0x75, 0x04,                    // Report Size (4 bits)
    0x81, 0x02,                    // Input (Data,Var,Abs)
    
    0x95, 0x01,                    // Report Count (1)
    0x75, 0x04,                    // Report Size (4 bits)
    0x81, 0x01,                    // Input (Const,Var,Abs)
    
    0x09, 0x22,                    // Usage (Finger)
    0xA1, 0x02,                    // Collection (Logical)
    
    0x09, 0x42,                    // Usage (Tip Switch)
    0x15, 0x00,                    // Logical Minimum (0)
    0x25, 0x01,                    // Logical Maximum (1)
    0x75, 0x01,                    // Report Size (1)
    0x95, 0x01,                    // Report Count (1)
    0x81, 0x02,                    // Input (Data,Var,Abs)
    
    0x09, 0x32,                    // Usage (In Range)
    0x81, 0x02,                    // Input (Data,Var,Abs)
    
    0x95, 0x02,                    // Report Count (2)
    0x81, 0x01,                    // Input (Const,Var,Abs)
    
    0x09, 0x51,                    // Usage (Contact Identifier)
    0x25, 0x0F,                    // Logical Maximum (15)
    0x75, 0x04,                    // Report Size (4)
    0x95, 0x01,                    // Report Count (1)
    0x81, 0x02,                    // Input (Data,Var,Abs)
    
    0x05, 0x01,                    // Usage Page (Generic Desktop)
    0x09, 0x30,                    // Usage (X)
    0x16, 0x00, 0x00,              // Logical Minimum (0)
    0x26, 0xFF, 0x0F,              // Logical Maximum (4095)
    0x75, 0x10,                    // Report Size (16)
    0x95, 0x01,                    // Report Count (1)
    0x81, 0x02,                    // Input (Data,Var,Abs)
    
    0x09, 0x31,                    // Usage (Y)
    0x26, 0xFF, 0x0F,              // Logical Maximum (4095)
    0x81, 0x02,                    // Input (Data,Var,Abs)
    
    0x0D, 0x47, 0x00, 0x04,        // Usage (Width) - 0x47
    0x27, 0xFF, 0x0F, 0x00, 0x00,  // Logical Maximum (4095)
    0x75, 0x10,                    // Report Size (16)
    0x95, 0x01,                    // Report Count (1)
    0x81, 0x02,                    // Input (Data,Var,Abs)
    
    0x0D, 0x48, 0x00, 0x04,        // Usage (Height) - 0x48
    0x81, 0x02,                    // Input (Data,Var,Abs)
    
    0xC0,                          // End Collection
    
    0xC0                           // End Collection
};

// 报告格式:
// [0] = Report ID (0x01)
// [1] = Contact Count (低4位) + 保留(高4位)
// [2] = Tip Switch (bit0) + In Range (bit1) + 保留(bit2-3) + Contact ID (bit4-7)
// [3] = X坐标低字节
// [4] = X坐标高字节
// [5] = Y坐标低字节
// [6] = Y坐标高字节
// [7] = Width低字节
// [8] = Width高字节
// [9] = Height低字节
// [10] = Height高字节

#define REPORT_SIZE 11

static void _sendTouchReport(uint32_t contactCount, uint32_t contactID, 
                             bool isTouching, uint32_t x, uint32_t y) {
    if (!_userDevice || !_handleReport) return;
    
    uint8_t report[REPORT_SIZE] = {0};
    report[0] = 0x01; // Report ID
    report[1] = contactCount & 0x0F; // Contact Count
    
    if (contactCount > 0) {
        report[2] = ((contactID & 0x0F) << 4) | (isTouching ? 0x03 : 0x00);
        report[3] = x & 0xFF;
        report[4] = (x >> 8) & 0xFF;
        report[5] = y & 0xFF;
        report[6] = (y >> 8) & 0xFF;
        report[7] = 0x14; // Width = 20
        report[8] = 0x00;
        report[9] = 0x14; // Height = 20
        report[10] = 0x00;
    }
    
    bool success = _handleReport(_userDevice, report, REPORT_SIZE);
    
    static bool logged = false;
    if (!logged) {
        NSLog(@"[TouchSimulation] IOHIDUserDevice report sent, success=%d", success);
        logged = true;
    }
}

static void _convertCoords(CGFloat x, CGFloat y, uint32_t *outX, uint32_t *outY) {
    *outX = (uint32_t)(x * 4095.0 / _screenSize.width);
    *outY = (uint32_t)(y * 4095.0 / _screenSize.height);
}

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
        [self _initHID];
        [self _initScreenInfo];
        _lastX = 0;
        _lastY = 0;
        _lastIdentity = 0;
    }
    return self;
}

- (void)_initScreenInfo {
    _screenScale = [UIScreen mainScreen].scale;
    _screenSize = [UIScreen mainScreen].nativeBounds.size;
    NSLog(@"[TouchSimulation] Screen: %.0fx%.0f scale=%.1f", 
          _screenSize.width, _screenSize.height, _screenScale);
}

- (void)_initHID {
    void* handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!handle) {
        handle = dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", RTLD_LAZY);
    }
    if (!handle) {
        [self _log:@"[TouchSimulation] ❌ 无法加载 IOKit.framework"];
        return;
    }
    
    _createUserDevice = dlsym(handle, "IOHIDUserDeviceCreate");
    _scheduleRunLoop = dlsym(handle, "IOHIDUserDeviceScheduleWithRunLoop");
    _unscheduleRunLoop = dlsym(handle, "IOHIDUserDeviceUnscheduleFromRunLoop");
    _handleReport = dlsym(handle, "IOHIDUserDeviceHandleReport");
    _registerCallback = dlsym(handle, "IOHIDUserDeviceRegisterInputReportCallback");
    
    if (!_createUserDevice || !_scheduleRunLoop || !_handleReport) {
        [self _log:@"[TouchSimulation] ❌ 缺少必要的 IOHIDUserDevice 函数"];
        return;
    }
    
    CFDataRef reportDescriptor = CFDataCreate(kCFAllocatorDefault, 
                                              _hidReportDescriptor, 
                                              sizeof(_hidReportDescriptor));
    
    NSDictionary *properties = @{
        (__bridge NSString *)kIOHIDReportDescriptorKey: (__bridge id)reportDescriptor,
        (__bridge NSString *)kIOHIDPhysicalDeviceUniqueIDKey: @"wuyou-touch-device",
        (__bridge NSString *)kIOHIDTransportKey: @"USB",
        (__bridge NSString *)kIOHIDVendorIDKey: @(0x1234),
        (__bridge NSString *)kIOHIDProductIDKey: @(0xABCD),
        (__bridge NSString *)kIOHIDVersionNumberKey: @(1),
        (__bridge NSString *)kIOHIDManufacturerKey: @"WuYou",
        (__bridge NSString *)kIOHIDProductKey: @"Touch Simulator"
    };
    
    _userDevice = _createUserDevice(kCFAllocatorDefault, (__bridge CFTypeRef)properties);
    
    if (reportDescriptor) CFRelease(reportDescriptor);
    
    if (_userDevice) {
        _scheduleRunLoop(_userDevice, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        [self _log:@"[TouchSimulation] ✅ IOHIDUserDevice 初始化成功"];
    } else {
        [self _log:@"[TouchSimulation] ❌ IOHIDUserDevice 创建失败"];
    }
}

- (void)dealloc {
    if (_userDevice) {
        _unscheduleRunLoop(_userDevice, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        CFRelease(_userDevice);
    }
}

- (void)_log:(NSString *)msg {
    if (self.logHandler) {
        self.logHandler(msg);
    }
    NSLog(@"%@", msg);
}

- (void)logDiagnostic {
    if (_userDevice && _handleReport) {
        [self _log:@"[TouchSimulation] ✅ HID UserDevice 有效"];
    } else {
        [self _log:@"[TouchSimulation] ❌ HID 初始化不完整——触摸注入完全无效！"];
    }
}

// MARK: - 内部核心方法

- (void)_sendTouchAtX:(CGFloat)x y:(CGFloat)y isTouching:(bool)isTouching fingerID:(uint32_t)fingerID {
    _lastX = x;
    _lastY = y;
    
    const char *phaseName = isTouching ? "DOWN" : "UP";
    
    uint32_t identity = isTouching ? (_fingerSeq++) : _lastIdentity;
    _lastIdentity = isTouching ? identity : _lastIdentity;
    
    uint32_t hidX, hidY;
    _convertCoords(x, y, &hidX, &hidY);
    
    [self _log:[NSString stringWithFormat:@"[TouchSimulation] 📱 %s finger=%d x=%.0f y=%.0f (HID: %u,%u) identity=%u",
              phaseName, fingerID, x, y, hidX, hidY, identity]];
    
    _sendTouchReport(isTouching ? 1 : 0, identity & 0x0F, isTouching, hidX, hidY);
    
    usleep(5000);
}

- (void)_sendMoveAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    _lastX = x;
    _lastY = y;
    
    uint32_t hidX, hidY;
    _convertCoords(x, y, &hidX, &hidY);
    
    [self _log:[NSString stringWithFormat:@"[TouchSimulation] 📱 MOVE finger=%d x=%.0f y=%.0f (HID: %u,%u)", 
              fingerID, x, y, hidX, hidY]];
    
    _sendTouchReport(1, _lastIdentity & 0x0F, true, hidX, hidY);
}

// MARK: - 底层原子操作

- (void)downAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    [self _sendTouchAtX:x y:y isTouching:true fingerID:fingerID];
}

- (void)moveAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID {
    [self _sendMoveAtX:x y:y fingerID:fingerID];
}

- (void)upFinger:(uint32_t)fingerID {
    [self _sendTouchAtX:_lastX y:_lastY isTouching:false fingerID:fingerID];
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