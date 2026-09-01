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
#import "TSColorFinder.h"
#import <dlfcn.h>
#import <mach/mach.h>
#import <unistd.h>
#import <IOKit/IOKitLib.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>

// MARK: - Display P3 广色域 → sRGB 转换
// iPhone 7 及之后的屏幕为 Display P3 广色域，IOSurface 像素是 P3 值。
// 若直接按 sRGB 解释/显示会整体偏淡、发灰，导致找色、取色颜色与手机屏幕不一致。
// 此转换把所有像素统一到标准 sRGB，保证截图、取色、Lua 脚本比对颜色完全一致。
// sRGB 屏（如 iPhone 6s）检测为 NO，行为与原版完全一致，无任何性能损失。
static float _srgbToLinearLUT[256];
static float _p3ToLinearLUT10[1024]; // 10-bit Display P3(30RGBLE, 'w30r') 线性化
static uint8_t _linearToSrgbLUT[4096];

static void _initColorLUTs(void) {
    for (int i = 0; i < 256; i++) {
        double v = i / 255.0;
        _srgbToLinearLUT[i] = (float)(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4));
    }
    for (int i = 0; i < 1024; i++) {
        // Display P3 传递函数 = sRGB OETF, 10-bit 域 [0,1023]
        double v = i / 1023.0;
        _p3ToLinearLUT10[i] = (float)(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4));
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
// 直接链接绑定(对齐原版 AutoTouch): iOS 16 的 dyld(chained fixups)运行时 bind 用
// dyld shared cache 符号表(含 local symbol)解析, 而 dlsym 只查 exported symbols,
// 所以 _UICreateCGImageFromIOSurface 用 dlsym(UIKitCore/UIKit/RTLD_DEFAULT) 全失败。
// project.yml 已设 -Wl,-undefined,dynamic_lookup, weak 声明保证符号缺失时置 NULL 不崩溃。
CGImageRef _UICreateCGImageFromIOSurface(IOSurfaceRef surface) __attribute__((weak));

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

    // CARenderServer 复用 surface(iOS16 前台主路径):
    // 原实现每次截屏都新建 12MB GPU IOSurface, iOS 16 高频截屏下 GPU/IO 内存暴涨
    // 被 jetsam 杀(SE3 iOS16.6 实测 7 秒爆内存; 6S iOS15 走 UIScreenSurface 系统
    // surface 无此问题, 24h 稳定)。复用同一 surface(尺寸不变, renderFn 每次重绘
    // 当前帧, 内容仍实时), 与 TrollShot daemon 常驻做法一致。
    IOSurfaceRef _renderServerSurface;
    int _renderServerSurfaceW;
    int _renderServerSurfaceH;
    // 复用转储目标 surface / IOSurfaceAccelerator(首建后常驻): 避免 iOS16 高频截屏
    // 每次新建全屏 GPU surface, 系统侧不立即回收导致挂机十几小时后内存累积被杀。
    IOSurfaceRef _dumpDstSurface;
    int _dumpDstSurfaceW;
    int _dumpDstSurfaceH;
    void *_dumpAccel;
    // 截屏路径诊断计数(供 AppDelegate 周期写入 touch.log, 定位内存累积来源)
    unsigned long long _statRenderServerOK, _statRenderServerFail;
    unsigned long long _statRenderServerDirectOK, _statRenderServerDirectFail;
    unsigned long long _statCreateUIScreenOK, _statCreateUIScreenFail;
    unsigned long long _statGlobalOK, _statGlobalFail;
    unsigned long long _statCacheOK, _statCacheFail;

    // ── 内存泄漏诊断计数(2026-09-01, iOS16.6 SE3 挂机 71MB/h 累积定位) ──
    // 拆分 createScreenIOSurface "真实创建" 与后台 "1 秒缓存命中"：
    // 原 _statCreateUIScreenOK 把两者混计, 99.6 次/秒 中无法区分真实创建频率。
    unsigned long long _statUIScreenCreateCalls;   // createScreenIOSurface 返回非空次数
    unsigned long long _statUIScreenReleased;      // 已 CFRelease 的 surface 次数
    unsigned long long _statUIScreenCacheHit;      // 后台 1 秒缓存命中(未新建 surface)
    unsigned long long _statUIScreenRealCreateOK;  // 真实创建并成功读取
    unsigned long long _statUIScreenAllocBytes;    // 累计 surface alloc size(字节, 诊断量级)
    unsigned long long _statUIScreenAllocSizeLast; // 最近一次 surface alloc size
    unsigned long long _statKeepCalls;             // keepPixels 调用次数
    unsigned long long _statKeepThrottled;         // keep 60ms 限频跳过次数
    unsigned long long _statKeepRealCapture;       // keep 实际触发截屏次数
    unsigned long long _statCaptureCalls;          // captureScreenToRGBA 总调用次数
    unsigned long long _statDumpMallocBytes;       // _dumpIOSurface 累计 malloc 缓冲字节
    unsigned long long _statDumpMallocCount;       // _dumpIOSurface malloc 调用次数
}
@end

// Lua 层 grabScreen 调用统计(static 计数器, 供类方法 +statsLine 读取)
// 注意: 必须放在 @interface 之外(文件作用域), ObjC 不允许在类扩展内声明 static 变量。
static unsigned long long s_statGrabScreenCalls = 0;   // grabScreen 总调用次数
static unsigned long long s_statGrabThrottled = 0;     // grabScreen 60ms 限频跳过次数

@implementation TSScreenCapture

// 记录失败原因到 lastError(Lua 层可见), 截屏成功路径需手动置 nil
#define TSSetLastError(...) do { \
    self.lastError = [NSString stringWithFormat:__VA_ARGS__]; \
} while (0)

// NSLog 节流: 高频截屏(约每 100ms 一次)下每次 NSLog 都会产生 os_log 缓冲与 IO,
// iOS 16 长时间挂机会额外累积内存压力, 同一来源日志每 2 秒最多打一次。
static void _logThrottled(NSString *fmt, ...) {
    static NSTimeInterval s_lastLog = 0;
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if (now - s_lastLog < 2.0) { return; }
    s_lastLog = now;
    va_list args;
    va_start(args, fmt);
    NSLogv(fmt, args);
    va_end(args);
}

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
        // _UICreateCGImageFromIOSurface 直接链接绑定(对齐原版):
        // dlsym(RTLD_DEFAULT/UIKitCore/UIKit) 在 iOS 16 全失败 —— dyld bind 用
        // cache 符号表(含 local symbol)解析, dlsym 只查 exported symbols。
        // extern weak + project.yml 的 -Wl,-undefined,dynamic_lookup:
        // 运行时由 dyld 在已加载 image 中解析, 缺失自动置 NULL。
        _uiCreateCGImageFn = _UICreateCGImageFromIOSurface;
        _uiCreateCGImageSource = _uiCreateCGImageFn ? @"direct-link(weak)" : @"(未加载)";
        if (!_uiCreateCGImageFn) {
            NSLog(@"[TSScreenCapture] 警告: _UICreateCGImageFromIOSurface 链接解析失败(dynamic_lookup 未找到)");
        }
    }
    return self;
}

#pragma mark - IOSurface 转储(对齐原版: 硬件/窗口 surface -> 加速器 -> 自建 BGRA surface)

/// 读取 IOSurface 声明的色彩空间(IOSurfaceColorSpace 属性, 系统标记内容真实色彩空间)。
/// 返回字符串(如 "sRGB"/"DisplayP3"), 属性缺失/不可解析时返回 nil。
- (NSString *)_surfaceColorSpaceName:(IOSurfaceRef)surf {
    if (!surf || !_iosurfaceHandle) { return nil; }
    CFTypeRef (*copyValueFn)(IOSurfaceRef, CFStringRef) =
        dlsym(_iosurfaceHandle, "IOSurfaceCopyValue");
    if (!copyValueFn) { return nil; }
    CFTypeRef v = copyValueFn(surf, CFSTR("IOSurfaceColorSpace"));
    if (v) {
        if (CFGetTypeID(v) == CFStringGetTypeID()) {
            NSString *s = [NSString stringWithString:(__bridge NSString *)v];
            CFRelease(v);
            return s;
        }
        CFRelease(v);
    }
    return nil;
}

/// 用 IOSurfaceAccelerator 把 source surface 转储到自建 BGRA surface 并读出 RGBA 像素。
/// 传输在 WindowServer 侧(GPU)执行，不依赖 App 自身渲染状态，后台/其他 App 前台仍可用。
- (BOOL)_dumpIOSurface:(IOSurfaceRef)sourceSurface
      skipColorConvert:(BOOL)skipColorConvert
      directReadIfBgra:(BOOL)directReadIfBgra
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
    self.lastSourceFormat = [NSString stringWithFormat:@"0x%08X", (unsigned int)srcFmt];
    self.lastAccelOK = NO;
    self.lastAccelError = 0;
    _logThrottled(@"[TSScreenCapture] _dumpIOSurface source=%zux%zu fmt=0x%08X", srcW, srcH, (unsigned int)srcFmt);
    if (srcW == 0 || srcH == 0) { return NO; }

    // 直接 IOSurfaceLock 读硬件输出 surface 在 iOS 15+/后台/部分机型不可靠(空内容),
    // 经 GPU 加速器转储到自建 surface 后能拿到稳定全屏像素(原版 HUD 的做法)。
    IOSurfaceRef readSurface = sourceSurface;
    IOSurfaceRef dstSurface = NULL;
    void *accel = NULL;
    // 源已是 BGRA 且允许直读(仅 RenderServer 自建 surface): 直接 IOSurfaceLock 读,
    // 不再经加速器转储创建 dstSurface。iOS 16 上每次截屏创建-释放全屏 GPU surface
    // (约 12MB)系统侧不立即回收, 长时间挂机持续累积触发 Jetsam(SE3 iOS16.6 实测
    // 约 18h 被杀; iOS 15 系统回收正常故无此问题)。自建 surface 由 renderFn 渲染,
    // lock 直读稳定, 且两 surface 同为 BGRA 无色彩转换差异。
    BOOL directBgra = (srcFmt == 0x42475241 /*BGRA*/ && directReadIfBgra);
    if (!directBgra && accelCreateFn && accelTransferFn && createFn) {
        // 复用 IOSurfaceAccelerator(首建后常驻)与转储目标 surface(尺寸不变时复用):
        // 除首次外不再创建任何 GPU surface, 从源头消除 iOS16 高频截屏下
        // "创建-释放全屏 GPU surface"导致的系统侧内存持续累积。
        @synchronized (self) {
            if (_dumpAccel) {
                accel = _dumpAccel;
            } else if (accelCreateFn(kCFAllocatorDefault, 0, &_dumpAccel) == KERN_SUCCESS && _dumpAccel) {
                accel = _dumpAccel;
            }
        }
        if (accel) {
            // 尺寸匹配 → 复用上次转储目标 surface; 否则新建并缓存
            if (_dumpDstSurface && _dumpDstSurfaceW == (int)srcW && _dumpDstSurfaceH == (int)srcH) {
                dstSurface = (IOSurfaceRef)CFRetain(_dumpDstSurface);
            } else {
                dstSurface = [self _createIOSurfaceWithWidth:(int)srcW height:(int)srcH];
                if (dstSurface) {
                    @synchronized (self) {
                        if (_dumpDstSurface) { CFRelease(_dumpDstSurface); _dumpDstSurface = NULL; }
                        _dumpDstSurface = (IOSurfaceRef)CFRetain(dstSurface);
                        _dumpDstSurfaceW = (int)srcW;
                        _dumpDstSurfaceH = (int)srcH;
                    }
                }
            }
            // 转储; 复用后的 transfer 在部分 iOS 版本上不可靠, 失败时丢弃缓存的
            // accel+dstSurface 按首建流程重建一次, 仍失败才回退直接读。
            for (int retry = 0; dstSurface && retry < 2; retry++) {
                kern_return_t tr = accelTransferFn(accel, sourceSurface, dstSurface, NULL, NULL, NULL, NULL);
                if (tr == KERN_SUCCESS) {
                    readSurface = dstSurface;
                    self.lastAccelOK = YES;
                    _logThrottled(@"[TSScreenCapture] 加速器转储成功 src=0x%08X -> dst=BGRA", (unsigned int)srcFmt);
                    break;
                }
                self.lastAccelError = (int)tr;
                NSLog(@"[TSScreenCapture] IOSurfaceAcceleratorTransferSurface 失败 kr=%d (0x%x), 重建重试", (int)tr, (unsigned int)tr);
                if (dstSurface) { CFRelease(dstSurface); dstSurface = NULL; }
                @synchronized (self) {
                    if (_dumpAccel) { CFRelease(_dumpAccel); _dumpAccel = NULL; }
                    if (_dumpDstSurface) { CFRelease(_dumpDstSurface); _dumpDstSurface = NULL; }
                    _dumpDstSurfaceW = 0; _dumpDstSurfaceH = 0;
                }
                if (retry == 0 && accelCreateFn(kCFAllocatorDefault, 0, &_dumpAccel) == KERN_SUCCESS && _dumpAccel) {
                    accel = _dumpAccel;
                    dstSurface = [self _createIOSurfaceWithWidth:(int)srcW height:(int)srcH];
                    if (dstSurface) {
                        @synchronized (self) {
                            _dumpDstSurface = (IOSurfaceRef)CFRetain(dstSurface);
                            _dumpDstSurfaceW = (int)srcW;
                            _dumpDstSurfaceH = (int)srcH;
                        }
                    }
                }
            }
        }
    }

    // ---- 系统色彩管理路径: _UICreateCGImageFromIOSurface(原版 AutoTouch 读取端) ----
    // ★已禁用(2026-08-28): iOS 16.6 + P3 屏(w30r)高频截屏下, 本路径的 CIImage 兜底
    // (kCIContextUseSoftwareRenderer=NO, GPU 渲染) 每次截屏都在 GPU 分配缓冲, GPU/IO 内存
    // 暴涨被 jetsam 杀 —— SE3 iOS 16.6 实测 9 秒 4 次内存警告后闪退; 6S iOS15 源为
    // 8-bit BGRA 不经本路径, 24h 稳定, 两平台唯一路径差异即此处。
    // 且实测 iOS 16.6 上 _UICreateCGImageFromIOSurface 返回 NULL 不出图, 本路径本就无效。
    // 现统一走下方手动读取(w30r 10-bit 白点归一化 + 编码域对比度拉伸, dcc15cf 实测颜色正确),
    // 完全跳过 CGImage/CIImage 大分配, 不再有 GPU 内存累积。若需恢复仅改回 YES。
    if (NO && self.lastAccelOK == NO && srcFmt != 0x42475241 /* 'BGRA' */) {
        __block CGImageRef cg = NULL;
        if (_uiCreateCGImageFn) {
            if ([NSThread isMainThread]) {
                cg = _uiCreateCGImageFn(readSurface);
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    cg = _uiCreateCGImageFn(readSurface);
                });
            }
        } else {
            self.lastSystemPath = [NSString stringWithFormat:@"符号未加载(src=%@)", self.uiCreateCGImageSource ?: @"(nil)"];
        }
        if (!cg) {
            // 兜底: CIImage imageWithIOSurface(公开 API, CIContext 线程安全) + sRGB 渲染
            CIImage *ci = [CIImage imageWithIOSurface:readSurface options:nil];
            if (ci) {
                static CIContext *s_ciCtx = nil;
                static dispatch_once_t onceToken;
                dispatch_once(&onceToken, ^{
                    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                    s_ciCtx = [CIContext contextWithOptions:@{
                        (id)kCIContextWorkingColorSpace: (__bridge id)srgb,
                        (id)kCIContextOutputColorSpace: (__bridge id)srgb,
                        (id)kCIContextUseSoftwareRenderer: @NO,
                    }];
                    CGColorSpaceRelease(srgb);
                });
                CGRect ext = ci.extent;
                cg = [s_ciCtx createCGImage:ci fromRect:ext];
                self.lastSystemPath = cg ? @"CIImage(imageWithIOSurface)->sRGB fallback" : @"CIImage 渲染也失败";
            } else {
                self.lastSystemPath = @"_UICreateCGImageFromIOSurface 与 CIImage(imageWithIOSurface) 均失败";
            }
            NSLog(@"[TSScreenCapture] _UICreateCGImageFromIOSurface 返回 NULL, CIImage fallback: %@", self.lastSystemPath);
        } else {
            size_t cw = CGImageGetWidth(cg), ch = CGImageGetHeight(cg);
            // 诊断: 记录 CoreGraphics 解析出的 CGImage 色彩空间(判断是否需手动补 P3)
            NSString *imgCSDesc = @"null";
            CGColorSpaceRef imgCS = CGImageGetColorSpace(cg);
            if (imgCS) {
                CFStringRef nm = CGColorSpaceCopyName(imgCS);
                if (nm) {
                    imgCSDesc = [NSString stringWithFormat:@"%@", nm];
                    CFRelease(nm);
                } else {
                    imgCSDesc = @"(unnamed)";
                }
            }
            if (cw > 0 && ch > 0) {
                uint8_t *cgOut = malloc(cw * ch * 4);
                if (cgOut) {
                    // 用 sRGB context(原版 UIGraphicsBeginImageContextWithOptions 即 sRGB):
                    // P3 屏上 kCGColorSpaceDeviceRGB 映射设备 P3 profile, P3 CGImage 绘制进去
                    // 恒等不转换, 输出仍是 P3 编码值 -> 脚本按 sRGB 找色发灰;
                    // sRGB context 让 CoreGraphics 把 DisplayP3 CGImage 自动转换到 sRGB。
                    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                    if (!cs) { cs = CGColorSpaceCreateDeviceRGB(); }
                    CGContextRef ctx = CGBitmapContextCreate(cgOut, cw, ch, 8, cw * 4, cs,
                        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
                    if (ctx) {
                        CGContextDrawImage(ctx, CGRectMake(0, 0, cw, ch), cg);
                        CGContextRelease(ctx);
                        CGColorSpaceRelease(cs);
                        CGImageRelease(cg);
                        if (dstSurface) { CFRelease(dstSurface); }
                        *pixelsOut = cgOut;
                        *widthOut = (int)cw;
                        *heightOut = (int)ch;
                        self.lastColorDecision = [NSString stringWithFormat:@"system(_UICreateCGImageFromIOSurface->sRGB, imgCS=%@)", imgCSDesc];
                        self.lastSystemPath = [NSString stringWithFormat:@"ok(imgCS=%@, %zux%zu)", imgCSDesc, cw, ch];
                        self.lastP3Applied = NO; // 色彩转换由 CoreGraphics 自动完成
                        return YES;
                    }
                    CGColorSpaceRelease(cs);
                    free(cgOut);
                }
            }
            self.lastSystemPath = [NSString stringWithFormat:@"CGImage 有效(imgCS=%@)但绘制失败", imgCSDesc];
            CGImageRelease(cg);
        }
        // 创建/绘制失败则回退手动读取
    }

    // ---- 读取: 加锁读取 readSurface(加速器成功时即 dstSurface; 否则为源 surface) ----
    kern_return_t lk = lockFn(readSurface, 0 /*对齐原版 mov w1,#0*/, NULL);
    if (lk != KERN_SUCCESS) {
        NSLog(@"[TSScreenCapture] IOSurfaceLock 失败 kr=%d", (int)lk);
        if (dstSurface) { CFRelease(dstSurface); }
        return NO;
    }
    size_t w = widthFn(readSurface);
    size_t h = heightFn(readSurface);
    size_t bpr = bytesPerRowFn(readSurface);
    void *base = baseAddrFn(readSurface);
    if (w == 0 || h == 0 || bpr < w * 4 || !base) {
        unlockFn(readSurface, 0, NULL);
        if (dstSurface) { CFRelease(dstSurface); }
        return NO;
    }

    uint8_t *out = malloc(w * h * 4);
    if (!out) {
        unlockFn(readSurface, 0, NULL);
        if (dstSurface) { CFRelease(dstSurface); }
        return NO;
    }
    // 诊断: 进程内转储缓冲 malloc 流量累计(每次截屏 ~4MB, 对比 heap 增长判断
    // 缓冲是否被正常 free —— 若 dumpMalloc 累计巨大而 heap 不涨, 说明缓冲都释放了,
    // 泄漏在别处(系统侧 surface 或 ObjC 对象); 若 heap 同步涨, 则进程内泄漏)
    _statDumpMallocCount++;
    _statDumpMallocBytes += (unsigned long long)w * (unsigned long long)h * 4;

    uint32_t fmt = pixelFormatFn ? pixelFormatFn(readSurface) : 0x42475241; // 默认假设 BGRA
    self.lastReadFormat = [NSString stringWithFormat:@"0x%08X", (unsigned int)fmt];

    // ---- P3→sRGB 转换决策(按可靠度排序) ----
    // 1. skipColorConvert(CARenderServer): 系统已按 surface 声明的 sRGB 渲染完成
    // 2. source surface 的 IOSurfaceColorSpace 属性: 系统标记的内容真实色彩空间
    // 3. iOS16+ 的 'w30r'(createScreenIOSurface): 内容编码随渲染管线
    //    - P3 屏(iOS16 新机): 内容按 Display P3 编码, 需转 sRGB
    //      (直接截断当 sRGB 会整体降饱和发灰, B.png 实测 243→217)
    //    - sRGB 屏(iOS15 老机): 内容按 sRGB 编码, 无需转换
    //    故按屏幕类型判定(_screenUsesP3)
    // 4. 兜底: 按屏幕类型判定(_screenUsesP3)
    NSString *surfaceCS = [self _surfaceColorSpaceName:sourceSurface];
    self.lastSourceColorSpace = surfaceCS ?: @"(无属性)";
    BOOL attrSrgb = NO, attrP3 = NO;
    if (surfaceCS.length) {
        attrSrgb = ([surfaceCS rangeOfString:@"sRGB" options:NSCaseInsensitiveSearch].location != NSNotFound);
        if (!attrSrgb) {
            attrP3 = ([surfaceCS rangeOfString:@"P3" options:NSCaseInsensitiveSearch].location != NSNotFound
                      || [surfaceCS rangeOfString:@"WideGamut" options:NSCaseInsensitiveSearch].location != NSNotFound);
        }
    }
    NSString *decision = nil;
    BOOL p3ToSrgb;
    if (skipColorConvert) {
        p3ToSrgb = NO;    decision = @"car-server(sRGB 已就绪)";
    } else if (attrSrgb) {
        p3ToSrgb = NO;    decision = @"attribute-srgb";
    } else if (attrP3) {
        p3ToSrgb = YES;   decision = @"attribute-p3";
    } else if (fmt == 0x77333072) {
        // 'w30r' = kCVPixelFormatType_30RGBLEPackedWideGamut = 10-bit Display P3。
        // 内容编码随渲染管线:
        //   - P3 屏(iOS 16 新机): surface 内容按 Display P3 编码, 直接截断当 sRGB
        //     会整体降饱和发灰(B.png 750x1334 实测: 与 A.png 同界面色相一致,
        //     但平均亮度 217 vs 243、8 水平带亮度均匀无渐变 = 降饱和灰非遮罩;
        //     原版走 _UICreateCGImageFromIOSurface 由 CoreGraphics 做 P3→sRGB 正常)。
        //   - sRGB 屏(iOS 15 老机): 内容按 sRGB 编码, 无需转换。
        // 故按屏幕类型(_screenUsesP3)决定转换。
        // [iOS 16.6 + P3 屏 决定性修正] createScreenIOSurface 返回的 w30r 源是
        // ERSRGB(Extended Range sRGB): SDR 白点 = 0.874(10-bit 894=0x37E)。
        //   c56004c 实测: 白点归一化(894→255)后中心白正确, 但保留 P3→sRGB 矩阵
        //   让彩色降饱和, P3 屏上对比屏幕仍有"一层灰色遮盖"(sRGB 色域<P3 色域)。
        //   27cf421 改: 白点归一化 + 8-bit 直出, 中心白 255 正确, 但手机实测
        //   C.png 饱和色(金/蓝/绿)仍明显发灰。
        //   现用 A.png(原版) 与 C.png 同元素样本拟合出原版转换 =
        //   编码域对比度拉伸 E = 1.74*C - 188.7, 全样本误差≤2, 全局误差 1.5。
        p3ToSrgb = _screenUsesP3();
        decision = p3ToSrgb ? @"format-w30r(edr-w30r 白点894归一化→编码域对比度拉伸 1.74C-188.7)" : @"format-w30r(srgb 屏内容已 sRGB)";
    } else {
        p3ToSrgb = _screenUsesP3();
        decision = p3ToSrgb ? @"screen-fallback(p3)" : @"screen-fallback(srgb)";
    }
    self.lastColorDecision = decision;
    self.lastP3Applied = p3ToSrgb;
    if (p3ToSrgb) {
        _ensureColorLUTs();
    }
    // 诊断: 记录屏幕中心像素的源值(10-bit 原始/8-bit)与转换后输出值
    __block uint32_t dbgSrc[3] = {0, 0, 0};
    __block BOOL dbgSrcIs10bit = NO;
    const size_t cx = w / 2, cy = h / 2;
    for (size_t y = 0; y < h; y++) {
        uint8_t *src = (uint8_t *)base + y * bpr;
        uint8_t *dst = out + y * w * 4;
        for (size_t x = 0; x < w; x++) {
            if (fmt == 0x42475241 /*BGRA*/) {
                uint8_t R = src[x*4+2];
                uint8_t G = src[x*4+1];
                uint8_t B = src[x*4+0];
                if (x == cx && y == cy) {
                    dbgSrc[0] = R; dbgSrc[1] = G; dbgSrc[2] = B; dbgSrcIs10bit = NO;
                }
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
            } else if (fmt == 0x77333072 /* 'w30r': kCVPixelFormatType_30RGBLEPackedWideGamut */) {
                // iOS 16+ createScreenIOSurface 返回 10-bit 广色域 surface(Display P3)。
                // 官方定义: 'w30r' = little-endian RGB101010, 2 MSB 为 0。
                // 32-bit little-endian 打包(32-bit 值 = 内存 4 字节按小端组合):
                //   bits [31:30]=未用, [29:20]=R(10b), [19:10]=G(10b), [9:0]=B(10b)。
                // ★R 在最高 10 位(bit 29:20), B 在最低 10 位(bit 9:0)。
                //   真机实测验证(iOS 16.6 截屏): 曾一度按"R 在最低位"解析, 结果截图
                //   R/B 互换(红蓝颠倒); 还原为 R 高位后颜色通道正确。
                // Display P3 传递函数 = sRGB OETF, 10-bit 线性化后走同一 P3→sRGB 矩阵。
                // 注: 此格式无 alpha, 剩余 2 bit 未定义。
                uint32_t px = *(const uint32_t *)(src + x * 4);
                uint16_t r10 = (px >> 20) & 0x3FF;
                uint16_t g10 = (px >> 10) & 0x3FF;
                uint16_t b10 = (px >>  0) & 0x3FF;
                if (x == cx && y == cy) {
                    dbgSrc[0] = r10; dbgSrc[1] = g10; dbgSrc[2] = b10; dbgSrcIs10bit = YES;
                }
                // ERSRGB 白点归一化 + 编码域对比度拉伸(复刻原版色调映射):
                // iOS 16 的 w30r 源是 ERSRGB(白点 0.874 = 10-bit 894), 894 即屏幕白。
                // 27cf421 纯直出(C.png) 实测在手机上明显发灰——直出是"白点归一化的
                // ERSRGB 值", 缺少原版加速器/CG 的色调映射增强。
                // 用 A.png(原版) 与 C.png(直出) 同元素样本拟合出原版转换 =
                // 编码域对比度拉伸: E = 1.74*C - 188.7 (0-255 clamp)。
                // 验证: 金(255,149,0)/蓝(88,86,214)/绿(89,209,120)/灰/白全样本误差≤2,
                //       E-vs-A 全局差异均值 1.5(C-vs-A 为 12), 显著差异 0.2%(4.8%)。
                // sRGB 屏(iOS 15 老机走 8-bit BGRA 满量程, 不经此分支)不受影响。
                const float kEdrWhite = 894.0f; // 10-bit ERSRGB 白点(0x37E)
                int r8 = (int)llroundf(1.74f * (r10 * (255.0f / kEdrWhite)) - 188.7f);
                int g8 = (int)llroundf(1.74f * (g10 * (255.0f / kEdrWhite)) - 188.7f);
                int b8 = (int)llroundf(1.74f * (b10 * (255.0f / kEdrWhite)) - 188.7f);
                if (r8 < 0) r8 = 0; else if (r8 > 255) r8 = 255;
                if (g8 < 0) g8 = 0; else if (g8 > 255) g8 = 255;
                if (b8 < 0) b8 = 0; else if (b8 > 255) b8 = 255;
                dst[x*4+0] = (uint8_t)r8;
                dst[x*4+1] = (uint8_t)g8;
                dst[x*4+2] = (uint8_t)b8;
                dst[x*4+3] = 255;
            } else {
                dst[x*4+0] = src[x*4+0];
                dst[x*4+1] = src[x*4+1];
                dst[x*4+2] = src[x*4+2];
                dst[x*4+3] = src[x*4+3];
                if (x == cx && y == cy) {
                    dbgSrc[0] = src[x*4+2]; dbgSrc[1] = src[x*4+1]; dbgSrc[2] = src[x*4+0]; dbgSrcIs10bit = NO;
                }
            }
        }
    }
    // 诊断: 中心像素源值/输出值
    if (dbgSrcIs10bit) {
        self.lastSrcPx = [NSString stringWithFormat:@"center src 10bit R=0x%03X(%u) G=0x%03X(%u) B=0x%03X(%u)",
                          (unsigned)dbgSrc[0], (unsigned)dbgSrc[0],
                          (unsigned)dbgSrc[1], (unsigned)dbgSrc[1],
                          (unsigned)dbgSrc[2], (unsigned)dbgSrc[2]];
    } else {
        self.lastSrcPx = [NSString stringWithFormat:@"center src 8bit R=%u G=%u B=%u",
                          (unsigned)dbgSrc[0], (unsigned)dbgSrc[1], (unsigned)dbgSrc[2]];
    }
    // 输出内存序为 R,G,B,A(out[0]=R,out[1]=G,out[2]=B)，此前 R/B 标签写反
    self.lastOutPx = [NSString stringWithFormat:@"center out R=%u G=%u B=%u A=%u",
                      out[(cy*w+cx)*4+0], out[(cy*w+cx)*4+1], out[(cy*w+cx)*4+2], out[(cy*w+cx)*4+3]];
    unlockFn(readSurface, 0, NULL);
    if (dstSurface) { CFRelease(dstSurface); }

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
    if (![self _dumpIOSurface:surface skipColorConvert:NO directReadIfBgra:NO pixelsOut:&px width:&w height:&h] || !px) {
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
    if (result) { _statUIScreenCreateCalls++; }
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
        __block BOOL timedOut = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            IOSurfaceRef s = [self _createUIScreenSurface];
            BOOL abandoned = NO;
            @synchronized (self) {
                if (timedOut) { abandoned = YES; }
                else { created = s; }
            }
            dispatch_semaphore_signal(sema);
            // 主线程已超时未取走时, block 自行释放, 避免 surface 泄漏
            if (abandoned && s) { _statUIScreenReleased++; CFRelease(s); }
        });
        long ws = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC));
        if (ws != 0) {
            @synchronized (self) { timedOut = YES; }
            // 等主线程 block 收尾(创建+释放)完成再返回, 确保不泄漏
            dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC));
            TSSetLastError(@"路径0 UIScreenSurface: 主线程 800ms 未响应, 截屏取消");
            return NO;
        }
        surf = created;
    }
    if (!surf) {
        TSSetLastError(@"路径0 UIScreenSurface: 全部候选均未返回 IOSurface(需 iOS12+ 且 TrollStore 全权限环境)");
        return NO;
    }

    // 读取像素(后台线程, 走 _UICreateCGImageFromIOSurface / 加速器转储 / 手动 lock 三级读取)
    uint8_t *px = NULL; int w = 0, h = 0;
    BOOL ok = [self _dumpIOSurface:surf skipColorConvert:NO directReadIfBgra:NO pixelsOut:&px width:&w height:&h] && px;
    // 诊断: 记录本次 surface 的 alloc size(系统侧 GPU/IO 内存量级), 累计用于判断
    // "创建-释放是否配对" —— 若 allocBytes 增长远高于释放次数预期, 即为系统侧累积。
    size_t (*allocSizeFn)(IOSurfaceRef) = _iosurfaceHandle ? dlsym(_iosurfaceHandle, "IOSurfaceGetAllocSize") : NULL;
    if (allocSizeFn) {
        size_t asz = allocSizeFn(surf);
        _statUIScreenAllocBytes += asz;
        _statUIScreenAllocSizeLast = asz;
    }
    _statUIScreenReleased++;
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
        if ([self _dumpIOSurface:found skipColorConvert:NO directReadIfBgra:NO pixelsOut:&px width:&w height:&h] && px) {
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
    // GPU 内存区(PurpleGFXMemory): 对齐转储目标 surface —— 让 WindowServer 渲染
    // 与 IOSurfaceAccelerator 可写该 surface, 否则 iOS 16 上渲染/传输可能被拒。
    CFDictionarySetValue(props, CFSTR("MemoryRegion"), CFSTR("PurpleGFXMemory"));
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
    _logThrottled(@"[TSScreenCapture] 尝试 CARenderServerRenderDisplay 截屏 %dx%d", w, h);

    // 复用上次的 src surface(尺寸不变), 避免每次截屏重建 12MB GPU IOSurface。
    // iOS 16 高频截屏下每次创建/释放 GPU surface 导致 IO 内存暴涨被 jetsam 杀
    // (SE3 iOS16.6 实测 7 秒爆内存; 6S iOS15 走 UIScreenSurface 系统 surface 无此问题)。
    // renderFn 每次把当前帧重绘到该 surface, 内容实时, 不影响"点击后取新帧"语义。
    IOSurfaceRef src = NULL;
    @synchronized (self) {
        if (_renderServerSurface && _renderServerSurfaceW == w && _renderServerSurfaceH == h) {
            src = (IOSurfaceRef)CFRetain(_renderServerSurface);
        } else {
            if (_renderServerSurface) { CFRelease(_renderServerSurface); _renderServerSurface = NULL; }
            src = [self _createIOSurfaceWithWidth:w height:h];
            if (src) {
                _renderServerSurface = (IOSurfaceRef)CFRetain(src);
                _renderServerSurfaceW = w;
                _renderServerSurfaceH = h;
            }
        }
    }
    if (!src) {
        TSSetLastError(@"路径2 CARenderServer: 创建 IOSurface 失败 %dx%d", w, h);
        NSLog(@"[TSScreenCapture] CARenderServer 方案创建 IOSurface 失败 %dx%d", w, h);
        return NO;
    }
    @try {
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

            // surface 声明为 sRGB, WindowServer 渲染已完成色彩管理,
            // 像素即 sRGB 编码 —— 跳过 P3→sRGB 二次转换(iOS16+P3 屏发灰修复)
            uint8_t *px = NULL; int rw = 0, rh = 0;
            // 优先直读(自建 BGRA surface, 零 GPU 分配); 失败/全空回退复用转储
            // (accel+dstSurface 均已常驻复用, 也不创建新 GPU surface)。
            // 两个读取端都失败才判为失败 —— 不再落回 createScreenIOSurface
            // (iOS16 上该路径每次新建系统 GPU surface 且不随释放回收, 是累积源)。
            BOOL dumpOK = [self _dumpIOSurface:src skipColorConvert:YES directReadIfBgra:YES
                                       pixelsOut:&px width:&rw height:&rh] && px;
            if (dumpOK && [self _isAllZeroPixels:px width:rw height:rh]) {
                free(px); px = NULL; dumpOK = NO;
            }
            if (!dumpOK) {
                _statRenderServerDirectFail++;
                dumpOK = [self _dumpIOSurface:src skipColorConvert:YES directReadIfBgra:NO
                                      pixelsOut:&px width:&rw height:&rh] && px;
                if (dumpOK && [self _isAllZeroPixels:px width:rw height:rh]) {
                    free(px); px = NULL; dumpOK = NO;
                }
            } else {
                _statRenderServerDirectOK++;
            }
            if (dumpOK) {
                _statRenderServerOK++;
                _logThrottled(@"[TSScreenCapture] CARenderServer 截屏成功 %dx%d (display=%s)",
                      rw, rh, displayNames[attempt]);
                self.lastError = nil;
                *pixelsOut = px; *widthOut = rw; *heightOut = rh;
                return YES;
            }
            _statRenderServerFail++;
            if (px) { free(px); px = NULL; }
            TSSetLastError(@"路径2 CARenderServer: display=%s 渲染结果全空(可能被 WindowServer 拒绝)", displayNames[attempt]);
            NSLog(@"[TSScreenCapture] CARenderServer display=%s 读取失败(直读+转储均空)", displayNames[attempt]);
        }

        NSLog(@"[TSScreenCapture] CARenderServerRenderDisplay 两次渲染均取到空内容");
        return NO;
    } @finally {
        // 仅释放本地临时引用; _renderServerSurface 缓存引用保留, 供下次复用
        CFRelease(src);
    }
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
        if ([self _dumpIOSurface:src skipColorConvert:NO directReadIfBgra:NO pixelsOut:&px width:&w height:&h] && px) {
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
    // iOS 16 上每次 [UIScreen createScreenIOSurface] 都会在系统侧新建全屏 GPU
    // IOSurface。挂机脚本约每 100ms 截一次屏, 即使进程内 CFRelease, 系统侧的
    // IO/GPU 内存也持续累积, 几小时后触发 Jetsam 杀后台 —— 与下方
    // _captureRenderServerToRGBA 注释中 SE3 iOS16.6 实测结论一致。
    // CARenderServerRenderDisplay 复用同一个自建 surface 反复渲染, 无累积问题,
    // 因此 iOS 16 后台也改为 CARenderServer 优先; iOS 15 保持 UIScreen 优先
    // (系统 surface 无此问题, 与原版行为一致)。
    BOOL isIOS16OrLater = ([[UIDevice currentDevice].systemVersion doubleValue] >= 16.0);
    if (isIOS16OrLater && [self _captureRenderServerToRGBA:pixelsOut width:widthOut height:heightOut]) {
        return YES;
    }
    NSString *errRS = isIOS16OrLater ? [self.lastError copy] : nil;
    // 0. UIScreen createScreenIOSurface(原版核心链路, 系统级全屏 surface, 与 App 前后台无关)
    //    iOS 15: 系统 surface 回收正常, 每次截屏都重新创建(与原版行为一致)。
    //    iOS 16: RenderServer 失败后的节流兜底 —— 该路径每次调用都在系统侧新建全屏
    //    GPU surface 且不随 CFRelease 及时回收(挂机几小时后 Jetsam 的累积源)。
    //    兜底帧缓存 1 秒: 1 秒内再次失败直接复用缓存帧, createScreenIOSurface 实际
    //    调用 ≤1 次/秒(原为每 100ms 一次), 累积速度降低约 10 倍, 同时保住
    //    RenderServer 不可用时的取色(否则 iOS 16 上截屏全挂 → 找色失败)。
    if (isIOS16OrLater) {
        static uint8_t *sFbPx = NULL;
        static int sFbW = 0, sFbH = 0;
        static NSTimeInterval sFbAt = 0;
        NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
        if (sFbPx && sFbW > 0 && sFbH > 0 && (now - sFbAt) < 1.0) {
            uint8_t *copy = malloc((size_t)sFbW * (size_t)sFbH * 4);
            if (copy) {
                memcpy(copy, sFbPx, (size_t)sFbW * (size_t)sFbH * 4);
                _statCreateUIScreenOK++;
                _statUIScreenCacheHit++;   // 1 秒节流命中: 未调用 createScreenIOSurface
                *pixelsOut = copy; *widthOut = sFbW; *heightOut = sFbH;
                self.lastError = nil;
                return YES;
            }
        }
        BOOL ok0 = [self _captureUIScreenIOSurfaceToRGBA:pixelsOut width:widthOut height:heightOut];
        if (ok0) {
            if (sFbPx) { free(sFbPx); }
            sFbW = *widthOut; sFbH = *heightOut;
            sFbPx = malloc((size_t)sFbW * (size_t)sFbH * 4);
            if (sFbPx) { memcpy(sFbPx, *pixelsOut, (size_t)sFbW * (size_t)sFbH * 4); }
            sFbAt = now;
            _statCreateUIScreenOK++;
            _statUIScreenRealCreateOK++;
            return YES;
        }
        _statCreateUIScreenFail++;
    } else {
        BOOL ok0 = [self _captureUIScreenIOSurfaceToRGBA:pixelsOut width:widthOut height:heightOut];
        if (ok0) { _statCreateUIScreenOK++; _statUIScreenRealCreateOK++; return YES; }
        _statCreateUIScreenFail++;
    }
    NSString *err0 = isIOS16OrLater ? nil : [self.lastError copy];
    // 1. CARenderServerRenderDisplay: TrollShot/TrollVNC 在后台/锁屏验证过的跨 App 截屏方案,
    //    走 WindowServer 渲染管线, 与 App 自身前后台无关。iOS 16 已在上面优先尝试。
    if (!isIOS16OrLater && [self _captureRenderServerToRGBA:pixelsOut width:widthOut height:heightOut]) {
        return YES;
    }
    if (!errRS) { errRS = [self.lastError copy]; }
    // 2. IORegistry DisplaySurface + IOSurfaceLookup(全局显示缓冲, 不依赖前台)
    if ([self _captureGlobalDisplayToRGBA:pixelsOut width:widthOut height:heightOut]) {
        _statGlobalOK++;
        return YES;
    }
    _statGlobalFail++;
    NSString *errGD = [self.lastError copy];
    // 3. 兜底: 读 UIScreen surface 缓存(可能含前台最后一帧, 不重新创建、不阻塞主线程)
    IOSurfaceRef cached = [self _getCachedScreenSurface];
    if (cached) {
        uint8_t *px = NULL; int w = 0, h = 0;
        BOOL ok = [self _dumpIOSurface:cached skipColorConvert:NO directReadIfBgra:NO pixelsOut:&px width:&w height:&h] && px
                  && ![self _isAllZeroPixels:px width:w height:h];
        CFRelease(cached);
        if (ok) {
            _statCacheOK++;
            self.lastError = nil;
            *pixelsOut = px; *widthOut = w; *heightOut = h;
            return YES;
        }
        _statCacheFail++;
        if (px) { free(px); }
        [self _setCachedScreenSurface:NULL];
    }
    self.lastError = [NSString stringWithFormat:@"后台截屏: createScreenIOSurface: %@; CARenderServer: %@; 全局显示: %@; UIScreen 缓存: 空/全0",
                      err0 ?: @"未尝试", errRS ?: @"未尝试", errGD ?: @"未尝试"];
    return NO;
}

#pragma mark - 截图链路诊断

+ (void)noteGrabScreenCall { s_statGrabScreenCalls++; }
+ (void)noteGrabScreenThrottled { s_statGrabThrottled++; }

/// 截屏路径统计摘要(供 AppDelegate 周期写入 touch.log, 定位 iOS16 高频截屏内存累积来源)
- (NSString *)statsLine {
    // 诊断字段说明(2026-09-01, 定位 iOS16 挂机内存累积):
    //   UIScreen创建 = createScreenIOSurface 真实调用次数(系统侧 GPU surface 新建)
    //   UIScreen释放 = 进程内已 CFRelease 次数; 若 创建-释放 持续为正 → 进程内未释放
    //   缓存命中     = 后台 1 秒节流命中(未新建 surface, 不产生系统侧内存)
    //   alloc累计    = 已释放 surface 的 alloc size 总和(衡量系统侧 surface 大小)
    //   keep 限频跳过 = keepPixels 60ms 限频拦截次数; keep 实际截屏 = 真实触发的截屏
    UIApplicationState st = [UIApplication sharedApplication].applicationState;
    NSString *stName = (st == UIApplicationStateActive) ? @"前台Active"
                      : (st == UIApplicationStateInactive) ? @"Inactive" : @"后台Background";
    return [NSString stringWithFormat:
        @"[截屏] %@ RenderServer 成功%llu/失败%llu(直读%llu/转储回退%llu) "
        @"UIScreen 创建%llu/释放%llu 成功%llu/失败%llu(缓存命中%llu/真实创建%llu) "
        @"alloc累计%llu(最近%llu) "
        @"全局显示 成功%llu/失败%llu 缓存 成功%llu/失败%llu "
        @"keep 调用%llu 限频跳过%llu 实际截屏%llu grab 调用%llu/限频跳过%llu "
        @"dump malloc %llu次/%lluMB 总请求%llu",
        stName,
        _statRenderServerOK, _statRenderServerFail,
        _statRenderServerDirectOK, _statRenderServerDirectFail,
        _statUIScreenCreateCalls, _statUIScreenReleased,
        _statCreateUIScreenOK, _statCreateUIScreenFail, _statUIScreenCacheHit, _statUIScreenRealCreateOK,
        _statUIScreenAllocBytes, _statUIScreenAllocSizeLast,
        _statGlobalOK, _statGlobalFail,
        _statCacheOK, _statCacheFail,
        _statKeepCalls, _statKeepThrottled, _statKeepRealCapture,
        s_statGrabScreenCalls, s_statGrabThrottled,
        _statDumpMallocCount, _statDumpMallocBytes / 1024 / 1024,
        _statCaptureCalls];
}

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
            BOOL dumpOk = (sw > 0 && sh > 0) && [self _dumpIOSurface:s skipColorConvert:NO directReadIfBgra:NO pixelsOut:&px width:&dw height:&dh];
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
            BOOL hdump = (gW && gH && gW(hs) > 0) && [self _dumpIOSurface:hs skipColorConvert:NO directReadIfBgra:NO pixelsOut:&hpx width:&hw height:&hh];
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
        // iOS15/16 分离 + 格式诊断
        diag[@"systemVersion"] = [UIDevice currentDevice].systemVersion;
        diag[@"lastPathUsed"] = self.lastPathUsed ?: @"(无)";
        diag[@"lastSourceFormat"] = self.lastSourceFormat ?: @"(无)";
        diag[@"lastReadFormat"] = self.lastReadFormat ?: @"(无)";
        diag[@"lastAccelOK"] = @(self.lastAccelOK);
        diag[@"lastAccelError"] = @(self.lastAccelError);
        diag[@"lastSystemPath"] = self.lastSystemPath ?: @"(未进入)";
        diag[@"uiCreateCGImageSource"] = self.uiCreateCGImageSource ?: @"(未加载)";
        diag[@"lastP3Applied"] = @(self.lastP3Applied);
        diag[@"srcColorSpace"] = self.lastSourceColorSpace ?: @"(无)";
        diag[@"colorDecision"] = self.lastColorDecision ?: @"(无)";
        diag[@"lastSrcPx"] = self.lastSrcPx ?: @"(无)";
        diag[@"lastOutPx"] = self.lastOutPx ?: @"(无)";
        diag[@"screenP3"] = @(_screenUsesP3());
    } @catch (NSException *e) {
        diag[@"exception"] = [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
    }
    return diag;
}

- (BOOL)captureScreenToRGBA:(uint8_t **)pixelsOut
                     width:(int *)widthOut
                    height:(int *)heightOut {
    _statCaptureCalls++;
    self.lastPathUsed = @"(未截屏)";
    self.lastSourceFormat = nil;
    self.lastReadFormat = nil;
    self.lastAccelOK = NO;
    self.lastAccelError = 0;
    self.lastSystemPath = nil;
    self.lastP3Applied = NO;
    self.lastSourceColorSpace = nil;
    self.lastColorDecision = nil;
    self.lastSrcPx = nil;
    self.lastOutPx = nil;

    // 后台状态: 切换到后台专用路径。
    UIApplicationState bgState = [UIApplication sharedApplication].applicationState;
    if (bgState == UIApplicationStateBackground) {
        BOOL ok = [self _captureBackgroundToRGBA:pixelsOut width:widthOut height:heightOut];
        if (ok) { self.lastPathUsed = @"Background(后台)"; }
        return ok;
    }

    // iOS 15 / iOS 16 截屏路径分离:
    //  - iOS 16+: [UIScreen createScreenIOSurface] 返回的系统 surface 格式/位深已变化,
    //    加速器转储到 BGRA8 后会呈"热成像"伪彩色, 因此优先 CARenderServer 渲染到
    //    自建 BGRA surface(格式可控, TrollVNC 同款方案)。
    //  - iOS 15-: 保持原版链路顺序(UIScreen surface 优先), 与原版行为一致,
    //    避免修好 iOS 16 却破坏 iOS 15。
    BOOL isIOS16OrLater = ([[UIDevice currentDevice].systemVersion doubleValue] >= 16.0);
    NSArray<NSString *> *order = isIOS16OrLater
        ? @[@"CARenderServer", @"UIScreenSurface", @"GlobalDisplay", @"SystemWindow", @"IOMFB", @"AppWindow"]
        : @[@"UIScreenSurface", @"GlobalDisplay", @"SystemWindow", @"CARenderServer", @"IOMFB", @"AppWindow"];

    NSMutableArray<NSString *> *errs = [NSMutableArray array];
    for (NSString *path in order) {
        BOOL ok = [self _tryCapturePath:path pixelsOut:pixelsOut width:widthOut height:heightOut];
        if (ok) {
            self.lastPathUsed = path;
            NSLog(@"[TSScreenCapture] 截屏成功: 路径=%@ (iOS%@)", path, [UIDevice currentDevice].systemVersion);
            return YES;
        }
        [errs addObject:[NSString stringWithFormat:@"%@: %@", path, self.lastError ?: @"失败"]];
    }

    NSLog(@"[TSScreenCapture] 全部截屏路径失败, 回退应用内截屏");
    BOOL ok = [self _captureAppWindowToRGBA:pixelsOut width:widthOut height:heightOut];
    if (ok) {
        self.lastPathUsed = @"AppWindow(兜底)";
        return YES;
    }
    [errs addObject:[NSString stringWithFormat:@"AppWindow: %@", self.lastError ?: @"失败"]];
    self.lastError = [errs componentsJoinedByString:@"; "];
    return NO;
}

/// 按名称尝试对应截屏路径(供 captureScreenToRGBA 的 iOS15/16 分离顺序使用)。
- (BOOL)_tryCapturePath:(NSString *)path
              pixelsOut:(uint8_t **)pixelsOut
                  width:(int *)widthOut
                 height:(int *)heightOut {
    if ([path isEqualToString:@"CARenderServer"]) {
        return [self _captureRenderServerToRGBA:pixelsOut width:widthOut height:heightOut];
    }
    if ([path isEqualToString:@"UIScreenSurface"]) {
        return [self _captureUIScreenIOSurfaceToRGBA:pixelsOut width:widthOut height:heightOut];
    }
    if ([path isEqualToString:@"GlobalDisplay"]) {
        return [self _captureGlobalDisplayToRGBA:pixelsOut width:widthOut height:heightOut];
    }
    if ([path isEqualToString:@"SystemWindow"]) {
        return [self _captureSystemWindowToRGBA:pixelsOut width:widthOut height:heightOut];
    }
    if ([path isEqualToString:@"IOMFB"]) {
        return [self _captureFramebufferToRGBA:pixelsOut width:widthOut height:heightOut];
    }
    if ([path isEqualToString:@"AppWindow"]) {
        return [self _captureAppWindowToRGBA:pixelsOut width:widthOut height:heightOut];
    }
    return NO;
}

- (UIImage *)captureImage {
    return [self captureImageWithPath:nil];
}

- (UIImage *)captureImageWithPath:(NSString *)path {
    uint8_t *pixels = NULL;
    int w = 0, h = 0;
    BOOL ok;
    if (path.length > 0) {
        ok = [self _tryCapturePath:path pixelsOut:&pixels width:&w height:&h];
    } else {
        ok = [self captureScreenToRGBA:&pixels width:&w height:&h];
    }
    if (!ok || !pixels) { return nil; }
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
    _statKeepCalls++;
    // 60ms 限频(与 grabScreen 一致): 无 mSleep 的死循环脚本每圈 keep() 都会触发一次
    // 完整截屏 —— createScreenIOSurface 在系统侧新建全屏 GPU surface, 实测可达 100 次/秒,
    // iOS15/16 上系统侧均不随 CFRelease 及时回收, 持续累积内存(6S iOS15.8.4 实测约 71MB/h,
    // 7 小时 footprint 涨 487MB)。限频后复用现有缓存帧(≤16.7fps 更新), 对找色脚本足够。
    // 注: 缓存被 unkeep 清空时不限频(必须截屏), 但后续 findColor 走 grabScreen 仍有
    // 60ms 限频兜底, 整体截屏频率不会失控。
    static NSTimeInterval lastKeepAt = 0;
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if (_cachedPixels && _cachedWidth > 0 && _cachedHeight > 0 &&
        lastKeepAt > 0 && (now - lastKeepAt) < 0.06) {
        _statKeepThrottled++;
        return;
    }
    lastKeepAt = now;
    // 先释放旧缓存
    if (_cachedPixels) { free(_cachedPixels); _cachedPixels = NULL; }

    if (![self captureScreenToRGBA:&_cachedPixels width:&_cachedWidth height:&_cachedHeight]) {
        _cachedPixels = NULL; _cachedWidth = 0; _cachedHeight = 0;
    } else {
        _statKeepRealCapture++;
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

- (BOOL)getCachedColorAtPoint:(CGPoint)point
                   screenSize:(CGSize)screenSize
                            r:(int *)r g:(int *)g b:(int *)b {
    // 仅当 keep 缓存存在时零分配读单点（避免每帧 4MB 副本 malloc/memcpy/free 的
    // 内存流量把死循环脚本压垮）；无缓存时返回 NO，由调用方回退到 grabScreen。
    if (!_cachedPixels || _cachedWidth <= 0 || _cachedHeight <= 0) { return NO; }
    int color = [TSColorFinder getColorAtPoint:point
                                        pixels:_cachedPixels
                                         width:_cachedWidth height:_cachedHeight
                                    screenSize:screenSize];
    if (r) { *r = (color >> 16) & 0xFF; }
    if (g) { *g = (color >> 8) & 0xFF; }
    if (b) { *b = color & 0xFF; }
    return YES;
}

- (void)dealloc {
    if (_cachedPixels) { free(_cachedPixels); _cachedPixels = NULL; }
    if (_cachedScreenSurface) { CFRelease(_cachedScreenSurface); _cachedScreenSurface = NULL; }
    if (_renderServerSurface) { CFRelease(_renderServerSurface); _renderServerSurface = NULL; }
}

@end
