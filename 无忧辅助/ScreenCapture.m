//
//  ScreenCapture.m
//  无忧辅助 - 通过 IOMobileFramebuffer 进行屏幕截图与取色
//

#import "ScreenCapture.h"
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <IOSurface/IOSurfaceRef.h>

// IOSurface API 前向声明（IOSurface.h 在此 SDK 中不可用）
extern size_t IOSurfaceGetWidth(IOSurfaceRef surface);
extern size_t IOSurfaceGetHeight(IOSurfaceRef surface);
extern void *IOSurfaceGetBaseAddress(IOSurfaceRef surface);

// IOMobileFramebuffer 私有 API —— 运行时通过 dlsym 加载（不在任何 SDK 中）
typedef struct __IOMobileFramebuffer *IOMobileFramebufferConnection;

static int (*IOMobileFramebufferGetMainDisplay)(IOMobileFramebufferConnection *connection);
static int (*IOMobileFramebufferCreateSurface)(IOMobileFramebufferConnection connection,
                                                int width, int height, int pixelFormat,
                                                IOSurfaceRef *surface, int *bytesPerRow);
static int (*IOMobileFramebufferLockSurface)(IOMobileFramebufferConnection connection,
                                              IOSurfaceRef surface, int param, int *lockToken);
static int (*IOMobileFramebufferUnlockSurface)(IOMobileFramebufferConnection connection,
                                                IOSurfaceRef surface, int lockToken);
static int (*IOMobileFramebufferRelease)(IOMobileFramebufferConnection connection);

// 诊断信息（供外部读取）
static NSString *_globalDiagInfo = nil;

static void _loadIOMobileFramebuffer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 先尝试加载私有框架（TrollStore/越狱环境下才能成功）
        void *fw = dlopen(
            "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
            RTLD_NOW
        );

        void *h = fw ?: RTLD_DEFAULT;
        IOMobileFramebufferGetMainDisplay  = dlsym(h, "IOMobileFramebufferGetMainDisplay");
        IOMobileFramebufferCreateSurface   = dlsym(h, "IOMobileFramebufferCreateSurface");
        IOMobileFramebufferLockSurface     = dlsym(h, "IOMobileFramebufferLockSurface");
        IOMobileFramebufferUnlockSurface   = dlsym(h, "IOMobileFramebufferUnlockSurface");
        IOMobileFramebufferRelease         = dlsym(h, "IOMobileFramebufferRelease");

        if (!fw) {
            _globalDiagInfo = @"dlopen IOMobileFramebuffer 失败 → 应用未脱离沙盒";
            NSLog(@"[ScreenCapture] %@", _globalDiagInfo);
        } else if (!IOMobileFramebufferGetMainDisplay) {
            _globalDiagInfo = @"dlopen 成功但符号解析失败 → iOS 版本可能已移除该私有 API";
            NSLog(@"[ScreenCapture] %@", _globalDiagInfo);
        }
    });
}

// kCVPixelFormatType_32BGRA = 'BGRA'
#define PIXEL_FORMAT 0x42475241

@implementation ScreenCapture {
    IOMobileFramebufferConnection _connection;
    IOSurfaceRef _surface;
    int _bytesPerRow;
    int _width;
    int _height;
    BOOL _connected;

    // 诊断
    NSString *_diagMessage;

    // 屏幕保持缓存
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
        [self _connect];
    }
    return self;
}

- (void)dealloc {
    [self releaseScreen];
    [self _disconnect];
}

- (void)_connect {
    if (_connected) return;

    _loadIOMobileFramebuffer();

    if (!IOMobileFramebufferGetMainDisplay ||
        !IOMobileFramebufferCreateSurface ||
        !IOMobileFramebufferLockSurface ||
        !IOMobileFramebufferUnlockSurface) {
        _diagMessage = _globalDiagInfo ?: @"❌ IOMobileFramebuffer 符号未找到 → 应用未通过 TrollStore 安装，或缺乏私有 API 权限";
        NSLog(@"[ScreenCapture] %@", _diagMessage);
        [self _fallbackScreenSize];
        return;
    }

    int ret = IOMobileFramebufferGetMainDisplay(&_connection);
    if (ret != 0) {
        _diagMessage = [NSString stringWithFormat:@"❌ IOMobileFramebufferGetMainDisplay 失败(错误码:%d) → 缺少 entitlement，请用 TrollStore 安装", ret];
        NSLog(@"[ScreenCapture] %@", _diagMessage);
        [self _fallbackScreenSize];
        return;
    }

    // 用 1x1 先创建 surface 获取宽高信息
    ret = IOMobileFramebufferCreateSurface(_connection, 1, 1, PIXEL_FORMAT,
                                            &_surface, &_bytesPerRow);
    if (ret != 0 || !_surface) {
        _diagMessage = [NSString stringWithFormat:@"❌ CreateSurface 探测失败(错误码:%d)", ret];
        NSLog(@"[ScreenCapture] %@", _diagMessage);
        [self _fallbackScreenSize];
        return;
    }

    // 获取实际尺寸
    _width  = (int)IOSurfaceGetWidth(_surface);
    _height = (int)IOSurfaceGetHeight(_surface);

    // 释放 probe surface，用实际尺寸重建
    CFRelease(_surface);
    _surface = NULL;

    if (_width <= 0 || _height <= 0) {
        _diagMessage = [NSString stringWithFormat:@"❌ Surface 返回无效尺寸 %dx%d", _width, _height];
        NSLog(@"[ScreenCapture] %@", _diagMessage);
        [self _fallbackScreenSize];
        return;
    }

    ret = IOMobileFramebufferCreateSurface(_connection, _width, _height, PIXEL_FORMAT,
                                            &_surface, &_bytesPerRow);
    if (ret != 0 || !_surface) {
        _diagMessage = [NSString stringWithFormat:@"❌ CreateSurface(%dx%d) 失败(错误码:%d)", _width, _height, ret];
        NSLog(@"[ScreenCapture] %@", _diagMessage);
        [self _fallbackScreenSize];
        return;
    }

    _connected = YES;
    _diagMessage = [NSString stringWithFormat:@"✅ 已连接: %dx%d, bytesPerRow=%d", _width, _height, _bytesPerRow];
    NSLog(@"[ScreenCapture] %@", _diagMessage);
}

- (void)_fallbackScreenSize {
    CGRect bounds = [[UIScreen mainScreen] nativeBounds];
    _width  = (int)bounds.size.width;
    _height = (int)bounds.size.height;
    if (!_diagMessage) {
        _diagMessage = [NSString stringWithFormat:@"⚠️ 屏幕捕获未初始化，分辨率回退为 UIScreen: %dx%d", _width, _height];
    }
    NSLog(@"[ScreenCapture] Fallback screen size: %dx%d (screen capture may still fail)", _width, _height);
}

- (BOOL)isConnected {
    return _connected;
}

- (NSString *)diagnosticDescription {
    // 补充安装方式检测
    NSMutableString *desc = [NSMutableString string];
    [desc appendFormat:@"屏幕捕获: %@\n", _diagMessage ?: _globalDiagInfo ?: @"(未初始化)"];

    NSString *installPath = [[NSBundle mainBundle] bundlePath];
    if ([installPath containsString:@"/private/var/containers/Bundle/Application"]) {
        [desc appendString:@"安装方式: ⚠️ 沙盒内 (普通侧载/AltStore)\n"];
    } else if ([installPath containsString:@"/Applications"]) {
        [desc appendString:@"安装方式: ✅ /Applications (TrollStore/越狱)\n"];
    } else {
        [desc appendFormat:@"安装路径: %@\n", installPath];
    }

    [desc appendFormat:@"分辨率: %dx%d\n", _width, _height];
    [desc appendFormat:@"取色可用: %@", _connected ? @"✅ 是" : @"❌ 否"];

    return desc;
}

- (void)_disconnect {
    if (_surface) {
        CFRelease(_surface);
        _surface = NULL;
    }
    if (_connection) {
        IOMobileFramebufferRelease(_connection);
        _connection = NULL;
    }
    _connected = NO;
}

/// 获取当前屏幕数据的指针（缓存或实时）
- (unsigned char *)_lockAndGetBuffer {
    if (_keeping && _cachedBuffer) {
        return _cachedBuffer;
    }

    if (!_connected) return NULL;

    int lockToken = 0;
    int ret = IOMobileFramebufferLockSurface(_connection, _surface, 0, &lockToken);
    if (ret != 0) {
        NSLog(@"[ScreenCapture] LockSurface failed: %d", ret);
        return NULL;
    }

    void *baseAddr = (void *)IOSurfaceGetBaseAddress(_surface);
    if (!baseAddr) {
        IOMobileFramebufferUnlockSurface(_connection, _surface, lockToken);
        return NULL;
    }

    // 拷贝数据出来，避免长时间持有锁
    size_t totalSize = (size_t)_height * _bytesPerRow;
    if (_cachedSize != totalSize) {
        free(_cachedBuffer);
        _cachedBuffer = (unsigned char *)malloc(totalSize);
        _cachedSize = totalSize;
    }
    memcpy(_cachedBuffer, baseAddr, totalSize);

    IOMobileFramebufferUnlockSurface(_connection, _surface, lockToken);
    return _cachedBuffer;
}

// MARK: - 公开接口

- (CGSize)screenSize {
    return CGSizeMake(_width, _height);
}

- (ScreenColor)colorAtX:(int)x y:(int)y {
    ScreenColor result = {0, 0, 0};
    if (!_connected || x < 0 || y < 0 || x >= _width || y >= _height) {
        return result;
    }

    if (_keeping && _cachedBuffer) {
        int offset = y * _bytesPerRow + x * 4;
        unsigned char *pixel = _cachedBuffer + offset;
        result.b = pixel[0];
        result.g = pixel[1];
        result.r = pixel[2];
        return result;
    }

    int lockToken = 0;
    int ret = IOMobileFramebufferLockSurface(_connection, _surface, 0, &lockToken);
    if (ret != 0) {
        NSLog(@"[ScreenCapture] LockSurface failed: %d", ret);
        return result;
    }

    void *baseAddr = (void *)IOSurfaceGetBaseAddress(_surface);
    if (baseAddr) {
        int offset = y * _bytesPerRow + x * 4;  // BGRA 格式
        unsigned char *pixel = (unsigned char *)baseAddr + offset;
        result.b = pixel[0];
        result.g = pixel[1];
        result.r = pixel[2];
    }

    IOMobileFramebufferUnlockSurface(_connection, _surface, lockToken);
    return result;
}

- (CGPoint)findColor:(ScreenColor)color
            tolerance:(int)tolerance
                   x1:(int)x1 y1:(int)y1
                   x2:(int)x2 y2:(int)y2 {
    if (!_connected) return CGPointMake(-1, -1);

    // 参数校验
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
                return CGPointMake(x, y);
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
                [results addObject:[NSValue valueWithCGPoint:CGPointMake(x, y)]];
            }
        }
    }

    return results;
}

- (void)keepScreen {
    if (_keeping) return;
    // 立即缓存当前屏幕
    [self _lockAndGetBuffer];
    _keeping = YES;
    NSLog(@"[ScreenCapture] Screen kept");
}

- (void)releaseScreen {
    _keeping = NO;
    NSLog(@"[ScreenCapture] Screen released");
}

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

    // BGRA → RGBA 转换，创建 CGImage
    size_t bytesPerPixel = 4;
    size_t bitsPerComponent = 8;
    size_t bitsPerPixel = 32;
    size_t dataLength = (size_t)h * w * bytesPerPixel;

    unsigned char *rgbaData = (unsigned char *)malloc(dataLength);
    if (!rgbaData) return NO;

    for (int row = 0; row < h; row++) {
        unsigned char *src = buffer + (y + row) * _bytesPerRow + x * 4;
        unsigned char *dst = rgbaData + row * w * 4;
        for (int col = 0; col < w; col++) {
            dst[col * 4 + 0] = src[col * 4 + 2];  // R
            dst[col * 4 + 1] = src[col * 4 + 1];  // G
            dst[col * 4 + 2] = src[col * 4 + 0];  // B
            dst[col * 4 + 3] = 255;               // A
        }
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rgbaData, w, h, bitsPerComponent,
                                              w * bytesPerPixel, colorSpace,
                                              kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);

    if (!ctx) {
        free(rgbaData);
        return NO;
    }

    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);

    if (!image) {
        free(rgbaData);
        return NO;
    }

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
