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
// 注意: 这些函数是"输入参数 + 返回 kern_return_t"，不是"返回指针"。
// 错误签名会把结果写到垃圾地址，是 getColor 闪退的根因(与原版逆向结果一致)。
typedef kern_return_t (*IOMFBGetMainDisplayFunc)(void **fb);                    // IOMobileFramebufferGetMainDisplay(&fb)
// 注意: IOMobileFramebufferGetSurface 真实签名是 (fb, surfaceIndex, out) 3 个参数,
// 绝不能按 2 参调用, 否则第 3 个参数取到寄存器垃圾值, 写入垃圾地址拿不到 surface。
typedef kern_return_t (*IOMFBGetSurfaceFunc)(void *fb, int surfaceIndex, IOSurfaceRef *surface);
typedef kern_return_t (*IOMFBGetLayerSurfaceFunc)(void *fb, int layer, IOSurfaceRef *surface); // iOS 15+, 3 参数

// IOSurfaceAccelerator 私有接口(对齐原版 HUD 的截屏链路: 硬件 surface -> 加速器转储 -> 自建 surface)
typedef kern_return_t (*IOSurfaceAccelCreateFunc)(CFAllocatorRef allocator, uint32_t type, void **acceleratorOut);
typedef kern_return_t (*IOSurfaceAccelTransferFunc)(void *accelerator, IOSurfaceRef sourceSurface,
                                                    IOSurfaceRef destSurface, CFDictionaryRef dict,
                                                    void **errorOut);

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

    // IOMobileFramebufferGetMainDisplay(&fb)
    // 注意: 这是"输出参数 + kern_return_t"签名，不能按"返回指针"调用，否则会往垃圾地址写 fb 指针闪退。
    IOMFBGetMainDisplayFunc getMain = (IOMFBGetMainDisplayFunc)dlsym(_iomfbHandle, "IOMobileFramebufferGetMainDisplay");
    if (!getMain) { return NO; }

    void *fb = NULL;
    kern_return_t krMain = getMain(&fb);
    if (krMain != KERN_SUCCESS || !fb) { return NO; }

    IOSurfaceRef surface = NULL;
    kern_return_t kr = KERN_FAILURE;

    // 优先 iOS 15+ 的 IOMobileFramebufferGetLayerDefaultSurface(fb, layer, &surface),
    // 个别机型/版本主屏不在 layer 0, 逐个尝试直到拿到 surface。
    IOMFBGetLayerSurfaceFunc getLayerSurface = (IOMFBGetLayerSurfaceFunc)dlsym(_iomfbHandle, "IOMobileFramebufferGetLayerDefaultSurface");
    if (getLayerSurface) {
        for (int layer = 0; layer < 4; layer++) {
            surface = NULL;
            kr = getLayerSurface(fb, layer, &surface);
            if (kr == KERN_SUCCESS && surface) { break; }
        }
    } else {
        // iOS 14 及更早: IOMobileFramebufferGetSurface(fb, 0, &surface) —— 3 个参数!
        IOMFBGetSurfaceFunc getSurface = (IOMFBGetSurfaceFunc)dlsym(_iomfbHandle, "IOMobileFramebufferGetSurface");
        if (getSurface) {
            surface = NULL;
            kr = getSurface(fb, 0, &surface);
        }
    }
    if (kr != KERN_SUCCESS || !surface) {
        NSLog(@"[TSScreenCapture] 获取帧缓冲 surface 失败 kr=%d", (int)kr);
        return NO;
    }

    // ---- 加载 IOSurface 函数 ----
    kern_return_t (*lockFn)(IOSurfaceRef, uint32_t, uint32_t *) =
        dlsym(_iosurfaceHandle, "IOSurfaceLock");
    kern_return_t (*unlockFn)(IOSurfaceRef, uint32_t, uint32_t *) =
        dlsym(_iosurfaceHandle, "IOSurfaceUnlock");
    void *(*baseAddrFn)(IOSurfaceRef) =
        dlsym(_iosurfaceHandle, "IOSurfaceGetBaseAddress");
    size_t (*widthFn)(IOSurfaceRef) = dlsym(_iosurfaceHandle, "IOSurfaceGetWidth");
    size_t (*heightFn)(IOSurfaceRef) = dlsym(_iosurfaceHandle, "IOSurfaceGetHeight");
    size_t (*bytesPerRowFn)(IOSurfaceRef) = dlsym(_iosurfaceHandle, "IOSurfaceGetBytesPerRow");
    uint32_t (*pixelFormatFn)(IOSurfaceRef) = dlsym(_iosurfaceHandle, "IOSurfaceGetPixelFormat");
    IOSurfaceRef (*createFn)(CFDictionaryRef) = dlsym(_iosurfaceHandle, "IOSurfaceCreate");
    IOSurfaceAccelCreateFunc accelCreateFn = (IOSurfaceAccelCreateFunc)dlsym(_iosurfaceHandle, "IOSurfaceAcceleratorCreate");
    IOSurfaceAccelTransferFunc accelTransferFn = (IOSurfaceAccelTransferFunc)dlsym(_iosurfaceHandle, "IOSurfaceAcceleratorTransferSurface");

    if (!lockFn || !unlockFn || !baseAddrFn || !widthFn || !heightFn || !bytesPerRowFn) { return NO; }

    size_t srcW = widthFn(surface);
    size_t srcH = heightFn(surface);
    if (srcW == 0 || srcH == 0) { return NO; }

    // ---- 对齐原版: 用 IOSurfaceAccelerator 把硬件输出 surface 转储到自建 BGRA surface ----
    // 直接 IOSurfaceLock 读硬件输出 surface 在 iOS 15+/后台/部分机型不可靠(返回空或失败),
    // 经 GPU 加速器转储后能得到稳定的全屏像素(原版 HUD 就是这么做的)。
    IOSurfaceRef readSurface = surface;
    IOSurfaceRef dstSurface = NULL;
    void *accel = NULL;
    if (accelCreateFn && accelTransferFn && createFn &&
        accelCreateFn(kCFAllocatorDefault, 0, &accel) == KERN_SUCCESS && accel) {
        CFMutableDictionaryRef props = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (props) {
            // kIOSurface* 常量在 IOSurface.framework, 用其字符串字面值即可
            uint32_t bgra = 0x42475241; // 'BGRA'
            CFNumberRef wNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &srcW);
            CFNumberRef hNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &srcH);
            CFNumberRef fmtNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bgra);
            CFDictionarySetValue(props, CFSTR("Width"), wNum);
            CFDictionarySetValue(props, CFSTR("Height"), hNum);
            CFDictionarySetValue(props, CFSTR("PixelFormat"), fmtNum);
            CFDictionarySetValue(props, CFSTR("BytesPerRow"), (__bridge CFNumberRef)@(srcW * 4));
            CFDictionarySetValue(props, CFSTR("AllocSize"), (__bridge CFNumberRef)@(srcW * srcH * 4));
            CFRelease(wNum); CFRelease(hNum); CFRelease(fmtNum);

            dstSurface = createFn(props);
            CFRelease(props);
        }
        if (dstSurface) {
            kern_return_t tr = accelTransferFn(accel, surface, dstSurface, NULL, NULL);
            if (tr == KERN_SUCCESS) {
                readSurface = dstSurface;
            } else {
                NSLog(@"[TSScreenCapture] IOSurfaceAcceleratorTransferSurface 失败 kr=%d, 回退直接读", (int)tr);
            }
        }
    }

    // ---- 加锁读取 ----
    kern_return_t lk = lockFn(readSurface, 1 /*kIOSurfaceLockReadOnly*/, NULL);
    if (lk != KERN_SUCCESS) {
        NSLog(@"[TSScreenCapture] IOSurfaceLock 失败 kr=%d", (int)lk);
        if (dstSurface) { CFRelease(dstSurface); }
        if (accel) { CFRelease(accel); }
        return NO;
    }
    size_t w = widthFn(readSurface);
    size_t h = heightFn(readSurface);
    size_t bpr = bytesPerRowFn(readSurface);
    void *base = baseAddrFn(readSurface);
    if (w == 0 || h == 0 || bpr < w * 4 || !base) {
        unlockFn(readSurface, 0, NULL);
        if (dstSurface) { CFRelease(dstSurface); }
        if (accel) { CFRelease(accel); }
        return NO;
    }

    // 帧缓冲通常是 BGRA 'BGRA'(0x42475241)。统一转成 RGBA。
    uint8_t *out = malloc(w * h * 4);
    if (!out) { unlockFn(readSurface, 0, NULL); if (dstSurface) { CFRelease(dstSurface); } if (accel) { CFRelease(accel); } return NO; }

    uint32_t fmt = pixelFormatFn ? pixelFormatFn(readSurface) : 0x42475241; // 默认假设 BGRA
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
    unlockFn(readSurface, 0, NULL);
    if (dstSurface) { CFRelease(dstSurface); }
    if (accel) { CFRelease(accel); }

    *pixelsOut = out;
    *widthOut = (int)w;
    *heightOut = (int)h;
    return YES;
}

/// 应用内截屏回退(仅本 App 窗口)
/// 注意: UIGraphics/drawViewHierarchyInRect 等 UIKit 绘制必须在主线程,
/// 而 Lua 取色在后台队列执行, 若在此直接调用会在非主线程崩溃闪退。
- (BOOL)_captureAppWindowToRGBA:(uint8_t **)pixelsOut
                         width:(int *)widthOut
                        height:(int *)heightOut {
    // App 进入后台后自身窗口会被系统挂起/清空, 应用内截屏必然返回全黑,
    // 直接失败, 避免返回黑屏让 getColor 误判成"识别到黑色 0x000000"。
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        return NO;
    }
    __block UIImage *img = nil;
    void (^captureBlock)(void) = ^{
        UIWindow *keyWindow = nil;
        NSArray<UIWindow *> *candidateWindows = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                candidateWindows = ws.windows;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) { keyWindow = w; break; }
                }
                if (keyWindow) { break; }
            }
        }
        // 找不到 keyWindow 时(例如悬浮窗抢占了 keyWindow)，回退到任一可见窗口
        if (!keyWindow) {
            for (UIWindow *w in candidateWindows) {
                if (!w.hidden && w.rootViewController) { keyWindow = w; break; }
            }
        }
        if (!keyWindow) { return; }

        UIView *view = keyWindow;
        UIGraphicsBeginImageContextWithOptions(view.bounds.size, YES, [UIScreen mainScreen].scale);
        // afterScreenUpdates:YES —— 确保拿到当前完整渲染内容(恢复原版行为)。
        // 之前改成 NO 会让首帧/动画中的画面缺失或变空白。
        [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:YES];
        img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    };

    if ([NSThread isMainThread]) {
        captureBlock();
    } else {
        // 绝不能用 dispatch_sync 无限等待主线程: 若主线程正忙于渲染/UI 事件会互相等待,
        // 导致整个 App 卡死无响应(只能双击 HOME 强退)。异步派发 + 300ms 超时,
        // 超时则放弃本次截屏, 保证 Lua 线程永远不被挂起。
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool { captureBlock(); }
            dispatch_semaphore_signal(sema);
        });
        if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC)) != 0) {
            return NO;
        }
    }
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
    UIApplicationState appState = [UIApplication sharedApplication].applicationState;
    NSLog(@"[TSScreenCapture] 帧缓冲截屏失败(appState=%ld: 0前台/1后台/2挂起)，回退应用内截屏",
          (long)appState);
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
