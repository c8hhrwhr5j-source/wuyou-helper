//
//  TSScreenCapture.m
//  TrollAutoTouch
//
//  屏幕截图 —— 对齐原版 TrollAutoScript 的截屏能力。
//
//  原版逆向结论(HUDServices 符号级确认):
//   - 完全不用 IOMobileFramebuffer(GetMainDisplay/GetLayerDefaultSurface/GetSurface 均不存在)
//   - 跨应用截屏链路为:
//       +[UIWindow windowWithContextId:]  → 绑定系统窗口 context 的远程窗口代理
//       IOSurfaceCreate(kIOSurface* 键)   → 自建目标 BGRA surface
//       IOSurfaceAcceleratorCreate + IOSurfaceAcceleratorTransferSurface(accel, src, dst)
//                                       → 经 WindowServer 侧 GPU 加速器转储屏幕内容
//       UICreateCGImageFromIOSurface / CVPixelBufferCreateWithIOSurface → CGImage
//       或 IOSurfaceLock/GetBaseAddress → 直接读像素(找色用)
//   - 该链路走 WindowServer 渲染管线(依赖 global-capture entitlement), 与 App 自身
//     前后台状态无关, 因此切换到其他 App 后仍能取到真实屏幕像素。
//
//  本类提供三级截屏路径(自动回退):
//   1. 系统窗口路径(主): [UIWindow windowWithContextId:] + IOSurfaceAccelerator 链路
//   2. IOMFB 帧缓冲(回退): 前台场景可用, 后台/其他 App 前台时会拿到空 surface
//   3. 应用内截屏(兜底): 仅本 App 窗口

#import "TSScreenCapture.h"
#import <dlfcn.h>
#import <mach/mach.h>

// ---------- IOSurface / IOMobileFramebuffer 私有接口 ----------
typedef struct __IOSurface *IOSurfaceRef;

// IOMobileFramebuffer 私有函数指针
typedef kern_return_t (*IOMFBGetMainDisplayFunc)(void **fb);                    // IOMobileFramebufferGetMainDisplay(&fb)
// IOMobileFramebufferGetSurface 真实签名 3 参数: (fb, surfaceIndex, &surface)
typedef kern_return_t (*IOMFBGetSurfaceFunc)(void *fb, int surfaceIndex, IOSurfaceRef *surface);
typedef kern_return_t (*IOMFBGetLayerSurfaceFunc)(void *fb, int layer, IOSurfaceRef *surface); // iOS 15+, 3 参数

// IOSurfaceAccelerator 私有接口(对齐原版 HUD 截屏链路)
typedef kern_return_t (*IOSurfaceAccelCreateFunc)(CFAllocatorRef allocator, uint32_t type, void **acceleratorOut);
typedef kern_return_t (*IOSurfaceAccelTransferFunc)(void *accelerator, IOSurfaceRef sourceSurface,
                                                    IOSurfaceRef destSurface, CFDictionaryRef dict,
                                                    void **errorOut);
typedef CFTypeID (*IOSurfaceGetTypeIDFunc)(void);

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

#pragma mark - IOSurface 转储(对齐原版: 硬件/窗口 surface -> 加速器 -> 自建 BGRA surface)

/// 用 IOSurfaceAccelerator 把 source surface 转储到自建 BGRA surface 并读出 RGBA 像素。
/// 传输在 WindowServer 侧(GPU)执行，不依赖 App 自身渲染状态，后台/其他 App 前台仍可用。
- (BOOL)_dumpIOSurface:(IOSurfaceRef)sourceSurface
            pixelsOut:(uint8_t **)pixelsOut
               width:(int *)widthOut
              height:(int *)heightOut {
    if (!_iosurfaceHandle || !sourceSurface) { return NO; }

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

    size_t srcW = widthFn(sourceSurface);
    size_t srcH = heightFn(sourceSurface);
    if (srcW == 0 || srcH == 0) { return NO; }

    // 直接 IOSurfaceLock 读硬件输出 surface 在 iOS 15+/后台/部分机型不可靠(空内容),
    // 经 GPU 加速器转储到自建 surface 后能拿到稳定全屏像素(原版 HUD 的做法)。
    IOSurfaceRef readSurface = sourceSurface;
    IOSurfaceRef dstSurface = NULL;
    void *accel = NULL;
    if (accelCreateFn && accelTransferFn && createFn &&
        accelCreateFn(kCFAllocatorDefault, 0, &accel) == KERN_SUCCESS && accel) {
        CFMutableDictionaryRef props = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (props) {
            uint32_t bgra = 0x42475241; // 'BGRA'
            size_t bytesPerRow = srcW * 4;
            size_t allocSize = srcW * srcH * 4;
            CFNumberRef wNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &srcW);
            CFNumberRef hNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &srcH);
            CFNumberRef fmtNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bgra);
            CFNumberRef bprNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &bytesPerRow);
            CFNumberRef allocNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &allocSize);
            // 键名与原版 kIOSurface* 常量对应的字符串字面值一致
            CFDictionarySetValue(props, CFSTR("Width"), wNum);
            CFDictionarySetValue(props, CFSTR("Height"), hNum);
            CFDictionarySetValue(props, CFSTR("PixelFormat"), fmtNum);
            CFDictionarySetValue(props, CFSTR("BytesPerRow"), bprNum);
            CFDictionarySetValue(props, CFSTR("AllocSize"), allocNum);
            CFRelease(wNum); CFRelease(hNum); CFRelease(fmtNum);
            CFRelease(bprNum); CFRelease(allocNum);

            dstSurface = createFn(props);
            CFRelease(props);
        }
        if (dstSurface) {
            kern_return_t tr = accelTransferFn(accel, sourceSurface, dstSurface, NULL, NULL);
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

    uint8_t *out = malloc(w * h * 4);
    if (!out) {
        unlockFn(readSurface, 0, NULL);
        if (dstSurface) { CFRelease(dstSurface); }
        if (accel) { CFRelease(accel); }
        return NO;
    }

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

#pragma mark - IOMFB 帧缓冲(回退路径)

/// 尝试通过 IOMobileFramebuffer + IOSurface 截取整屏(前台场景可用)。
- (BOOL)_captureFramebufferToRGBA:(uint8_t **)pixelsOut
                           width:(int *)widthOut
                          height:(int *)heightOut {
    if (!_iomfbHandle || !_iosurfaceHandle) { return NO; }

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

    return [self _dumpIOSurface:surface pixelsOut:pixelsOut width:widthOut height:heightOut];
}

#pragma mark - 跨应用截屏: windowWithContextId 链路(对齐原版 HUD)

/// 动态调用 +[UIWindow windowWithContextId:] 创建绑定系统窗口 context 的远程窗口代理。
- (UIWindow *)_remoteWindowWithContextId:(unsigned int)contextId {
    SEL sel = NSSelectorFromString(@"windowWithContextId:");
    if (!sel || ![UIWindow respondsToSelector:sel]) { return nil; }
    NSMethodSignature *sig = [UIWindow methodSignatureForSelector:sel];
    if (!sig) { return nil; }
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = [UIWindow class];
    inv.selector = sel;
    [inv setArgument:&contextId atIndex:2];
    [inv invoke];
    __unsafe_unretained UIWindow *window = nil;
    [inv getReturnValue:&window];
    return window;
}

/// 获取主屏(contextId=0 表示主屏; 个别版本可从 UIScreen._contextId 读到)。
- (unsigned int)_mainScreenContextId {
    @try {
        id val = [[UIScreen mainScreen] valueForKey:@"_contextId"];
        if ([val respondsToSelector:@selector(unsignedIntValue)]) {
            return (unsigned int)[val unsignedIntValue];
        }
    } @catch (NSException *e) {
        // KVC 不可用时回退默认值
    }
    return 0;
}

/// 从远程窗口的 layer 多级尝试提取 source IOSurface。
/// 原版截屏核心: 窗口/合成 context 的 IOSurface 经 global-capture entitlement
/// 在 WindowServer 侧读取, 不依赖 App 自身前后台状态, 因此其他 App 前台时也能取到。
- (IOSurfaceRef)_sourceSurfaceFromWindow:(UIWindow *)window {
    if (!window || !_iosurfaceHandle) { return NULL; }
    CALayer *layer = window.layer;
    if (!layer) { return NULL; }
    IOSurfaceGetTypeIDFunc typeIdFn = (IOSurfaceGetTypeIDFunc)dlsym(_iosurfaceHandle, "IOSurfaceGetTypeID");
    if (!typeIdFn) { return NULL; }

    // 尝试 1: layer.contents 直接是 IOSurface(远程 layer 部分版本直接暴露)
    @try {
        id contents = [layer valueForKey:@"contents"];
        if (contents && CFGetTypeID((__bridge CFTypeRef)contents) == typeIdFn()) {
            return (__bridge IOSurfaceRef)contents;
        }
    } @catch (NSException *e) {}

    // 尝试 2: layer 的 CAContext(context) 的 surface(_surface/surface)
    // CAContext._surface 返回该 context 的渲染输出 IOSurface, 是原版链路的核心 source。
    @try {
        id caContext = [layer valueForKey:@"context"];
        if (caContext) {
            NSArray *keys = @[@"_surface", @"surface"];
            for (NSString *key in keys) {
                @try {
                    id surf = [caContext valueForKey:key];
                    if (surf && CFGetTypeID((__bridge CFTypeRef)surf) == typeIdFn()) {
                        return (__bridge IOSurfaceRef)surf;
                    }
                } @catch (NSException *e) {}
            }
        }
    } @catch (NSException *e) {}

    // 尝试 3: layer 直接暴露 _surface
    @try {
        id surf = [layer valueForKey:@"_surface"];
        if (surf && CFGetTypeID((__bridge CFTypeRef)surf) == typeIdFn()) {
            return (__bridge IOSurfaceRef)surf;
        }
    } @catch (NSException *e) {}

    // 尝试 4: 窗口层级的 keyWindow/rootViewController view 的 layer(兜底)
    @try {
        id surf = [window valueForKey:@"_surface"];
        if (surf && CFGetTypeID((__bridge CFTypeRef)surf) == typeIdFn()) {
            return (__bridge IOSurfaceRef)surf;
        }
    } @catch (NSException *e) {}

    return NULL;
}

/// 判断像素缓冲是否全黑(采样检测, 用于识别"截到了空 surface/黑屏")。
- (BOOL)_isAllZeroPixels:(uint8_t *)px width:(int)w height:(int)h {
    if (!px || w <= 0 || h <= 0) { return YES; }
    int total = w * h;
    int step = MAX(1, total / 4096); // 采样约 4096 个点
    for (int i = 0; i < total; i += step) {
        int off = i * 4;
        if (px[off] || px[off+1] || px[off+2]) { return NO; }
    }
    return YES;
}

/// 跨应用截屏主入口(线程安全封装, UIWindow 相关操作必须在主线程)。
- (BOOL)_captureSystemWindowToRGBA:(uint8_t **)pixelsOut
                             width:(int *)widthOut
                            height:(int *)heightOut {
    __block BOOL ok = NO;
    __block uint8_t *px = NULL;
    __block int w = 0, h = 0;
    void (^captureBlock)(void) = ^{
        @autoreleasepool {
            ok = [self _captureSystemWindowOnMainThreadToRGBA:&px width:&w height:&h];
        }
    };
    if ([NSThread isMainThread]) {
        captureBlock();
    } else {
        // 异步派发 + 超时, 保证 Lua 线程不被挂起(与 _captureAppWindowToRGBA 同一策略)
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            captureBlock();
            dispatch_semaphore_signal(sema);
        });
        if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC)) != 0) {
            return NO;
        }
    }
    if (ok && px) {
        *pixelsOut = px;
        *widthOut = w;
        *heightOut = h;
        return YES;
    }
    return NO;
}

/// 跨应用截屏核心(必须在主线程):
///   A. [UIWindow windowWithContextId:] → 远程窗口 → layer contents IOSurface → 加速器转储(对齐原版)
///   B. 远程窗口 drawViewHierarchyInRect:afterScreenUpdates:NO → 渲染快照(社区验证的跨应用截屏方案)
- (BOOL)_captureSystemWindowOnMainThreadToRGBA:(uint8_t **)pixelsOut
                                          width:(int *)widthOut
                                         height:(int *)heightOut {
    // 1. 创建绑定主屏 context 的远程窗口代理
    unsigned int contextId = [self _mainScreenContextId];
    UIWindow *remoteWindow = [self _remoteWindowWithContextId:contextId];
    if (!remoteWindow) {
        NSLog(@"[TSScreenCapture] windowWithContextId: 不可用(当前 iOS 版本不支持)");
        return NO;
    }
    // 对齐原版 HUD 窗口属性: 标记为系统窗口 + WindowServer 托管
    @try {
        [remoteWindow setValue:@YES forKey:@"_isSystemWindow"];
        [remoteWindow setValue:@YES forKey:@"_isWindowServerHostingManaged"];
    } @catch (NSException *e) {
        // 属性缺失时忽略, 不阻塞截屏
    }

    // 2. 路径 A: IOSurface 链路(对齐原版符号链, 后台/其他 App 前台也走这里)
    IOSurfaceRef src = [self _sourceSurfaceFromWindow:remoteWindow];
    if (src) {
        uint8_t *px = NULL; int w = 0, h = 0;
        if ([self _dumpIOSurface:src pixelsOut:&px width:&w height:&h] && px) {
            if (![self _isAllZeroPixels:px width:w height:h]) {
                NSLog(@"[TSScreenCapture] 系统窗口截屏成功(路径A/IOSurface) %dx%d contextId=%u", w, h, contextId);
                *pixelsOut = px; *widthOut = w; *heightOut = h;
                return YES;
            }
            NSLog(@"[TSScreenCapture] 路径A(IOSurface)取到空内容, 回退路径B");
            free(px);
        }
    } else {
        NSLog(@"[TSScreenCapture] 未从远程窗口获取到 IOSurface source, 走路径B(drawViewHierarchy)");
    }

    // 3. 路径 B: drawViewHierarchyInRect 渲染远程窗口快照(社区验证的跨应用截屏方案)
    CGRect r = remoteWindow.bounds;
    if (r.size.width < 1 || r.size.height < 1) {
        r = [UIScreen mainScreen].bounds;
        remoteWindow.frame = r;
    }
    CGFloat scale = [UIScreen mainScreen].scale;
    UIGraphicsBeginImageContextWithOptions(r.size, YES, scale);
    [remoteWindow drawViewHierarchyInRect:r afterScreenUpdates:NO];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!img) { return NO; }

    uint8_t *px = NULL; int w = 0, h = 0;
    if (![self _extractRGBAFromImage:img pixelsOut:&px width:&w height:&h] || !px) { return NO; }
    if ([self _isAllZeroPixels:px width:w height:h]) {
        NSLog(@"[TSScreenCapture] 远程窗口快照为空(全黑), 可能 contextId=%u 未绑定到实际屏幕", contextId);
        free(px);
        return NO;
    }
    NSLog(@"[TSScreenCapture] 系统窗口截屏成功(路径B/drawViewHierarchy) %dx%d contextId=%u", w, h, contextId);
    *pixelsOut = px; *widthOut = w; *heightOut = h;
    return YES;
}

#pragma mark - 应用内截屏回退(仅本 App 窗口)

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
        [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:YES];
        img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    };

    if ([NSThread isMainThread]) {
        captureBlock();
    } else {
        // 异步派发 + 300ms 超时, 保证 Lua 线程永远不被挂起
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
    // 1. 系统窗口截屏(对齐原版: 可截任意 App, 含其他 App 前台/后台场景)
    if ([self _captureSystemWindowToRGBA:pixelsOut width:widthOut height:heightOut]) {
        return YES;
    }
    // 2. IOMFB 帧缓冲(前台场景回退)
    if ([self _captureFramebufferToRGBA:pixelsOut width:widthOut height:heightOut]) {
        return YES;
    }
    // 3. 应用内截屏(兜底)
    UIApplicationState appState = [UIApplication sharedApplication].applicationState;
    NSLog(@"[TSScreenCapture] 跨应用截屏失败(appState=%ld: 0前台/1后台/2挂起)，回退应用内截屏",
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
