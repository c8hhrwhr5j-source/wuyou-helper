//
//  TSOCREngine.h
//  TrollAutoTouch
//
//  OCR 文字识别引擎 —— 使用 Apple Vision Framework 替换原版 PaddleOCR/TomatoOCR.so
//
//  功能:
//   - 整屏 OCR 识别，返回文字+坐标
//   - 区域 OCR，限定识别范围
//   - 按文字查找并返回坐标(替代原版 findText 功能)
//   - 支持中文/英文/数字多语言识别
//
//  使用方式:
//    // 整屏 OCR
//    NSArray<TSOCRResult *> *results = [[TSOCREngine shared] recognize:screenshotImage];
//
//    // 区域 OCR
//    NSArray<TSOCRResult *> *results = [[TSOCREngine shared] recognize:screenshotImage rect:CGRectMake(0,0,540,960)];
//
//    // 查找指定文字坐标
//    TSOCRResult *hit = [[TSOCREngine shared] findText:@"确认" inImage:screenshotImage];
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// OCR 单条识别结果
@interface TSOCRResult : NSObject
@property (nonatomic, copy)   NSString  *text;         // 识别的文字
@property (nonatomic, assign) CGRect    boundingBox;    // 归一化坐标 [0,1]
@property (nonatomic, assign) CGFloat   confidence;     // 置信度 [0,1]
@property (nonatomic, assign) CGPoint   center;         // 在实际图像中的中心像素坐标
@property (nonatomic, assign) CGRect    rect;           // 在实际图像中的像素坐标
@end

/// OCR 引擎
@interface TSOCREngine : NSObject

+ (instancetype)shared;

/// 整屏 OCR
/// @param image 待识别的截图
/// @return 识别结果数组（按文字在画面中的位置排序）
- (NSArray<TSOCRResult *> *)recognize:(UIImage *)image;

/// 区域 OCR
/// @param image 待识别的截图
/// @param region 识别区域（图像坐标）
- (NSArray<TSOCRResult *> *)recognize:(UIImage *)image inRegion:(CGRect)region;

/// 在图像中查找包含指定文字的 OCR 结果
/// @param text  要搜索的文字（支持正则）
/// @param image 截图
/// @return 首个匹配的结果，未找到返回 nil
- (nullable TSOCRResult *)findText:(NSString *)text inImage:(UIImage *)image;

/// 在指定区域查找文字
- (nullable TSOCRResult *)findText:(NSString *)text inImage:(UIImage *)image inRegion:(CGRect)region;

/// 查找所有匹配文字的结果
- (NSArray<TSOCRResult *> *)findAllText:(NSString *)text inImage:(UIImage *)image;

/// 查找并点击文字（组合操作：OCR → 找到坐标 → 触摸点击）
/// @param text  要点击的文字
/// @param image 当前截图
/// @return 是否成功找到并点击
- (BOOL)tapText:(NSString *)text inImage:(UIImage *)image;

@end

NS_ASSUME_NONNULL_END
