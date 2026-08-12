//
//  TSScreenCapture.h
//  TrollAutoTouch
//
//  屏幕截图 —— 对应原版 TrollAutoScript 的截屏能力。
//
//  原版逆向(HUDServices 符号级确认):
//   完全不用 IOMobileFramebuffer。跨应用截屏走 WindowServer 渲染管线:
//   +[UIWindow windowWithContextId:] → IOSurfaceCreate → IOSurfaceAcceleratorTransferSurface
//   → UICreateCGImageFromIOSurface / 直接读像素。该链路不依赖 App 自身前后台状态,
//   因此切到其他 App 后仍能取到真实屏幕像素(依赖 global-capture entitlement)。
//
//  本类提供四级截屏路径(自动回退):
//   0. CARenderServerRenderDisplay: WindowServer 直接渲染主屏到 IOSurface(TrollShot 验证)。
//   1. 系统窗口: [UIWindow windowWithContextId:] + IOSurfaceAccelerator 链路，可截任意 App。
//   2. IOMFB 帧缓冲: 前台场景可用，后台/其他 App 前台时会拿到空 surface(已对齐原版移除主用地位)。
//   3. 应用内回退: UIGraphicsImageRenderer 截取本 App 窗口(用于自测/无权限时)。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSScreenCapture : NSObject

+ (instancetype)shared;

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

/// keepScreen: 缓存上一次截屏像素(避免每次截屏，用于多色查找等场景)
- (void)keepPixels;
/// unkeepScreen: 释放缓存
- (void)unkeepPixels;
/// 获取缓存的像素(不新截屏)。若无缓存则执行一次截屏。
- (BOOL)getCachedPixels:(uint8_t *_Nullable *_Nullable)pixelsOut
                  width:(int *)widthOut height:(int *)heightOut;

@end

NS_ASSUME_NONNULL_END
