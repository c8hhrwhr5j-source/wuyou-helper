//
//  TSScreenCapture.m
//  TrollAutoTouch
//

#import "TSScreenCapture.h"
#import <dlfcn.h>
#import <mach/mach.h>

// ---------- IOSurface / IOMobileFramebuffer 私有接口 ----------
// 原版用这些私有框架读取帧缓冲。这里用 dlopen 动态加载，避免链接期依赖。
// 说明: 完整的帧缓冲截屏在不同 iOS 版本差异较大，下面给出 iOS 14~16 常见路径。
//       若 captureFramebuffer 失败，会自动回退到应用内截屏。

typedef struct __IOSurface *IOSurfaceRef;

// IOMobileFramebuffer 私有函数指针
typedef void *(*IOMFBCreateFunc)(CFAllocatorRef);
typedef kern_return_t (*IOMFBGetSurfaceFunc)(void *fb, IOSurfaceRef *surface);

@interface TSScreenCapture () {
    void *_iomfbHandle;
    void *_iosurfaceHandle;
    // keep 缓存
    uint8_t  *_cachedPixels;
    int       _cachedWidth;
    int       _cachedHeight;
}
@end

@implementation TSScreenCapture

+ (instancetype)shared {
    static TSScreenCapture *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TSScreenCapture alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 预加载私有框架
        _iomfbHandle = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_LAZY);
        _iosurfaceHandle = dlopen("/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
    }
    return self;
}

/// 尝试通过 IOMobileFramebuffer + IOSurface 截取整屏
- (BOOL)_captureFramebufferToRGBA:(uint8_t **)pixelsOut
                           width:(int *)widthOut
                          height:(int *)heightOut {
    if (!_iomfbHandle || !_iosurfaceHandle) { return NO; }

    // IOMobileFramebufferGetMainDisplay
    IOMFBCreateFunc create = dlsym(_iomfbHandle, "IOMobileFramebufferGetMainDisplay");
    IOMFBGetSurfaceFunc getSurface = (IOMFBGetSurfaceFunc)dlsym(_iomfbHandle, "IOMobileFramebufferGetSurface");
    if (!create || !getSurface) { return NO; }

    void *fb = create(kCFAllocatorDefault);
    if (!fb) { return NO; }

    IOSurfaceRef surface = NULL;
    kern_return_t kr = getSurface(fb, &surface);
    if (kr != KERN_SUCCESS || !surface) { return NO; }

    // 从 IOSurface 拷贝像素。这些函数来自 IOSurface.framework。
    size_t (*lock)(IOSurfaceRef, uint32_t, uint32_t *) =
        dlsym(_iosurfaceHandle, "IOSurfaceLock");
    void *(*baseAddr)(IOSurfaceRef) =
        dlsym(_iosurfaceHandle, "IOSurfaceGetBaseAddress");
    size_t (*widthFn)(IOSurfaceRef) = dlsym(_iosurfaceHandle, "IOSurfaceGetWidth");
    size_t (*heightFn)(IOSurfaceRef) = dlsym(_iosurfaceHandle, "IOSurfaceGetHeight");
    size_t (*bytesPerRowFn)(IOSurfaceRef) = dlsym(_iosurfaceHandle, "IOSurfaceGetBytesPerRow");
    uint32_t (*pixelFormatFn)(IOSurfaceRef) = dlsym(_iosurfaceHandle, "IOSurfaceGetPixelFormat");

    if (!lock || !baseAddr || !widthFn || !heightFn || !bytesPerRowFn) { return NO; }

    IOSurfaceLock(surface, 0, NULL);
    size_t w = widthFn(surface);
    size_t h = heightFn(surface);
    size_t bpr = bytesPerRowFn(surface);
    void *base = baseAddr(surface);

    // 帧缓冲通常是 BGRA 'BGRA'(0x41524742)。统一转成 RGBA。
    uint8_t *out = malloc(w * h * 4);
    if (!out) { IOSurfaceUnlock(surface, 0, NULL); return NO; }

    uint32_t fmt = pixelFormatFn ? pixelFormatFn(surface) : 0x42475241; // 默认假设 BGRA
    for (size_t y = 0; y < h; y++) {
        uint8_t *src = (uint8_t *)base + y * bpr;
        uint8_t *dst = out + y * w * 4;
        for (size_t x = 0; x < w; x++) {
            if (fmt == 0x42475241 /*BGRA*/) {
                dst[x*4+0] = src[x*4+2]; // R
                dst[x*4+1] = src[x*4+1]; // G
                dst[x*4+2] = src[x*4+0]; // B
                dst[x*4+3] = 255;
            } else {
                dst[x*4+0] = src[x*4+0];
                dst[x*4+1] = src[x*4+1];
                dst[x*4+2] = src[x*4+2];
                dst[x*4+3] = src[x*4+3];
            }
        }
    }
    IOSurfaceUnlock(surface, 0, NULL);

    *pixelsOut = out;
    *widthOut = (int)w;
    *heightOut = (int)h;
    return YES;
}

/// 应用内截屏回退(仅本 App 窗口)
- (BOOL)_captureAppWindowToRGBA:(uint8_t **)pixelsOut
                         width:(int *)widthOut
                        height:(int *)heightOut {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) { keyWindow = w; break; }
                }
            }
        }
    }
    if (!keyWindow) { return NO; }

    UIView *view = keyWindow;
    UIGraphicsBeginImageContextWithOptions(view.bounds.size, YES, [UIScreen mainScreen].scale);
    [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:YES];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!img) { return NO; }

    return [self _extractRGBAFromImage:img pixelsOut:pixelsOut width:widthOut height:heightOut];
}

- (BOOL)_extractRGBAFromImage:(UIImage *)image
                    pixelsOut:(uint8_t **)pixelsOut
                       width:(int *)widthOut
                      height:(int *)heightOut {
    CGImageRef cg = image.CGImage;
    int w = (int)CGImageGetWidth(cg);
    int h = (int)CGImageGetHeight(cg);
    uint8_t *out = malloc(w * h * 4);
    if (!out) { return NO; }
    CGContextRef ctx = CGBitmapContextCreate(out, w, h, 8, w * 4,
        CGColorSpaceCreateDeviceRGB(),
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    *pixelsOut = out;
    *widthOut = w;
    *heightOut = h;
    return YES;
}

#pragma mark - 公共 API

- (BOOL)captureScreenToRGBA:(uint8_t **)pixelsOut
                     width:(int *)widthOut
                    height:(int *)heightOut {
    // 优先系统级帧缓冲截屏(可截任意 App)
    if ([self _captureFramebufferToRGBA:pixelsOut width:widthOut height:heightOut]) {
        return YES;
    }
    NSLog(@"[TSScreenCapture] 帧缓冲截屏失败，回退到应用内截屏。系统级截屏需 TrollStore 权限。");
    return [self _captureAppWindowToRGBA:pixelsOut width:widthOut height:heightOut];
}

- (UIImage *)captureImage {
    uint8_t *pixels = NULL;
    int w = 0, h = 0;
    if (![self captureScreenToRGBA:&pixels width:&w height:&h] || !pixels) { return nil; }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef cg = CGBitmapContextCreateImage(ctx);
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(pixels);
    return img;
}

#pragma mark - keep/unkeep 缓存

- (void)keepPixels {
    // 先释放旧缓存
    if (_cachedPixels) { free(_cachedPixels); _cachedPixels = NULL; }
    
    if (![self captureScreenToRGBA:&_cachedPixels width:&_cachedWidth height:&_cachedHeight]) {
        _cachedPixels = NULL; _cachedWidth = 0; _cachedHeight = 0;
    }
}

- (void)unkeepPixels {
    if (_cachedPixels) { free(_cachedPixels); _cachedPixels = NULL; }
    _cachedWidth = 0; _cachedHeight = 0;
}

- (BOOL)getCachedPixels:(uint8_t **)pixelsOut
                  width:(int *)widthOut height:(int *)heightOut {
    if (_cachedPixels && _cachedWidth > 0 && _cachedHeight > 0) {
        uint8_t *copy = malloc(_cachedWidth * _cachedHeight * 4);
        memcpy(copy, _cachedPixels, _cachedWidth * _cachedHeight * 4);
        *pixelsOut = copy;
        *widthOut = _cachedWidth;
        *heightOut = _cachedHeight;
        return YES;
    }
    // 无缓存则执行一次新截屏
    return [self captureScreenToRGBA:pixelsOut width:widthOut height:heightOut];
}

- (void)dealloc {
    if (_cachedPixels) { free(_cachedPixels); _cachedPixels = NULL; }
}

@end
