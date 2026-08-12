//
//  TSScreenCapture.m
//  TrollAutoTouch
//
//  屏幕截图 —— 对齐原版 TrollAutoScript 的截屏能力。
//
//  原版逆向结论(HUDServices + luaLib 符号级确认):
//   - 完全不用 IOMobileFramebuffer(GetMainDisplay/GetLayerDefaultSurface/GetSurface 均不存在)
//   - 完全不用 CARenderServerRenderDisplay(该符号在原版中不存在)
//   - 跨应用截屏链路为:
//       +[UIWindow windowWithContextId:](部分版本为 _windowWithContextId:)
//                                       → 绑定主屏 context 的远程窗口代理
//       [remoteWindow createScreenIOSurface](UIWindow 私有实例方法)
//                                       → 直接拿到该 context 的渲染输出 IOSurface
//                                         (无需自行 IOSurfaceCreate, 规避权限问题)
//       IOSurfaceLock / IOSurfaceGetBaseAddress / IOSurfaceGetBytesPerRow → 直接读像素(找色用)
//       (HUD 另备 IOSurfaceCreate + IOSurfaceAcceleratorTransferSurface 转储链路)
//   - 该链路走 WindowServer 渲染管线(依赖 global-capture entitlement), 与 App 自身
//     前后台状态无关, 因此切换到其他 App 后仍能取到真实屏幕像素。
//
//  本类提供四级截屏路径(自动回退):
//   0. 系统窗口(原版链路首选): windowWithContextId: + createScreenIOSurface
//   1. CARenderServerRenderDisplay: TrollShot 方案, 保留回退(依赖 IOSurfaceCreate, 可能受限)
//   2. IOMFB 帧缓冲(回退): 前台场景可用, 后台/其他 App 前台时会拿到空 surface
//   3. 应用内截屏(兜底): 仅本 App 窗口

#import "TSScreenCapture.h"
#import <dlfcn.h>
#import <mach/mach.h>
#import <unistd.h>

// ---------- IOSurface / IOMobileFramebuffer 私有接口 ----------
typedef struct __IOSurface *IOSurfaceRef;

// IOMobileFramebuffer 私有函数指针
typedef kern_return_t (*IOMFBGetMainDisplayFunc)(void **fb);                    // IOMobileFramebufferGetMainDisplay(&fb)
// IOMobileFramebufferGetSurface 真实签名 3 参数: (fb, surfaceIndex, &surface)
typedef kern_return_t (*IOMFBGetSurfaceFunc)(void *fb, int surfaceIndex, IOSurfaceRef *surface);
typedef kern_return_t (*IOMFBGetLayerSurfaceFunc)(void *fb, int layer, IOSurfaceRef *surface); // iOS 15+, 3 参数

// IOSurfaceAccelerator 私有接口(对齐原版 HUD 截屏链路)
typedef kern_return_t (*IOSurfaceAccelCreateFunc)(CFAllocatorRef allocator, uint32_t type, void **acceleratorOut);
// 真实签名 7 参数(参考 TrollShot/TrollVNC: accel, src, dst, NULL, NULL, NULL, NULL)
typedef kern_return_t (*IOSurfaceAccelTransferFunc)(void *accelerator, IOSurfaceRef sourceSurface,
                                                    IOSurfaceRef destSurface, void *p1, void *p2,
                                                    void *p3, void *p4);
typedef CFTypeID (*IOSurfaceGetTypeIDFunc)(void);
// CARenderServerRenderDisplay: 把主屏渲染到 IOSurface(TrollShot/TrollVNC 验证的 TrollStore 截屏方案)
typedef void (*CARenderServerRenderDisplayFunc)(kern_return_t a, CFStringRef display, IOSurfaceRef surface,
                                                int options, int a2);

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

// 记录失败原因到 lastError(Lua 层可见), 截屏成功路径需手动置 nil
#define TSSetLastError(...) do { \
    self.lastError = [NSString stringWithFormat:__VA_ARGS__]; \
} while (0)

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
            // BytesPerRow 需按 IOSurfaceAlignProperty 对齐(TrollShot 做法), 否则 IOSurfaceCreate 可能失败
            size_t (*alignPropFn)(CFStringRef, size_t) = dlsym(_iosurfaceHandle, "IOSurfaceAlignProperty");
            size_t bytesPerRow = alignPropFn ? alignPropFn(CFSTR("BytesPerRow"), srcW * 4) : srcW * 4;
            size_t allocSize = bytesPerRow * srcH;
            // 数值统一 32 位 SInt32(与 TrollShot @(int) 一致):
            // IOSurfaceCreate 对 CFNumber 字节宽度敏感, 用 64 位 long 会导致属性解析失败返回 NULL
            int wl = (int)srcW, hl = (int)srcH;
            int bprl = (int)bytesPerRow, allocl = (int)allocSize;
            CFNumberRef wNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &wl);
            CFNumberRef hNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &hl);
            CFNumberRef fmtNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bgra);
            CFNumberRef bprNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bprl);
            CFNumberRef allocNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &allocl);
            // 键名与原版 kIOSurface* 常量对应的字符串字面值一致
            CFDictionarySetValue(props, CFSTR("Width"), wNum);
            CFDictionarySetValue(props, CFSTR("Height"), hNum);
            CFDictionarySetValue(props, CFSTR("PixelFormat"), fmtNum);
            CFDictionarySetValue(props, CFSTR("BytesPerRow"), bprNum);
            CFDictionarySetValue(props, CFSTR("AllocSize"), allocNum);
            // 对齐 TrollShot: BytesPerElement + sRGB ColorSpace
            int bpe = 4;
            CFNumberRef bpeNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bpe);
            if (bpeNum) {
                CFDictionarySetValue(props, CFSTR("BytesPerElement"), bpeNum);
                CFRelease(bpeNum);
            }
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            if (cs) {
                CFPropertyListRef csProps = CGColorSpaceCopyPropertyList(cs);
                CGColorSpaceRelease(cs);
                if (csProps) {
                    CFDictionarySetValue(props, CFSTR("ColorSpace"), csProps);
                    CFRelease(csProps);
                }
            }
            CFRelease(wNum); CFRelease(hNum); CFRelease(fmtNum);
            CFRelease(bprNum); CFRelease(allocNum);

            dstSurface = createFn(props);
            CFRelease(props);
        }
        if (dstSurface) {
            // 真实签名 7 参数(对齐 TrollShot/TrollVNC)
            kern_return_t tr = accelTransferFn(accel, sourceSurface, dstSurface, NULL, NULL, NULL, NULL);
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
        TSSetLastError(@"路径2 IOMFB: 获取帧缓冲 surface 失败 kr=%d", (int)kr);
        NSLog(@"[TSScreenCapture] 获取帧缓冲 surface 失败 kr=%d", (int)kr);
        return NO;
    }

    // IOMFB 帧缓冲在后台/其他 App 前台时可能返回空 surface(IOSurfaceLock 读到全 0),
    // 加全 0 检测, 避免静默返回黑屏让 getColor 误判成 0x000000。
    uint8_t *px = NULL; int w = 0, h = 0;
    if (![self _dumpIOSurface:surface pixelsOut:&px width:&w height:&h] || !px) { return NO; }
    if ([self _isAllZeroPixels:px width:w height:h]) {
        NSLog(@"[TSScreenCapture] IOMFB 帧缓冲截到空内容(全 0)，后台帧缓冲不可读");
        free(px);
        return NO;
    }
    *pixelsOut = px; *widthOut = w; *heightOut = h;
    return YES;
}

#pragma mark - 跨应用截屏: CARenderServerRenderDisplay(TrollShot/TrollVNC 验证的 TrollStore 方案)

/// 屏幕物理像素尺寸(截屏目标尺寸)。
- (CGSize)_screenPixelSize {
    // 优先私有 API _unjailedReferenceBoundsInPixels(TrollShot 使用), 得到未裁剪的真实像素尺寸
    @try {
        id v = [[UIScreen mainScreen] valueForKey:@"_unjailedReferenceBoundsInPixels"];
        if ([v isKindOfClass:[NSValue class]]) {
            CGRect r;
            [v getValue:&r];
            if (r.size.width > 0 && r.size.height > 0) { return r.size; }
        }
    } @catch (NSException *e) {}
    CGSize n = [UIScreen mainScreen].nativeBounds.size;
    if (n.width > 0 && n.height > 0) { return n; }
    CGSize b = [UIScreen mainScreen].bounds.size;
    CGFloat s = [UIScreen mainScreen].scale;
    return CGSizeMake(b.width * s, b.height * s);
}

/// 创建 BGRA IOSurface(参数键与 TrollShot 一致; BytesPerRow 经 IOSurfaceAlignProperty 对齐)。
- (IOSurfaceRef)_createIOSurfaceWithWidth:(int)w height:(int)h {
    if (!_iosurfaceHandle || w <= 0 || h <= 0) { return NULL; }
    IOSurfaceRef (*createFn)(CFDictionaryRef) = dlsym(_iosurfaceHandle, "IOSurfaceCreate");
    if (!createFn) { return NULL; }
    size_t (*alignPropFn)(CFStringRef, size_t) = dlsym(_iosurfaceHandle, "IOSurfaceAlignProperty");
    uint32_t bgra = 0x42475241; // 'BGRA'
    size_t bytesPerRow = alignPropFn ? alignPropFn(CFSTR("BytesPerRow"), (size_t)w * 4) : (size_t)w * 4;
    size_t allocSize = bytesPerRow * h;
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!props) { return NULL; }
    // 数值统一 32 位 SInt32(与 TrollShot @(int) 一致):
    // IOSurfaceCreate 对 CFNumber 字节宽度敏感, 用 64 位 long 会导致属性解析失败返回 NULL
    int wl = w, hl = h, bprl = (int)bytesPerRow, allocl = (int)allocSize;
    CFNumberRef wNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &wl);
    CFNumberRef hNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &hl);
    CFNumberRef fmtNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bgra);
    CFNumberRef bprNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bprl);
    CFNumberRef allocNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &allocl);
    CFDictionarySetValue(props, CFSTR("Width"), wNum);
    CFDictionarySetValue(props, CFSTR("Height"), hNum);
    CFDictionarySetValue(props, CFSTR("PixelFormat"), fmtNum);
    CFDictionarySetValue(props, CFSTR("BytesPerRow"), bprNum);
    CFDictionarySetValue(props, CFSTR("AllocSize"), allocNum);
    // 对齐 TrollShot: BytesPerElement + sRGB ColorSpace(WindowServer 渲染与 accel 转换需要)
    int bpe = 4;
    CFNumberRef bpeNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bpe);
    if (bpeNum) {
        CFDictionarySetValue(props, CFSTR("BytesPerElement"), bpeNum);
        CFRelease(bpeNum);
    }
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (cs) {
        CFPropertyListRef csProps = CGColorSpaceCopyPropertyList(cs);
        CGColorSpaceRelease(cs);
        if (csProps) {
            CFDictionarySetValue(props, CFSTR("ColorSpace"), csProps);
            CFRelease(csProps);
        }
    }
    CFRelease(wNum); CFRelease(hNum); CFRelease(fmtNum);
    CFRelease(bprNum); CFRelease(allocNum);
    IOSurfaceRef surf = createFn(props);
    CFRelease(props);
    return surf;
}

/// 直接把主屏渲染到 IOSurface 后读取像素。
/// CARenderServerRenderDisplay 是 QuartzCore 私有函数, 请求 WindowServer 把当前屏幕
/// 渲染到指定 surface; 走系统渲染管线, 与 App 自身前后台无关(TrollShot 后台 daemon 验证)。
- (BOOL)_captureRenderServerToRGBA:(uint8_t **)pixelsOut
                             width:(int *)widthOut
                            height:(int *)heightOut {
    if (!_iosurfaceHandle) {
        TSSetLastError(@"路径0 CARenderServer: IOSurface 框架加载失败");
        return NO;
    }
    static CARenderServerRenderDisplayFunc renderFn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 对齐 TrollShot: CARenderServerRenderDisplay(0, "LCD", surface, 0, 0)
        renderFn = (CARenderServerRenderDisplayFunc)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    });
    if (!renderFn) {
        TSSetLastError(@"路径0 CARenderServer: CARenderServerRenderDisplay 符号不可用(该 iOS 无此私有 API)");
        NSLog(@"[TSScreenCapture] CARenderServerRenderDisplay 不可用(私有符号缺失)");
        return NO;
    }

    CGSize sz = [self _screenPixelSize];
    int w = (int)sz.width, h = (int)sz.height;
    if (w <= 0 || h <= 0) {
        TSSetLastError(@"路径0 CARenderServer: 屏幕尺寸无效 %dx%d", w, h);
        return NO;
    }
    NSLog(@"[TSScreenCapture] 尝试 CARenderServerRenderDisplay 截屏 %dx%d", w, h);

    IOSurfaceRef src = [self _createIOSurfaceWithWidth:w height:h];
    if (!src) {
        TSSetLastError(@"路径0 CARenderServer: 创建 IOSurface 失败 %dx%d", w, h);
        NSLog(@"[TSScreenCapture] CARenderServer 方案创建 IOSurface 失败 %dx%d", w, h);
        return NO;
    }

    // 与 TrollShot 完全一致: 首参传 0, 显示名 "LCD"; "Main" 作为个别版本回退
    const char *displayNames[2] = { "LCD", "Main" };
    for (int attempt = 0; attempt < 2; attempt++) {
        CFStringRef display = CFStringCreateWithCString(kCFAllocatorDefault,
                                                        displayNames[attempt],
                                                        kCFStringEncodingUTF8);
        renderFn(0, display, src, 0, 0);
        CFRelease(display);
        // 等 WindowServer 完成异步渲染再读
        usleep(100 * 1000);

        uint8_t *px = NULL; int rw = 0, rh = 0;
        if ([self _dumpIOSurface:src pixelsOut:&px width:&rw height:&rh] && px) {
            if (![self _isAllZeroPixels:px width:rw height:rh]) {
                NSLog(@"[TSScreenCapture] CARenderServer 截屏成功 %dx%d (display=%s)",
                      rw, rh, displayNames[attempt]);
                self.lastError = nil;
                *pixelsOut = px; *widthOut = rw; *heightOut = rh;
                CFRelease(src);
                return YES;
            }
            TSSetLastError(@"路径0 CARenderServer: display=%s 渲染结果全空(可能被 WindowServer 拒绝)", displayNames[attempt]);
            NSLog(@"[TSScreenCapture] CARenderServer display=%s 取到空内容", displayNames[attempt]);
            free(px);
        } else {
            TSSetLastError(@"路径0 CARenderServer: display=%s 读 surface 失败", displayNames[attempt]);
            NSLog(@"[TSScreenCapture] CARenderServer display=%s 读 surface 失败", displayNames[attempt]);
        }
    }

    NSLog(@"[TSScreenCapture] CARenderServerRenderDisplay 两次渲染均取到空内容");
    CFRelease(src);
    return NO;
}

#pragma mark - 跨应用截屏: windowWithContextId 链路(对齐原版 HUD)

/// 动态调用 windowWithContextId: 系列私有 API 创建绑定主屏/系统 context 的远程窗口代理。
/// 逆向原版: selector 名因 iOS 版本而异(`windowWithContextId:` / `_windowWithContextId:`),
/// 所在类也因版本而异(UIWindow 类方法 / UIApplication / UIScreen 实例方法), 全部尝试。
- (UIWindow *)_remoteWindowWithContextId:(unsigned int)contextId {
    NSArray<NSString *> *selNames = @[@"windowWithContextId:", @"_windowWithContextId:"];
    NSArray *targets = @[ [UIWindow class], [UIApplication sharedApplication], [UIScreen mainScreen] ];
    for (NSString *selName in selNames) {
        SEL sel = NSSelectorFromString(selName);
        if (!sel) { continue; }
        for (id target in targets) {
            if (!target) { continue; }
            // respondsToSelector 对类对象检查类方法、实例对象检查实例方法, 语义正确
            if (![target respondsToSelector:sel]) { continue; }
            NSMethodSignature *sig = [target methodSignatureForSelector:sel];
            if (!sig || sig.methodReturnLength < sizeof(void *)) { continue; }
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = target;
            inv.selector = sel;
            [inv setArgument:&contextId atIndex:2];
            @try {
                [inv invoke];
                __unsafe_unretained UIWindow *window = nil;
                [inv getReturnValue:&window];
                if (window) {
                    NSLog(@"[TSScreenCapture] 远程窗口创建成功 sel=%@ target=%@ contextId=%u",
                          selName, NSStringFromClass([target class]), contextId);
                    return window;
                }
            } @catch (NSException *e) {
                NSLog(@"[TSScreenCapture] %@ 调用异常: %@", selName, e);
            }
        }
    }
    return nil;
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

/// 从远程窗口提取 source IOSurface。
/// 原版截屏核心(luaLib 符号确认): [window createScreenIOSurface] 返回窗口/绑定 context
/// 的渲染输出 IOSurface, 无需自行 IOSurfaceCreate; 后续 layer.contents/CAContext._surface
/// 仅为不同 iOS 版本的兜底。
- (IOSurfaceRef)_sourceSurfaceFromWindow:(UIWindow *)window {
    if (!window || !_iosurfaceHandle) { return NULL; }
    IOSurfaceGetTypeIDFunc typeIdFn = (IOSurfaceGetTypeIDFunc)dlsym(_iosurfaceHandle, "IOSurfaceGetTypeID");
    if (!typeIdFn) { return NULL; }

    // 尝试 0: [window createScreenIOSurface](原版调用, 返回渲染输出 IOSurface)
    SEL csis = NSSelectorFromString(@"createScreenIOSurface");
    if (csis && [window respondsToSelector:csis]) {
        NSMethodSignature *sig = [window methodSignatureForSelector:csis];
        if (sig && sig.methodReturnLength >= sizeof(void *)) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = window;
            inv.selector = csis;
            @try {
                [inv invoke];
                __unsafe_unretained IOSurfaceRef ios = NULL;
                [inv getReturnValue:&ios];
                if (ios && CFGetTypeID(ios) == typeIdFn()) {
                    NSLog(@"[TSScreenCapture] createScreenIOSurface 获取 IOSurface 成功");
                    return ios;
                }
            } @catch (NSException *e) {
                NSLog(@"[TSScreenCapture] createScreenIOSurface 异常: %@", e);
            }
        }
    }

    CALayer *layer = window.layer;
    if (!layer) { return NULL; }

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
        TSSetLastError(@"路径1 系统窗口: windowWithContextId: 系列均不可用(contextId=%u)");
        NSLog(@"[TSScreenCapture] windowWithContextId: 系列均不可用 contextId=%u", contextId);
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
                self.lastError = nil;
                *pixelsOut = px; *widthOut = w; *heightOut = h;
                return YES;
            }
            TSSetLastError(@"路径1 系统窗口: 路径A(IOSurface)取到空内容");
            NSLog(@"[TSScreenCapture] 路径A(IOSurface)取到空内容, 回退路径B");
            free(px);
        } else {
            TSSetLastError(@"路径1 系统窗口: 路径A dump IOSurface 失败");
        }
    } else {
        TSSetLastError(@"路径1 系统窗口: 未从远程窗口获取到 IOSurface source");
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
    if (!img) {
        TSSetLastError(@"路径1 系统窗口: drawViewHierarchy 未生成图像");
        return NO;
    }

    uint8_t *px = NULL; int w = 0, h = 0;
    if (![self _extractRGBAFromImage:img pixelsOut:&px width:&w height:&h] || !px) {
        TSSetLastError(@"路径1 系统窗口: 快照转 RGBA 失败");
        return NO;
    }
    if ([self _isAllZeroPixels:px width:w height:h]) {
        TSSetLastError(@"路径1 系统窗口: 远程窗口快照全黑(contextId=%u 未绑定实际屏幕)", contextId);
        NSLog(@"[TSScreenCapture] 远程窗口快照为空(全黑), 可能 contextId=%u 未绑定到实际屏幕", contextId);
        free(px);
        return NO;
    }
    NSLog(@"[TSScreenCapture] 系统窗口截屏成功(路径B/drawViewHierarchy) %dx%d contextId=%u", w, h, contextId);
    self.lastError = nil;
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
        TSSetLastError(@"路径3 应用内: App 在后台, 应用内截屏会全黑已跳过");
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
    // 0. 系统窗口截屏(原版链路首选: windowWithContextId:+createScreenIOSurface, 不依赖 IOSurfaceCreate)
    if ([self _captureSystemWindowToRGBA:pixelsOut width:widthOut height:heightOut]) {
        return YES;
    }
    NSString *err0 = [self.lastError copy];
    // 1. CARenderServerRenderDisplay: 主屏渲染到 IOSurface(TrollShot 方案, 保留回退)
    if ([self _captureRenderServerToRGBA:pixelsOut width:widthOut height:heightOut]) {
        return YES;
    }
    NSString *err1 = [self.lastError copy];
    // 2. IOMFB 帧缓冲(前台场景回退)
    if ([self _captureFramebufferToRGBA:pixelsOut width:widthOut height:heightOut]) {
        return YES;
    }
    NSString *err2 = [self.lastError copy];
    // 3. 应用内截屏(兜底)
    UIApplicationState appState = [UIApplication sharedApplication].applicationState;
    NSLog(@"[TSScreenCapture] 跨应用截屏失败(appState=%ld: 0前台/1后台/2挂起)，回退应用内截屏",
          (long)appState);
    BOOL ok = [self _captureAppWindowToRGBA:pixelsOut width:widthOut height:heightOut];
    if (ok) { return YES; }
    // 汇总全部路径失败原因, 供 Lua 层展示(NSLog 普通用户看不到)
    self.lastError = [NSString stringWithFormat:@"系统窗口: %@; CARenderServer: %@; IOMFB: %@; 应用内: %@",
                      err0 ?: @"未尝试", err1 ?: @"未尝试", err2 ?: @"未尝试", self.lastError ?: @"未尝试"];
    return NO;
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
