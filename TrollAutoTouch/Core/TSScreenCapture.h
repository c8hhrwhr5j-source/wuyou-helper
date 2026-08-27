//
//  TSScreenCapture.h
//  TrollAutoTouch
//
//  屏幕截图 —— 对应原版 TrollAutoScript 的截屏能力。
//
//  原版逆向(HUDServices + luaLib 符号级确认):
//   完全不用 IOMobileFramebuffer、不用 CARenderServerRenderDisplay。
//   核心截屏链路(反汇编确认)是直接向 UIScreen 索取全屏渲染 surface:
//   [UIScreen mainScreen] createScreenIOSurface (iOS12+ 私有 API, performSelector 动态调用)
//     → 返回绑定主屏渲染管线的全屏 IOSurface(系统级创建, 无需自行 IOSurfaceCreate,
//       后台/跨 App 可用, 这是与所有自建 surface 方案的关键差异)
//   → IOSurfaceLock / IOSurfaceGetBaseAddress 直接读像素
//   → 可选 _UICreateCGImageFromIOSurface / IOSurfaceAcceleratorTransferSurface 转储链路
//   该链路不依赖 App 自身前后台状态, 切到其他 App 后仍能取到真实屏幕像素(依赖 global-capture entitlement)。
//
//  本类提供多级截屏路径(自动回退):
//   0. UIScreen createScreenIOSurface(原版核心链路首选, iOS12+ 私有 API)。
//   1. 系统窗口: windowWithContextId: + createScreenIOSurface, 可截任意 App。
//   2. 全局显示: IORegistry DisplaySurface + IOSurfaceLookup(拿现成 surface)。
//   3. CARenderServerRenderDisplay: WindowServer 直接渲染主屏到 IOSurface(TrollShot 方案, 保留回退)。
//   4. IOMFB 帧缓冲: 前台场景可用，后台/其他 App 前台时会拿到空 surface(已对齐原版移除主用地位)。
//   5. 应用内回退: UIGraphicsImageRenderer 截取本 App 窗口(用于自测/无权限时)。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSScreenCapture : NSObject

+ (instancetype)shared;

/// 最近一次截屏失败原因(逐路径记录, 便于 Lua 层展示); 截屏成功时为 nil。
@property (nonatomic, strong, nullable) NSString *lastError;

/// 最近一次截屏实际成功的路径名(诊断用, /api/screencap-diag 暴露)
@property (nonatomic, strong, nullable) NSString *lastPathUsed;
/// 最近一次 _dumpIOSurface 的 source surface 像素格式(hex 字符串)
@property (nonatomic, strong, nullable) NSString *lastSourceFormat;
/// 最近一次读取时使用的像素格式(hex 字符串, 通常为 BGRA=0x42475241)
@property (nonatomic, strong, nullable) NSString *lastReadFormat;
/// 最近一次加速器(IOSurfaceAcceleratorTransferSurface)转储是否成功
@property (nonatomic, assign) BOOL lastAccelOK;
/// 最近一次加速器转储失败的 kern_return_t 错误码(0=未失败, 诊断用)
@property (nonatomic, assign) int lastAccelError;
/// 最近一次系统色彩管理路径(_UICreateCGImageFromIOSurface)的结果描述(诊断用)
@property (nonatomic, strong, nullable) NSString *lastSystemPath;
/// 最近一次是否执行了 P3->sRGB 转换
@property (nonatomic, assign) BOOL lastP3Applied;
/// 最近一次读取的屏幕中心像素源值(10-bit 原始值或 8-bit 通道值, 诊断用)
@property (nonatomic, strong, nullable) NSString *lastSrcPx;
/// 最近一次读取的屏幕中心像素转换后输出值(诊断用)
@property (nonatomic, strong, nullable) NSString *lastOutPx;
/// 最近一次 source surface 声明的色彩空间(IOSurfaceColorSpace 属性值, 诊断用)
@property (nonatomic, strong, nullable) NSString *lastSourceColorSpace;
/// 最近一次 P3->sRGB 转换的决策依据(attribute-srgb/attribute-p3/format-w30r/screen-fallback/car-server/skip, 诊断用)
@property (nonatomic, strong, nullable) NSString *lastColorDecision;

/// 截取整屏，返回 RGBA 像素缓冲(用于找色)。
/// @param pixelsOut  输出像素数组(调用者用完需 free)。每像素 4 字节 RGBA。
/// @param widthOut   输出宽度(像素)
/// @param heightOut  输出高度(像素)
/// @return 是否成功
- (BOOL)captureScreenToRGBA:(uint8_t *_Nullable *_Nullable)pixelsOut
                     width:(int *)widthOut
                    height:(int *)heightOut;

/// 截屏并返回 UIImage(便于调试/预览)。
- (nullable UIImage *)captureImage;

/// 指定截屏路径并返回 UIImage(调试用, 例如 @"CARenderServer"/@"UIScreenSurface"/@"GlobalDisplay"; nil=默认链路)
- (nullable UIImage *)captureImageWithPath:(nullable NSString *)path;

/// 截图链路诊断信息(供 HTTP /api/screencap-diag 使用, 便于排查各路径失败原因)
- (NSDictionary *)diagnostics;

/// keepScreen: 缓存上一次截屏像素(避免每次截屏，用于多色查找等场景)
- (void)keepPixels;
/// unkeepScreen: 释放缓存
- (void)unkeepPixels;
/// 获取缓存的像素(不新截屏)。若无缓存则执行一次截屏。
- (BOOL)getCachedPixels:(uint8_t *_Nullable *_Nullable)pixelsOut
                  width:(int *)widthOut height:(int *)heightOut;

@end

NS_ASSUME_NONNULL_END
