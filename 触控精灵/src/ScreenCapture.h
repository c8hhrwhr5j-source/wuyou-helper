/**
 *  ScreenCapture.h
 *  全屏截图 + 像素取色 + 区域找色
 *
 *  使用 IOMobileFramebuffer + IOSurface 直接读取屏幕帧缓冲
 *  无弹窗、纯内存操作、不保存文件
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface ScreenCapture : NSObject

+ (instancetype)shared;

/// 获取当前屏幕截图像素缓冲区（BGRA 格式）
/// 返回 raw pixel data，调用者不释放
- (const uint8_t *)captureScreenWithWidth:(int *)outWidth
                                   height:(int *)outHeight
                               bytesPerRow:(int *)outBytesPerRow;

/// 释放截图缓冲区
- (void)releaseCapture;

/// 获取指定坐标的 RGB 颜色值 (0-255)
/// @return YES 表示成功，NO 表示坐标越界
- (BOOL)getColorAtX:(int)x y:(int)y red:(uint8_t *)r green:(uint8_t *)g blue:(uint8_t *)b;

/// 在指定区域内查找颜色，返回第一个匹配坐标
/// @param similarity 相似度 (0-100)，100 为完全匹配
/// @param outX 输出匹配 X 坐标，未找到时返回 -1
/// @param outY 输出匹配 Y 坐标，未找到时返回 -1
/// @return YES 表示找到匹配
- (BOOL)findColorInRect:(CGRect)rect
              targetRed:(uint8_t)tr
            targetGreen:(uint8_t)tg
             targetBlue:(uint8_t)tb
             similarity:(int)similarity
                   outX:(int *)outX
                   outY:(int *)outY;

/// 获取屏幕分辨率
- (CGSize)screenSize;

/// 刷新截图（在每次找色/取色前调用以获取最新画面）
- (void)refreshCapture;

@end
