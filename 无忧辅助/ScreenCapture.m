//
//  ScreenCapture.m
//  无忧辅助 - 通过 IOMobileFramebuffer 进行屏幕截图与取色
//  iOS 15.x 兼容版：使用 extern 弱链接（与触控精灵完全一致）
//

#import "ScreenCapture.h"
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <unistd.h>
#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach.h>

// ---- IOMobileFramebuffer 私有声明（与触控精灵完全一致）----
typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;

// dyld 弱链接：编译时不要求框架存在，运行时从已加载的私有框架解析
extern kern_return_t IOMobileFramebufferGetMainDisplay(IOMobileFramebufferRef *fb);
extern kern_return_t IOMobileFramebufferGetLayerDefaultSurface(
    IOMobileFramebufferRef fb, int layer, IOSurfaceRef *surface);

@implementation ScreenCapture {
    IOMobileFramebufferRef _framebuffer;
    IOSurfaceRef _surface;
    int _bytesPerRow;
    int _width;
    int _height;
    BOOL _connected;

    int _rotation; // 0/90/180/270

    NSString *_diagMessage;

    BOOL _keeping;
    unsigned char *_cachedBuffer;
    size_t _cachedSize;
}

+ (instancetype)sharedInstance {
    static ScreenCapture *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ScreenCapture alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _connected = NO;
        _keeping = NO;
        _cachedBuffer = NULL;
        _cachedSize = 0;
        _diagMessage = @"(初始化中...)";
        _framebuffer = NULL;
        _surface = NULL;
        _width = 0;
        _height = 0;
        _bytesPerRow = 0;
        _rotation = 0;
        [self _connect];
    }
    return self;
}

- (void)dealloc {
    [self releaseScreen];
    [self _disconnect];
}

// MARK: - 连接 Framebuffer

- (void)_connect {
    @try {
        [self _connectImpl];
    } @catch (NSException *e) {
        _diagMessage = [NSString stringWithFormat:@"❌ _connect 异常: %@ - %@", e.name, e.reason];
        NSLog(@"[ScreenCapture] %@", _diagMessage);
        [self _fallbackScreenSize];
    }
}

- (void)_connectImpl {
    if (_connected) return;

    // 诊断：确认 dyld 已解析这两个弱链接符号
    if (!IOMobileFramebufferGetMainDisplay || !IOMobileFramebufferGetLayerDefaultSurface) {
        _diagMessage = @"弱链接符号未解析 (dyld 未找到 IOMobileFramebuffer 函数)";
        NSLog(@"[ScreenCapture] %@", _diagMessage);
        [self _fallbackScreenSize];
        return;
    }

    kern_return_t ret = IOMobileFramebufferGetMainDisplay(&_framebuffer);
    if (ret != KERN_SUCCESS || !_framebuffer) {
        _diagMessage = [NSString stringWithFormat:@"GetMainDisplay 失败 (ret=0x%x)", ret];
        NSLog(@"[ScreenCapture] %@", _diagMessage);
        [self _fallbackScreenSize];
        return;
    }

    ret = IOMobileFramebufferGetLayerDefaultSurface(_framebuffer, 0, &_surface);
    if (ret != KERN_SUCCESS || !_surface) {
        _diagMessage = [NSString stringWithFormat:@"GetLayerDefaultSurface 失败 (ret=0x%x)", ret];
        NSLog(@"[ScreenCapture] %@", _diagMessage);
        [self _fallbackScreenSize];
        return;
    }

    _width  = (int)IOSurfaceGetWidth(_surface);
    _height = (int)IOSurfaceGetHeight(_surface);
    _bytesPerRow = (int)IOSurfaceGetBytesPerRow(_surface);

    if (_width <= 0 || _height <= 0) {
        _diagMessage = [NSString stringWithFormat:@"无效尺寸 %dx%d", _width, _height];
        [self _fallbackScreenSize];
        return;
    }

    _connected = YES;
    _diagMessage = [NSString stringWithFormat:@"✅ 连接成功: %dx%d bpr=%d", _width, _height, _bytesPerRow];
    NSLog(@"[ScreenCapture] %@", _diagMessage);
}

- (void)_fallbackScreenSize {
    CGRect bounds = [[UIScreen mainScreen] nativeBounds];
    _width  = (int)bounds.size.width;
    _height = (int)bounds.size.height;
    NSString *prev = _diagMessage ?: @"";
    _diagMessage = [NSString stringWithFormat:@"%@ → fallback UIScreen %dx%d", prev, _width, _height];
    NSLog(@"[ScreenCapture] Fallback: %dx%d", _width, _height);
}

- (BOOL)isConnected {
    return _connected;
}

- (NSString *)diagnosticDescription {
    NSMutableString *desc = [NSMutableString string];
    [desc appendFormat:@"屏幕捕获: %@\n", _diagMessage ?: @"(未初始化)"];

    BOOL canAccessSystem = (access("/var/mobile/Library", F_OK) == 0);

    if (canAccessSystem) {
        [desc appendString:@"安装方式: ✅ TrollStore (no-sandbox 生效)\n"];
    } else {
        [desc appendString:@"安装方式: ❌ 沙盒内 — 请用 TrollStore 重装\n"];
    }

    [desc appendFormat:@"分辨率: %dx%d\n", _width, _height];
    [desc appendFormat:@"取色可用: %@\n", _connected ? @"✅ 是" : @"❌ 否"];

    return desc;
}

// MARK: - 断开连接

- (void)_reconnectIfNeeded {
    // 释放旧连接后重新初始化
    [self _disconnect];   // 会设 _connected = NO
    [self _connectImpl];  // 从头连接
    if (_connected) {
        NSLog(@"[ScreenCapture] 重连成功: %dx%d", _width, _height);
    } else {
        NSLog(@"[ScreenCapture] 重连失败");
    }
}

- (void)_disconnect {
    if (_surface) {
        CFRelease(_surface);
        _surface = NULL;
    }
    _framebuffer = NULL;
    _connected = NO;
}

// MARK: - 锁定/解锁 IOSurface（公开 API）

- (unsigned char *)_lockAndGetBuffer {
    if (_keeping && _cachedBuffer) {
        return _cachedBuffer;
    }

    if (!_connected || !_surface) {
        // 尝试重连（切后台后 Framebuffer 可能失效）
        [self _reconnectIfNeeded];
        if (!_connected || !_surface) return NULL;
    }

    kern_return_t ret = IOSurfaceLock(_surface, kIOSurfaceLockReadOnly, NULL);
    if (ret != KERN_SUCCESS) {
        NSLog(@"[ScreenCapture] IOSurfaceLock 失败: 0x%x，尝试重连", ret);
        [self _reconnectIfNeeded];
        if (!_connected || !_surface) return NULL;
        ret = IOSurfaceLock(_surface, kIOSurfaceLockReadOnly, NULL);
        if (ret != KERN_SUCCESS) {
            NSLog(@"[ScreenCapture] 重连后仍失败: 0x%x", ret);
            return NULL;
        }
    }

    void *baseAddr = IOSurfaceGetBaseAddress(_surface);
    if (!baseAddr) {
        IOSurfaceUnlock(_surface, kIOSurfaceLockReadOnly, NULL);
        // BaseAddress 为空说明 IOSurface 已失效（切后台导致），尝试重连
        NSLog(@"[ScreenCapture] BaseAddress=NULL，Surface失效，尝试重连");
        [self _reconnectIfNeeded];
        if (!_connected || !_surface) return NULL;
        ret = IOSurfaceLock(_surface, kIOSurfaceLockReadOnly, NULL);
        if (ret != KERN_SUCCESS) return NULL;
        baseAddr = IOSurfaceGetBaseAddress(_surface);
        if (!baseAddr) {
            IOSurfaceUnlock(_surface, kIOSurfaceLockReadOnly, NULL);
            NSLog(@"[ScreenCapture] 重连后 BaseAddress 仍为空");
            return NULL;
        }
    }

    size_t totalSize = (size_t)_height * _bytesPerRow;
    if (_cachedSize != totalSize) {
        free(_cachedBuffer);
        _cachedBuffer = (unsigned char *)malloc(totalSize);
        _cachedSize = totalSize;
    }
    if (_cachedBuffer) {
        memcpy(_cachedBuffer, baseAddr, totalSize);
    }

    IOSurfaceUnlock(_surface, kIOSurfaceLockReadOnly, NULL);
    return _cachedBuffer;
}

// MARK: - 取色

- (ScreenColor)colorAtX:(int)x y:(int)y {
    ScreenColor result = {0, 0, 0};
    [self _transformX:&x y:&y];
    if (x < 0 || y < 0 || x >= _width || y >= _height) {
        return result;
    }

    unsigned char *buffer = [self _lockAndGetBuffer];
    if (!buffer) return result;

    int offset = y * _bytesPerRow + x * 4;
    result.b = buffer[offset];
    result.g = buffer[offset + 1];
    result.r = buffer[offset + 2];
    return result;
}

// MARK: - 找色

- (CGPoint)findColor:(ScreenColor)color
            tolerance:(int)tolerance
                   x1:(int)x1 y1:(int)y1
                   x2:(int)x2 y2:(int)y2 {
    if (!_connected) return CGPointMake(-1, -1);

    // 应用旋转到搜索区域
    [self _transformX:&x1 y:&y1];
    [self _transformX:&x2 y:&y2];
    // normalize bounds after transform
    if (x1 > x2) { int t = x1; x1 = x2; x2 = t; }
    if (y1 > y2) { int t = y1; y1 = y2; y2 = t; }

    if (x2 <= 0 || x2 > _width)  x2 = _width;
    if (y2 <= 0 || y2 > _height) y2 = _height;
    if (x1 < 0) x1 = 0;
    if (y1 < 0) y1 = 0;
    if (x1 >= x2 || y1 >= y2) return CGPointMake(-1, -1);

    unsigned char *buffer = [self _lockAndGetBuffer];
    if (!buffer) return CGPointMake(-1, -1);

    for (int y = y1; y < y2; y++) {
        unsigned char *row = buffer + y * _bytesPerRow;
        for (int x = x1; x < x2; x++) {
            int idx = x * 4;
            int b = row[idx];
            int g = row[idx + 1];
            int r = row[idx + 2];

            if (abs(r - color.r) <= tolerance &&
                abs(g - color.g) <= tolerance &&
                abs(b - color.b) <= tolerance) {
                int rx = x, ry = y;
                [self _inverseTransformX:&rx y:&ry];
                return CGPointMake(rx, ry);
            }
        }
    }

    return CGPointMake(-1, -1);
}

- (NSArray<NSValue *> *)findAllColors:(ScreenColor)color
                            tolerance:(int)tolerance
                                   x1:(int)x1 y1:(int)y1
                                   x2:(int)x2 y2:(int)y2 {
    NSMutableArray<NSValue *> *results = [NSMutableArray array];
    if (!_connected) return results;

    [self _transformX:&x1 y:&y1];
    [self _transformX:&x2 y:&y2];
    if (x1 > x2) { int t = x1; x1 = x2; x2 = t; }
    if (y1 > y2) { int t = y1; y1 = y2; y2 = t; }

    if (x2 <= 0 || x2 > _width)  x2 = _width;
    if (y2 <= 0 || y2 > _height) y2 = _height;
    if (x1 < 0) x1 = 0;
    if (y1 < 0) y1 = 0;
    if (x1 >= x2 || y1 >= y2) return results;

    unsigned char *buffer = [self _lockAndGetBuffer];
    if (!buffer) return results;

    for (int y = y1; y < y2; y++) {
        unsigned char *row = buffer + y * _bytesPerRow;
        for (int x = x1; x < x2; x++) {
            int idx = x * 4;
            int b = row[idx];
            int g = row[idx + 1];
            int r = row[idx + 2];

            if (abs(r - color.r) <= tolerance &&
                abs(g - color.g) <= tolerance &&
                abs(b - color.b) <= tolerance) {
                int rx = x, ry = y;
                [self _inverseTransformX:&rx y:&ry];
                [results addObject:[NSValue valueWithCGPoint:CGPointMake(rx, ry)]];
            }
        }
    }

    return results;
}

// MARK: - 坐标旋转

- (void)setRotation:(int)degrees {
    // 标准化到 0/90/180/270
    int d = degrees % 360;
    if (d < 0) d += 360;
    if (d % 90 != 0) d = 0; // 不支持非 90 度增量
    _rotation = d;
    NSLog(@"[ScreenCapture] Rotation set to %d", _rotation);
}

- (void)resetRotation {
    _rotation = 0;
    NSLog(@"[ScreenCapture] Rotation reset to 0");
}

- (int)rotation {
    return _rotation;
}

// 将旋转后的坐标转换为原图坐标
// 原图 _width x _height，像素索引 0.._width-1, 0.._height-1
// -90°(270): 逻辑 (rx,ry) → 原图 (ry, _height-1 - rx)
//  90°     : 逻辑 (rx,ry) → 原图 (_width-1 - ry, rx)
// 180°     : 逻辑 (rx,ry) → 原图 (_width-1 - rx, _height-1 - ry)
- (void)_transformX:(int *)x y:(int *)y {
    if (_rotation == 0) return;
    int rx = *x, ry = *y;
    int w1 = _width - 1;
    int h1 = _height - 1;
    switch (_rotation) {
        case 90:
            *x = w1 - ry;
            *y = rx;
            break;
        case 180:
            *x = w1 - rx;
            *y = h1 - ry;
            break;
        case 270:
            *x = ry;
            *y = h1 - rx;
            break;
    }
}

// 反向：原图坐标转回旋转后的逻辑坐标
- (void)_inverseTransformX:(int *)x y:(int *)y {
    if (_rotation == 0) return;
    int ox = *x, oy = *y;
    int w1 = _width - 1;
    int h1 = _height - 1;
    switch (_rotation) {
        case 90:
            *x = oy;
            *y = w1 - ox;
            break;
        case 180:
            *x = w1 - ox;
            *y = h1 - oy;
            break;
        case 270:
            *x = h1 - oy;
            *y = ox;
            break;
    }
}

// 获取旋转后的逻辑尺寸
- (CGSize)screenSize {
    if (_rotation == 90 || _rotation == 270) {
        return CGSizeMake(_height, _width);
    }
    return CGSizeMake(_width, _height);
}

// MARK: - 屏幕缓存

- (void)keepScreen {
    if (_keeping) return;
    [self _lockAndGetBuffer];
    _keeping = YES;
    NSLog(@"[ScreenCapture] Screen kept");
}

- (void)releaseScreen {
    _keeping = NO;
    NSLog(@"[ScreenCapture] Screen released");
}

// MARK: - 截图为 PNG

- (BOOL)snapshotToPath:(NSString *)path {
    return [self snapshotToPath:path x:0 y:0 w:_width h:_height];
}

- (BOOL)snapshotToPath:(NSString *)path x:(int)x y:(int)y w:(int)w h:(int)h {
    if (!_connected) return NO;

    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x + w > _width)  w = _width - x;
    if (y + h > _height) h = _height - y;
    if (w <= 0 || h <= 0) return NO;

    unsigned char *buffer = [self _lockAndGetBuffer];
    if (!buffer) return NO;

    size_t dataLength = (size_t)h * w * 4;
    unsigned char *rgbaData = (unsigned char *)malloc(dataLength);
    if (!rgbaData) return NO;

    for (int row = 0; row < h; row++) {
        unsigned char *src = buffer + (y + row) * _bytesPerRow + x * 4;
        unsigned char *dst = rgbaData + row * w * 4;
        for (int col = 0; col < w; col++) {
            dst[col * 4 + 0] = src[col * 4 + 2];
            dst[col * 4 + 1] = src[col * 4 + 1];
            dst[col * 4 + 2] = src[col * 4 + 0];
            dst[col * 4 + 3] = 255;
        }
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rgbaData, w, h, 8,
                                              w * 4, colorSpace,
                                              kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);

    if (!ctx) { free(rgbaData); return NO; }

    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);

    if (!image) { free(rgbaData); return NO; }

    UIImage *uiImage = [UIImage imageWithCGImage:image];
    CGImageRelease(image);

    NSData *pngData = UIImagePNGRepresentation(uiImage);
    BOOL ok = [pngData writeToFile:path atomically:YES];
    free(rgbaData);

    if (ok) {
        NSLog(@"[ScreenCapture] Snapshot saved to %@", path);
    } else {
        NSLog(@"[ScreenCapture] Snapshot failed");
    }
    return ok;
}

@end
