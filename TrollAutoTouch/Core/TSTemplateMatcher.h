//
//  TSTemplateMatcher.h
//  TrollAutoTouch
//
//  图像模板匹配 —— 对应原版 screen.findImage / image.match。
//  使用归一化互相关(NCC)算法在截屏中查找模板图像位置。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 匹配结果
@interface TSTemplateMatchResult : NSObject
@property (nonatomic, assign) CGPoint center;    // 匹配中心坐标(逻辑点)
@property (nonatomic, assign) CGFloat confidence; // 置信度 0~1
@property (nonatomic, assign) CGRect rect;       // 匹配区域(逻辑点)
@end

@interface TSTemplateMatcher : NSObject

+ (instancetype)shared;

/// 在整屏中查找模板图像
/// @param templateImage 模板图像(UIImage)
/// @param accuracy 置信度阈值 0~1(建议 0.8)
/// @param rect 搜索区域(逻辑点, CGRectZero=全屏)
/// @return 最佳匹配结果，nil=未找到
- (nullable TSTemplateMatchResult *)findImage:(UIImage *)templateImage
                                     accuracy:(CGFloat)accuracy
                                         rect:(CGRect)rect;

/// 从文件加载模板并查找
/// @param imagePath 模板图像路径
- (nullable TSTemplateMatchResult *)findImageAtPath:(NSString *)imagePath
                                           accuracy:(CGFloat)accuracy
                                               rect:(CGRect)rect;

/// 截屏后查找模板
- (nullable TSTemplateMatchResult *)findImageOnScreen:(UIImage *)templateImage
                                             accuracy:(CGFloat)accuracy
                                                 rect:(CGRect)rect;

/// 在指定像素缓冲区中查找
/// @param pixels RGBA 像素缓冲区
/// @param w 宽度
/// @param h 高度
- (nullable TSTemplateMatchResult *)findImage:(UIImage *)templateImage
                                     accuracy:(CGFloat)accuracy
                                         rect:(CGRect)rect
                                      pixels:(const uint8_t *)pixels
                                       width:(int)w height:(int)h
                                  screenSize:(CGSize)screenSize;

@end

NS_ASSUME_NONNULL_END
