//
//  TSScreenCapture.h
//  TrollAutoTouch
//
//  屏幕截图 —— 对应原版 TrollAutoScript 的截屏能力。
//
//  原版逆向: 主程序与 HUDServices 均声明了 IOSurfaceRootUserClient /
//  IOSurfaceAcceleratorClient 权限，并通过 IOSurface + IOMobileFramebuffer
//  读取 GPU 帧缓冲做高速整屏截取(可截任意 App，含系统界面)。
//
//  本类提供两条路径:
//   - 系统级 (默认尝试): 走 IOMobileFramebuffer + IOSurface 私有 API，可截任意 App。
//   - 应用内回退: UIGraphicsImageRenderer 截取本 App 窗口(用于自测/无权限时)。
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
