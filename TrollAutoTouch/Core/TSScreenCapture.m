//
//  TSScreenCapture.m
//  TrollAutoTouch
//
//  屏幕截图 —— 对齐原版 TrollAutoScript 的截屏能力。
//
//  原版逆向结论(HUDServices 反汇编 + luaLib 符号级确认):
//   - 完全不用 IOMobileFramebuffer(GetMainDisplay/GetLayerDefaultSurface/GetSurface 均不存在)
//   - 完全不用 CARenderServerRenderDisplay(该符号在原版中不存在)
//   - 跨应用截屏核心链路为(反汇编 0x100056464 确认):
//       receiver = [UIScreen mainScreen]
//       [receiver performSelector:@selector(createScreenIOSurface)]   ← UIScreen 实例私有方法
//                                       → 返回绑定主屏渲染管线的**全屏 IOSurface**
//                                         (系统级创建, 无需 IOSurfaceCreate,
//                                          后台/跨 App 可用 —— 与所有自建 surface 方案的关键差异)
//       IOSurfaceLock / IOSurfaceGetBaseAddress / IOSurfaceGetBytesPerRow → 直接读像素(找色用)
//       (HUD 另备 IOSurfaceCreate + IOSurfaceAcceleratorTransferSurface 转储链路)
//   - 该链路走 WindowServer 渲染管线(依赖 global-capture entitlement), 与 App 自身
//     前后台状态无关, 因此切换到其他 App 后仍能取到真实屏幕像素。
//
//  本类提供多级截屏路径(自动回退):
//   0. UIScreen createScreenIOSurface(原版核心链路首选, iOS12+ 私有 API)
//   1. 系统窗口: windowWithContextId: + createScreenIOSurface
//   2. 全局显示: IORegistry DisplaySurface + IOSurfaceLookup(拿现成 surface)
//   3. CARenderServerRenderDisplay: TrollShot 方案, 保留回退(依赖 IOSurfaceCreate, 可能受限)
//   4. IOMFB 帧缓冲(回退): 前台场景可用, 后台/其他 App 前台时会拿到空 surface
//   5. 应用内截屏(兜底): 仅本 App 窗口

#import "TSScreenCapture.h"
#import <dlfcn.h>
#import <mach/mach.h>
#import <unistd.h>
#import <IOKit/IOKitLib.h>
#import <CoreGraphics/CoreGraphics.h>

// MARK: - Display P3 广色域 → sRGB 转换
// iPhone 7 及之后的屏幕为 Display P3 广色域，IOSurface 像素是 P3 值。
// 若直接按 sRGB 解释/显示会整体偏淡、发灰，导致找色、取色颜色与手机屏幕不一致。
// 此转换把所有像素统一到标准 sRGB，保证截图、取色、Lua 脚本比对颜色完全一致。
// sRGB 屏（如 iPhone 6s）检测为 NO，行为与原版完全一致，无任何性能损失。
static float _srgbToLinearLUT[256];
static uint8_t _linearToSrgbLUT[4096];

static void _initColorLUTs(void) {
    for (int i = 0; i < 256; i++) {
        double v = i / 255.0;
        _srgbToLinearLUT[i] = (float)(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4));
    }
    for (int i = 0; i < 4096; i++) {
        double v = i / 4095.0;
        double o = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
        int b = (int)lround(o * 255.0);
        _linearToSrgbLUT[i] = (uint8_t)(b < 0 ? 0 : (b > 255 ? 255 : b));
    }
}

static void _ensureColorLUTs(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ _initColorLUTs(); });
}

static inline uint8_t _srgbEncode(float lin) {
    if (lin <= 0.0f) return 0;
    if (lin >= 1.0f) return 255;
    int idx = (int)(lin * 4095.0f + 0.5f);
    return _linearToSrgbLUT[idx < 0 ? 0 : (idx > 4095 ? 4095 : idx)];
}

// 屏幕是否为 P3 广色域
static BOOL _screenUsesP3(void) {
    static BOOL p3 = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIScreen *screen = [UIScreen mainScreen];
        if ([screen respondsToSelector:@selector(traitCollection)]) {
            p3 = (screen.traitCollection.displayGamut == UIDisplayGamutP3);
        }
    });
    return p3;
}

// ---------- IOSurface / IOMobileFramebuffer 私有接口 ----------
typedef struct __IOSurface *IOSurfaceRef;

// IOSurfaceLookup: 通过 surface ID 映射到已存在的全局 IOSurface(不创建, 跨进程)
typedef IOSurfaceRef (*IOSurfaceLookupFunc)(uint32_t surfaceID);

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
// _UICreateCGImageFromIOSurface: UIKit 私有函数, 直接把 IOSurface 转成 CGImage。
// AutoTouch(HUDServices) 主截屏链路 = createScreenIOSurface -> IOSurfaceAcceleratorTransferSurface
//   -> _UICreateCGImageFromIOSurface(dst) 生成图像(0x100057378 反汇编确认)。
typedef CGImageRef (*UICreateCGImageFromIOSurfaceFunc)(IOSurfaceRef surface);

@interface TSScreenCapture () {
    void *_iomfbHandle;
    void *_iosurfaceHandle;
    // keep 缓存
    uint8_t  *_cachedPixels;
    int       _cachedWidth;
    int       _cachedHeight;
    // UIScreen createScreenIOSurface 缓存:
    // surface 绑定主屏渲染管线, 内容由 WindowServer 持续更新, 可长期复用。
    // 后台线程直接读缓存 surface, 避免高频 findColor 每次阻塞/占用主线程。
    IOSurfaceRef _cachedScreenSurface;   // 主线程创建, 跨线程读取(锁保护)
    NSTimeInterval _cachedSurfaceTime;   // 创建时刻(用于异步刷新节流)
    BOOL _surfaceRefreshPending;         // 异步刷新进行中标志
    BOOL _hideWindowsWhenCapturing;      // 后台截屏实验: 创建 surface 前临时隐藏本 App 所有窗口
                                         // (模拟原版 HUDServices 独立无窗口进程, 让 createScreenIOSurface
                                         //   不再绑定本 App 画面)
    // _UICreateCGImageFromIOSurface 函数指针(AutoTouch 原版主截屏读取路径)
    UICreateCGImageFromIOSurfaceFunc _uiCreateCGImageFn;
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
        // _UICreateCGImageFromIOSurface 是 UIKit 私有函数(AutoTouch 原版主截屏路径的读取端)
        _uiCreateCGImageFn = (UICreateCGImageFromIOSurfaceFunc)dlsym(RTLD_DEFAULT, "_UICreateCGImageFromIOSurface");
        if (!_uiCreateCGImageFn) {
            void *uiKit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY);
            if (uiKit) {
                _uiCreateCGImageFn = (UICreateCGImageFromIOSurfaceFunc)dlsym(uiKit, "_UICreateCGImageFromIOSurface");
            }
        }
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
    uint32_t srcFmt = pixelFormatFn ? pixelFormatFn(sourceSurface) : 0;
    NSLog(@"[TSScreenCapture] _dumpIOSurface source=%zux%zu fmt=0x%08X", srcW, srcH, (unsigned int)srcFmt);
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

    // ---- 读取 ----
    // iOS 16+ 上 _UICreateCGImageFromIOSurface 会把 dstSurface 标称的格式/色彩空间
    // 当成真实属性处理, 而 IOSurfaceAcceleratorTransferSurface 仅做像素转储,
    // 该函数对源格式/位深的解释可能与实际不符, 导致像素通道严重错乱
    // (用户反馈截图呈"热成像"伪彩色, 找色完全失败)。
    // 因此强制改用 IOSurfaceLock 直接读取我们自建的 BGRA8 dstSurface:
    // 格式已知、可按 BGRA 稳定解析, 并在下方统一做 P3->sRGB 转换。
    (void)_uiCreateCGImageFn; // 保留初始化, 不再调用

    // ---- 读取: 加锁读取 readSurface(加速器成功时即 dstSurface; 否则为源 surface) ----
    kern_return_t lk = lockFn(readSurface, 0 /*对齐原版 mov w1,#0*/, NULL);
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
    // P3 广色域屏需要把像素转换到 sRGB（sRGB 屏为 NO，行为与原版一致）
    BOOL p3ToSrgb = _screenUsesP3();
    if (p3ToSrgb) {
        _ensureColorLUTs();
    }
    for (size_t y = 0; y < h; y++) {
        uint8_t *src = (uint8_t *)base + y * bpr;
        uint8_t *dst = out + y * w * 4;
        for (size_t x = 0; x < w; x++) {
            if (fmt == 0x42475241 /*BGRA*/) {
                uint8_t R = src[x*4+2];
                uint8_t G = src[x*4+1];
                uint8_t B = src[x*4+0];
                if (p3ToSrgb) {
                    // Display P3 → sRGB（线性域 3x3 矩阵，D65 白点）
                    float rl = _srgbToLinearLUT[R];
                    float gl = _srgbToLinearLUT[G];
                    float bl = _srgbToLinearLUT[B];
                    dst[x*4+0] = _srgbEncode( 1.224940f*rl - 0.224940f*gl);
                    dst[x*4+1] = _srgbEncode(-0.042057f*rl + 1.042057f*gl);
                    dst[x*4+2] = _srgbEncode(-0.019644f*rl - 0.078644f*gl + 1.098289f*bl);
                    dst[x*4+3] = 255;
                } else {
                    dst[x*4+0] = R;
                    dst[x*4+1] = G;
                    dst[x*4+2] = B;
                    dst[x*4+3] = 255;
                }
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
    if (!_iosurfaceHandle) {
        TSSetLastError(@"路径3 IOMFB: IOSurface 框架加载失败");
        return NO;
    }
    // 符号查找: 句柄内优先, RTLD_DEFAULT 全局符号表兜底(对齐无忧辅助 dlsym(RTLD_DEFAULT,...))
    IOMFBGetMainDisplayFunc getMain = _iomfbHandle
        ? (IOMFBGetMainDisplayFunc)dlsym(_iomfbHandle, "IOMobileFramebufferGetMainDisplay")
        : NULL;
    if (!getMain) {
        getMain = (IOMFBGetMainDisplayFunc)dlsym(RTLD_DEFAULT, "IOMobileFramebufferGetMainDisplay");
    }
    if (!getMain) {
        TSSetLastError(@"路径3 IOMFB: IOMobileFramebufferGetMainDisplay 符号不可用(框架未加载)");
        return NO;
    }

    void *fb = NULL;
    kern_return_t krMain = getMain(&fb);
    if (krMain != KERN_SUCCESS || !fb) {
        TSSetLastError(@"路径3 IOMFB: GetMainDisplay 失败 kr=%d", (int)krMain);
        return NO;
    }

    IOSurfaceRef surface = NULL;
    kern_return_t kr = KERN_FAILURE;

    // 优先 iOS 15+ 的 IOMobileFramebufferGetLayerDefaultSurface(fb, layer, &surface),
    // 个别机型/版本主屏不在 layer 0, 逐个尝试直到拿到 surface。
    IOMFBGetLayerSurfaceFunc getLayerSurface = _iomfbHandle
        ? (IOMFBGetLayerSurfaceFunc)dlsym(_iomfbHandle, "IOMobileFramebufferGetLayerDefaultSurface")
        : NULL;
    if (!getLayerSurface) {
        getLayerSurface = (IOMFBGetLayerSurfaceFunc)dlsym(RTLD_DEFAULT, "IOMobileFramebufferGetLayerDefaultSurface");
    }
    if (getLayerSurface) {
        for (int layer = 0; layer < 4; layer++) {
            surface = NULL;
            kr = getLayerSurface(fb, layer, &surface);
            if (kr == KERN_SUCCESS && surface) { break; }
        }
    } else {
        // iOS 14 及更早: IOMobileFramebufferGetSurface(fb, 0, &surface) —— 3 个参数!
        IOMFBGetSurfaceFunc getSurface = _iomfbHandle
            ? (IOMFBGetSurfaceFunc)dlsym(_iomfbHandle, "IOMobileFramebufferGetSurface")
            : NULL;
        if (!getSurface) {
            getSurface = (IOMFBGetSurfaceFunc)dlsym(RTLD_DEFAULT, "IOMobileFramebufferGetSurface");
        }
        if (getSurface) {
            surface = NULL;
            kr = getSurface(fb, 0, &surface);
        } else {
            TSSetLastError(@"路径3 IOMFB: GetSurface/GetLayerDefaultSurface 符号均不可用");
            return NO;
        }
    }
    if (kr != KERN_SUCCESS || !surface) {
        TSSetLastError(@"路径3 IOMFB: 获取帧缓冲 surface 失败 kr=%d", (int)kr);
        NSLog(@"[TSScreenCapture] 获取帧缓冲 surface 失败 kr=%d", (int)kr);
        return NO;
    }

    // IOMFB 帧缓冲在后台/其他 App 前台时可能返回空 surface(IOSurfaceLock 读到全 0),
    // 加全 0 检测, 避免静默返回黑屏让 getColor 误判成 0x000000。
    uint8_t *px = NULL; int w = 0, h = 0;
    if (![self _dumpIOSurface:surface pixelsOut:&px width:&w height:&h] || !px) {
        TSSetLastError(@"路径3 IOMFB: 转储帧缓冲 surface 失败");
        return NO;
    }
    if ([self _isAllZeroPixels:px width:w height:h]) {
        NSLog(@"[TSScreenCapture] IOMFB 帧缓冲截到空内容(全 0)，后台帧缓冲不可读");
        free(px);
        return NO;
    }
    *pixelsOut = px; *widthOut = w; *heightOut = h;
    return YES;
}

#pragma mark - 跨应用截屏: UIScreen createScreenIOSurface(最优先, 原版 HUD 核心链路)

// 逆向反汇编确认(HUDServices 0x100056464):
//   receiver = [UIScreen mainScreen]
//   [receiver performSelector:@selector(createScreenIOSurface)]
// createScreenIOSurface 是 UIScreen 实例私有方法(iOS 12+), 返回绑定主屏渲染管线的
// **全屏 IOSurface**, 由系统在 WindowServer 侧创建/维护 —— 无需自行 IOSurfaceCreate,
// 不依赖 contextId/CARenderServer, 后台/切到其他 App 后仍能取到真实屏幕像素。
// 拿到 surface 后复用 _dumpIOSurface: 转储链路(优先加速器, 失败直读)读 RGBA。
// 必须在主线程调用(createScreenIOSurface 是 UIScreen/UIWindow 相关私有方法)。
// 返回的 IOSurface 绑定主屏渲染管线, 内容由 WindowServer 持续更新, 可长期复用。
- (IOSurfaceRef)_createUIScreenSurface {
    if (!_iosurfaceHandle) { return NULL; }
    IOSurfaceGetTypeIDFunc typeIdFn = (IOSurfaceGetTypeIDFunc)dlsym(_iosurfaceHandle, "IOSurfaceGetTypeID");
    if (!typeIdFn) { return NULL; }

    SEL sel = NSSelectorFromString(@"createScreenIOSurface");
    if (!sel) { return NULL; }

    IOSurfaceRef result = NULL;
    @try {
        // 逆向结论(AutoTouch 原版 HUDServices 反汇编):
        // receiver 是 [UIScreen mainScreen] 或类对象, 调用形态为 objc_msgSend(recv, @selector(createScreenIOSurface))。
        // 注意: 原版**不隐藏本 App 窗口**, createScreenIOSurface 返回的 surface 由 WindowServer 维护,
        // 内容始终是系统当前帧(与 App 前后台无关), 隐藏窗口反而会破坏创建。
        // 按兼容性列出全部候选: 类方法优先, 实例方法兜底。
        NSMutableArray *candidates = [NSMutableArray array];
        [candidates addObject:[UIWindow class]];                  // +[UIWindow createScreenIOSurface](逆向+社区首选)
        [candidates addObject:[UIScreen mainScreen]];             // -[UIScreen createScreenIOSurface](原版 receiver)
        [candidates addObject:[UIScreen class]];                  // +[UIScreen createScreenIOSurface](个别版本)
        @try {
            UIApplication *app = [UIApplication sharedApplication];
            if (app) {
                UIWindow *kw = [app valueForKey:@"keyWindow"];
                if (kw) { [candidates addObject:kw]; }            // -[keyWindow createScreenIOSurface]
                NSArray *wins = [app valueForKey:@"windows"];
                for (UIWindow *w in wins) {
                    if (w && w != kw) { [candidates addObject:w]; }
                }
            }
        } @catch (NSException *e) { }

        for (id target in candidates) {
            if (!target) { continue; }
            @try {
                if (![target respondsToSelector:sel]) { continue; }
                NSMethodSignature *sig = [target methodSignatureForSelector:sel];
                if (!sig || sig.methodReturnLength < sizeof(void *)) { continue; }
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = target;
                inv.selector = sel;
                [inv invoke];
                __unsafe_unretained IOSurfaceRef ios = NULL;
                [inv getReturnValue:&ios];
                if (ios && CFGetTypeID(ios) == typeIdFn()) {
                    result = ios;
                    break;
                }
            } @catch (NSException *e) { }
        }
    } @catch (NSException *e) { }
    return result;
}

// ---- 缓存: 复用同一个绑定主屏渲染管线的 surface, 后台线程直接读像素, 不再每次阻塞主线程 ----

- (IOSurfaceRef)_getCachedScreenSurface {
    @synchronized (self) {
        if (!_cachedScreenSurface) { return NULL; }
        return (IOSurfaceRef)CFRetain(_cachedScreenSurface);
    }
}

- (void)_setCachedScreenSurface:(IOSurfaceRef)s {
    @synchronized (self) {
        if (_cachedScreenSurface) { CFRelease(_cachedScreenSurface); _cachedScreenSurface = NULL; }
        if (s) {
            _cachedScreenSurface = (IOSurfaceRef)CFRetain(s);
            _cachedSurfaceTime = [NSProcessInfo processInfo].systemUptime;
        } else {
            _cachedSurfaceTime = 0;
        }
    }
}

// 异步请求主线程刷新缓存 surface(节流: 距上次创建 ≥ 400ms 才派发), 不阻塞调用线程。
// 高频 findColor 只触发几次/秒的轻量主线程任务, UI 不再被截屏拖死。
- (void)_requestScreenSurfaceRefresh {
    BOOL needDispatch = NO;
    @synchronized (self) {
        if (_surfaceRefreshPending) { return; }
        if (_cachedSurfaceTime > 0 &&
            ([NSProcessInfo processInfo].systemUptime - _cachedSurfaceTime) < 0.4) {
            return;
        }
        _surfaceRefreshPending = YES;
        needDispatch = YES;
    }
    if (!needDispatch) { return; }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }
        IOSurfaceRef s = [self _createUIScreenSurface];
        [self _setCachedScreenSurface:s];
        @synchronized (self) { self->_surfaceRefreshPending = NO; }
    });
}

- (BOOL)_captureUIScreenIOSurfaceToRGBA:(uint8_t **)pixelsOut
                                  width:(int *)widthOut
                                 height:(int *)heightOut {
    if (!_iosurfaceHandle) {
        TSSetLastError(@"路径0 UIScreenSurface: IOSurface 框架加载失败");
        return NO;
    }

    // 对齐 AutoTouch 原版: 每次截屏都新建 surface(createScreenIOSurface 必须主线程),
    // 创建后立即读取并释放, 不缓存复用 —— 缓存 surface 的内容可能停留在创建时刻,
    // 切到其他 App 后读到的仍是旧帧(非实时), 且新帧只在每次新建时更新。
    IOSurfaceRef surf = NULL;
    if ([NSThread isMainThread]) {
        surf = [self _createUIScreenSurface];
    } else {
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        __block IOSurfaceRef created = NULL;
        dispatch_async(dispatch_get_main_queue(), ^{
            created = [self _createUIScreenSurface];
            dispatch_semaphore_signal(sema);
        });
        dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC));
        surf = created;
    }
    if (!surf) {
        TSSetLastError(@"路径0 UIScreenSurface: 全部候选均未返回 IOSurface(需 iOS12+ 且 TrollStore 全权限环境)");
        return NO;
    }

    // 读取像素(后台线程, 走 _UICreateCGImageFromIOSurface / 加速器转储 / 手动 lock 三级读取)
    uint8_t *px = NULL; int w = 0, h = 0;
    BOOL ok = [self _dumpIOSurface:surf pixelsOut:&px width:&w height:&h] && px;
    CFRelease(surf);
    if (!ok) {
        TSSetLastError(@"路径0 UIScreenSurface: surface 读取失败");
        return NO;
    }
    if ([self _isAllZeroPixels:px width:w height:h]) {
        TSSetLastError(@"路径0 UIScreenSurface: 截到空内容(全 0)");
        free(px);
        return NO;
    }
    self.lastError = nil;
    *pixelsOut = px; *widthOut = w; *heightOut = h;
    return YES;
}

#pragma mark - 跨应用截屏: 全局显示截取(参考"无忧辅助" IORegistry 方案)

// 核心思路: 去 IORegistry 里找 IOMobileFramebuffer / AppleDCP 等系统显示服务的
// DisplaySurface / CurrentSurface 属性, 拿到 surface ID 后用 IOSurfaceLookup 直接映射
// WindowServer 维护的**全局显示缓冲**。不创建 IOSurface、不依赖 CARenderServer、
// 不依赖前台, 是真正跨 App 找色的路径, 只需 com.apple.private.screen-capture 权限。
static const char *_gsServiceNames[] = {
    "IOMobileFramebuffer",
    "AppleDCP",
    "AppleDCPExpert",
    "AppleCLCD",
    "AppleMipiDSI",
    "AppleH10CLCD", "AppleH11CLCD", "AppleH12CLCD", "AppleH13CLCD",
    "AppleM2ScalerCSC",
    NULL
};

// 候选属性名(各机型/版本存放全局 surface 的键不同)
static const char *_gsSurfaceKeys[] = {
    "DisplaySurface", "CurrentSurface", "FramebufferSurface", "MainSurface",
    "IOSurface", "Surface", "surface",
    "IOSurfaceID", "SurfaceID", "surface-id", "display-surface-id",
    "DisplaySurfaceID", "FBSystemSurfaceID", "ioSurfaceID", "CoreSurfaceID",
    NULL
};

- (BOOL)_captureGlobalDisplayToRGBA:(uint8_t **)pixelsOut
                              width:(int *)widthOut
                             height:(int *)heightOut {
    if (!_iosurfaceHandle) {
        TSSetLastError(@"路径0 全局显示: IOSurface 框架加载失败");
        return NO;
    }
    IOSurfaceGetTypeIDFunc typeIdFn = (IOSurfaceGetTypeIDFunc)dlsym(_iosurfaceHandle, "IOSurfaceGetTypeID");
    IOSurfaceLookupFunc lookupFn = (IOSurfaceLookupFunc)dlsym(_iosurfaceHandle, "IOSurfaceLookup");
    if (!typeIdFn || !lookupFn) {
        TSSetLastError(@"路径0 全局显示: IOSurfaceGetTypeID/IOSurfaceLookup 符号不可用");
        return NO;
    }

    for (int i = 0; _gsServiceNames[i]; i++) {
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                           IOServiceMatching(_gsServiceNames[i]));
        if (service == MACH_PORT_NULL) { continue; }

        CFMutableDictionaryRef props = NULL;
        kern_return_t kr = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0);
        IOObjectRelease(service);
        if (kr != KERN_SUCCESS || !props) { continue; }

        NSString *foundVia = nil;
        IOSurfaceRef found = NULL;
        NSDictionary *dict = (__bridge NSDictionary *)props;
        NSLog(@"[TSScreenCapture] 全局显示: 服务 %s 属性数=%lu", _gsServiceNames[i], (unsigned long)dict.count);
        for (int k = 0; _gsSurfaceKeys[k]; k++) {
            id value = dict[@(_gsSurfaceKeys[k])];
            if (!value) { continue; }
            // 值本身直接是 IOSurface 对象
            if (CFGetTypeID((__bridge CFTypeRef)value) == typeIdFn()) {
                found = (__bridge IOSurfaceRef)value;
                CFRetain(found);
                foundVia = [NSString stringWithFormat:@"%s->%s(对象)", _gsServiceNames[i], _gsSurfaceKeys[k]];
                break;
            }
            // 值是 surface ID 数字: IOSurfaceLookup 映射
            if ([value isKindOfClass:[NSNumber class]]) {
                uint32_t sid = [value unsignedIntValue];
                if (sid > 0) {
                    IOSurfaceRef s = lookupFn(sid);
                    if (s) {
                        found = s;
                        foundVia = [NSString stringWithFormat:@"%s->%s ID=%u", _gsServiceNames[i], _gsSurfaceKeys[k], sid];
                        break;
                    }
                }
            }
        }
        CFRelease(props);

        if (!found) { continue; }

        uint8_t *px = NULL; int w = 0, h = 0;
        if ([self _dumpIOSurface:found pixelsOut:&px width:&w height:&h] && px) {
            if (![self _isAllZeroPixels:px width:w height:h]) {
                NSLog(@"[TSScreenCapture] 全局显示截屏成功 %dx%d (%@)", w, h, foundVia);
                CFRelease(found);
                self.lastError = nil;
                *pixelsOut = px; *widthOut = w; *heightOut = h;
                return YES;
            }
            NSLog(@"[TSScreenCapture] 全局显示 %@ 取到空内容", foundVia);
            free(px);
        } else {
            NSLog(@"[TSScreenCapture] 全局显示 %@ dump 失败", foundVia);
        }
        CFRelease(found);
    }
    TSSetLastError(@"路径0 全局显示: 服务列表未找到可读的 DisplaySurface");
    return NO;
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
        TSSetLastError(@"路径2 CARenderServer: IOSurface 框架加载失败");
        return NO;
    }
    static CARenderServerRenderDisplayFunc renderFn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 对齐 TrollShot: CARenderServerRenderDisplay(0, "LCD", surface, 0, 0)
        renderFn = (CARenderServerRenderDisplayFunc)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    });
    if (!renderFn) {
        TSSetLastError(@"路径2 CARenderServer: CARenderServerRenderDisplay 符号不可用(该 iOS 无此私有 API)");
        NSLog(@"[TSScreenCapture] CARenderServerRenderDisplay 不可用(私有符号缺失)");
        return NO;
    }

    CGSize sz = [self _screenPixelSize];
    int w = (int)sz.width, h = (int)sz.height;
    if (w <= 0 || h <= 0) {
        TSSetLastError(@"路径2 CARenderServer: 屏幕尺寸无效 %dx%d", w, h);
        return NO;
    }
    NSLog(@"[TSScreenCapture] 尝试 CARenderServerRenderDisplay 截屏 %dx%d", w, h);

    IOSurfaceRef src = [self _createIOSurfaceWithWidth:w height:h];
    if (!src) {
        TSSetLastError(@"路径2 CARenderServer: 创建 IOSurface 失败 %dx%d", w, h);
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
            TSSetLastError(@"路径2 CARenderServer: display=%s 渲染结果全空(可能被 WindowServer 拒绝)", displayNames[attempt]);
            NSLog(@"[TSScreenCapture] CARenderServer display=%s 取到空内容", displayNames[attempt]);
            free(px);
        } else {
            TSSetLastError(@"路径2 CARenderServer: display=%s 读 surface 失败", displayNames[attempt]);
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
        TSSetLastError(@"路径1 系统窗口: windowWithContextId: 系列均不可用(contextId=%u)", contextId);
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
        TSSetLastError(@"路径4 应用内: App 在后台, 应用内截屏会全黑已跳过");
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

/// 后台截屏专用路径: 按原版 HUDServices 逆向链路优先 createScreenIOSurface,
/// 再回退 CARenderServer / 全局显示 / UIScreen surface 缓存。
- (BOOL)_captureBackgroundToRGBA:(uint8_t **)pixelsOut
                           width:(int *)widthOut
                          height:(int *)heightOut {
    // 0. UIScreen createScreenIOSurface(原版核心链路, 系统级全屏 surface, 与 App 前后台无关)
    //    对齐 AutoTouch: 不隐藏本 App 窗口(原版无此步骤), 每次截屏都重新创建 surface,
    //    读取走 _UICreateCGImageFromIOSurface 路径, 拿到的是系统当前帧(实时画面)。
    BOOL ok0 = [self _captureUIScreenIOSurfaceToRGBA:pixelsOut width:widthOut height:heightOut];
    if (ok0) {
        return YES;
    }
    NSString *err0 = [self.lastError copy];
    // 1. CARenderServerRenderDisplay: TrollShot/TrollVNC 在后台/锁屏验证过的跨 App 截屏方案,
    //    走 WindowServer 渲染管线, 与 App 自身前后台无关。
    if ([self _captureRenderServerToRGBA:pixelsOut width:widthOut height:heightOut]) {
        return YES;
    }
    NSString *errRS = [self.lastError copy];
    // 2. IORegistry DisplaySurface + IOSurfaceLookup(全局显示缓冲, 不依赖前台)
    if ([self _captureGlobalDisplayToRGBA:pixelsOut width:widthOut height:heightOut]) {
        return YES;
    }
    NSString *errGD = [self.lastError copy];
    // 3. 兜底: 读 UIScreen surface 缓存(可能含前台最后一帧, 不重新创建、不阻塞主线程)
    IOSurfaceRef cached = [self _getCachedScreenSurface];
    if (cached) {
        uint8_t *px = NULL; int w = 0, h = 0;
        BOOL ok = [self _dumpIOSurface:cached pixelsOut:&px width:&w height:&h] && px
                  && ![self _isAllZeroPixels:px width:w height:h];
        CFRelease(cached);
        if (ok) {
            self.lastError = nil;
            *pixelsOut = px; *widthOut = w; *heightOut = h;
            return YES;
        }
        if (px) { free(px); }
        [self _setCachedScreenSurface:NULL];
    }
    self.lastError = [NSString stringWithFormat:@"后台截屏: createScreenIOSurface: %@; CARenderServer: %@; 全局显示: %@; UIScreen 缓存: 空/全0",
                      err0 ?: @"未尝试", errRS ?: @"未尝试", errGD ?: @"未尝试"];
    return NO;
}

#pragma mark - 截图链路诊断

- (NSDictionary *)diagnostics {
    NSMutableDictionary *diag = [NSMutableDictionary dictionary];
    @try {
        UIApplicationState st = [UIApplication sharedApplication].applicationState;
        diag[@"appState"] = (st == UIApplicationStateActive) ? @"Active(前台)"
                           : (st == UIApplicationStateInactive) ? @"Inactive" : @"Background(后台)";
        diag[@"iosurfaceLoaded"] = @(_iosurfaceHandle != NULL);
        diag[@"screenPixelSize"] = NSStringFromCGSize([self _screenPixelSize]);

        // createScreenIOSurface 候选 target 可用性
        SEL sel = NSSelectorFromString(@"createScreenIOSurface");
        NSMutableArray *cands = [NSMutableArray array];
        NSArray *targets = @[ [UIScreen mainScreen], [UIWindow class], [UIScreen class] ];
        for (id t in targets) {
            NSString *name = [t isKindOfClass:[UIScreen class]] ? @"[UIScreen mainScreen]" : NSStringFromClass(t);
            [cands addObject:@{@"target": name, @"respondsToSelector": @([t respondsToSelector:sel])}];
        }
        diag[@"createScreenIOSurfaceCandidates"] = cands;

        // 实际尝试创建一次 surface 并 dump
        IOSurfaceRef s = [self _createUIScreenSurface];
        if (s) {
            size_t (*getW)(IOSurfaceRef) = (size_t (*)(IOSurfaceRef))dlsym(_iosurfaceHandle, "IOSurfaceGetWidth");
            size_t (*getH)(IOSurfaceRef) = (size_t (*)(IOSurfaceRef))dlsym(_iosurfaceHandle, "IOSurfaceGetHeight");
            int sw = (int)(getW ? getW(s) : 0);
            int sh = (int)(getH ? getH(s) : 0);
            uint8_t *px = NULL; int dw = 0, dh = 0;
            BOOL dumpOk = (sw > 0 && sh > 0) && [self _dumpIOSurface:s pixelsOut:&px width:&dw height:&dh];
            BOOL allZero = dumpOk && px && [self _isAllZeroPixels:px width:dw height:dh];
            NSMutableDictionary *res = [@{
                @"ok": @YES,
                @"width": @(sw),
                @"height": @(sh),
                @"dumpOk": @(dumpOk),
                @"dumpWidth": @(dw),
                @"dumpHeight": @(dh),
                @"allZero": @(allZero)
            } mutableCopy];
            uint32_t (*pfFn)(IOSurfaceRef) = (uint32_t (*)(IOSurfaceRef))dlsym(_iosurfaceHandle, "IOSurfaceGetPixelFormat");
            if (pfFn) {
                res[@"pixelFormat"] = [NSString stringWithFormat:@"0x%08X", (unsigned int)pfFn(s)];
            }
            if (px) { free(px); }
            CFRelease(s);
            diag[@"createScreenIOSurfaceResult"] = res;
        } else {
            diag[@"createScreenIOSurfaceResult"] = @{@"ok": @NO, @"error": self.lastError ?: @"(无)"};
        }

        // 隐藏窗口模式测试: 模拟 HUDServices 无窗口进程, 看 surface 是否变为系统主屏
        @synchronized (self) { _hideWindowsWhenCapturing = YES; }
        IOSurfaceRef hs = [self _createUIScreenSurface];
        @synchronized (self) { _hideWindowsWhenCapturing = NO; }
        if (hs) {
            size_t (*gW)(IOSurfaceRef) = (size_t (*)(IOSurfaceRef))dlsym(_iosurfaceHandle, "IOSurfaceGetWidth");
            size_t (*gH)(IOSurfaceRef) = (size_t (*)(IOSurfaceRef))dlsym(_iosurfaceHandle, "IOSurfaceGetHeight");
            uint8_t *hpx = NULL; int hw = 0, hh = 0;
            BOOL hdump = (gW && gH && gW(hs) > 0) && [self _dumpIOSurface:hs pixelsOut:&hpx width:&hw height:&hh];
            BOOL hzero = hdump && hpx && [self _isAllZeroPixels:hpx width:hw height:hh];
            diag[@"hiddenWindowsSurfaceResult"] = @{
                @"ok": @YES,
                @"width": @(gW ? (int)gW(hs) : 0),
                @"height": @(gH ? (int)gH(hs) : 0),
                @"dumpOk": @(hdump),
                @"allZero": @(hzero)
            };
            if (hpx) { free(hpx); }
            CFRelease(hs);
        } else {
            diag[@"hiddenWindowsSurfaceResult"] = @{@"ok": @NO};
        }

        diag[@"CARenderServerRenderDisplaySymbol"] = @(dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay") != NULL);
        diag[@"IOMobileFramebufferSymbol"] = @(dlsym(RTLD_DEFAULT, "IOMobileFramebufferGetMainDisplay") != NULL);
        // 测试完整 captureImage 链路，并返回缩略图 base64，便于判断截到的是否为实时全屏
        UIImage *testImg = [self captureImage];
        diag[@"captureImageOk"] = @(testImg != nil);
        CGSize imgSize = testImg ? testImg.size : CGSizeZero;
        diag[@"captureImageSize"] = testImg ? NSStringFromCGSize(imgSize) : @"(失败)";
        if (testImg && imgSize.width > 0 && imgSize.height > 0) {
            CGFloat scale = MIN(200.0 / imgSize.width, 200.0 / imgSize.height);
            CGSize thumbSize = CGSizeMake(imgSize.width * scale, imgSize.height * scale);
            UIGraphicsBeginImageContextWithOptions(thumbSize, NO, 1.0);
            [testImg drawInRect:CGRectMake(0, 0, thumbSize.width, thumbSize.height)];
            UIImage *thumb = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            NSData *thumbPNG = UIImagePNGRepresentation(thumb);
            if (thumbPNG.length > 0) {
                diag[@"captureImageThumbBase64"] = [thumbPNG base64EncodedStringWithOptions:0];
            }
        }
        diag[@"lastError"] = self.lastError ?: @"(无)";
    } @catch (NSException *e) {
        diag[@"exception"] = [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
    }
    return diag;
}

- (BOOL)captureScreenToRGBA:(uint8_t **)pixelsOut
                     width:(int *)widthOut
                    height:(int *)heightOut {
    // 后台状态: 切换到后台专用路径(优先 CARenderServer 等验证过的后台方案)。
    // 前台路径完全不变, 保持现有截图功能与接口一致。
    UIApplicationState bgState = [UIApplication sharedApplication].applicationState;
    if (bgState == UIApplicationStateBackground) {
        return [self _captureBackgroundToRGBA:pixelsOut width:widthOut height:heightOut];
    }
    // 0. UIScreen createScreenIOSurface(原版核心链路, 系统级全屏 surface, 后台/跨 App 可用)
    if ([self _captureUIScreenIOSurfaceToRGBA:pixelsOut width:widthOut height:heightOut]) {
        return YES;
    }
    NSString *err0 = [self.lastError copy];
    // 1. 全局显示截取(IORegistry DisplaySurface + IOSurfaceLookup, 拿现成 surface, 跨 App)
    if ([self _captureGlobalDisplayToRGBA:pixelsOut width:widthOut height:heightOut]) {
        return YES;
    }
    NSString *err1 = [self.lastError copy];
    // 2. 系统窗口截屏(windowWithContextId:+createScreenIOSurface, 不依赖 IOSurfaceCreate)
    if ([self _captureSystemWindowToRGBA:pixelsOut width:widthOut height:heightOut]) {
        return YES;
    }
    NSString *err2 = [self.lastError copy];
    // 3. CARenderServerRenderDisplay: 主屏渲染到 IOSurface(TrollShot 方案, 保留回退)
    if ([self _captureRenderServerToRGBA:pixelsOut width:widthOut height:heightOut]) {
        return YES;
    }
    NSString *err3 = [self.lastError copy];
    // 4. IOMFB 帧缓冲(前台场景回退)
    if ([self _captureFramebufferToRGBA:pixelsOut width:widthOut height:heightOut]) {
        return YES;
    }
    NSString *err4 = [self.lastError copy];
    // 5. 应用内截屏(兜底)
    UIApplicationState appState = [UIApplication sharedApplication].applicationState;
    NSLog(@"[TSScreenCapture] 跨应用截屏失败(appState=%ld: 0前台/1后台/2挂起)，回退应用内截屏",
          (long)appState);
    BOOL ok = [self _captureAppWindowToRGBA:pixelsOut width:widthOut height:heightOut];
    if (ok) { return YES; }
    // 汇总全部路径失败原因, 供 Lua 层展示(NSLog 普通用户看不到)
    self.lastError = [NSString stringWithFormat:@"UIScreenSurface: %@; 全局显示: %@; 系统窗口: %@; CARenderServer: %@; IOMFB: %@; 应用内: %@",
                      err0 ?: @"未尝试", err1 ?: @"未尝试", err2 ?: @"未尝试", err3 ?: @"未尝试",
                      err4 ?: @"未尝试", self.lastError ?: @"未尝试"];
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
    if (_cachedScreenSurface) { CFRelease(_cachedScreenSurface); _cachedScreenSurface = NULL; }
}

@end
