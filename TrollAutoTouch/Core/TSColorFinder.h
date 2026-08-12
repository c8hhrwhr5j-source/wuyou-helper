//
//  TSColorFinder.h
//  TrollAutoTouch
//
//  在截屏像素缓冲中查找指定颜色，返回匹配坐标。
//  对应原版 Lua 脚本里的 findColor / getColor / findMultiColor 等能力。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 找色结果
@interface TSColorResult : NSObject
@property (nonatomic, assign) CGPoint point;   // 命中坐标(逻辑点)
@property (nonatomic, assign) int diff;        // 与目标色的差距(0=完全相同)
@end

@interface TSColorFinder : NSObject

/// 取某一点颜色(0xRRGGBB)。pixels=RGBA 缓冲, w/h=像素宽高。
+ (int)getColorAtPoint:(CGPoint)point
                pixels:(const uint8_t *)pixels
                 width:(int)w height:(int)h
            screenSize:(CGSize)screenSize;

/// 在区域内找单色。
/// @param color 目标色 0xRRGGBB
/// @param rect  搜索区域(逻辑点)，CGRectZero 表示整屏
/// @param sim   相似度 0~1 (1=完全相同)
+ (nullable TSColorResult *)findColor:(int)color
                                rect:(CGRect)rect
                           sim:(CGFloat)sim
                             pixels:(const uint8_t *)pixels
                              width:(int)w height:(int)h
                         screenSize:(CGSize)screenSize;

/// 找多色: 以主色定位，主色命中后再校验若干偏移点颜色。
/// @param mainColor 主色 0xRRGGBB
/// @param offsets   偏移点 [{@"x":dx,@"y":dy,@"color":0xRRGGBB}, ...]
+ (nullable TSColorResult *)findMultiColor:(int)mainColor
                                      rect:(CGRect)rect
                                mainColorSim:(CGFloat)sim
                                   offsets:(NSArray<NSDictionary *> *)offsets
                               offsetSim:(CGFloat)offsetSim
                                    pixels:(const uint8_t *)pixels
                                     width:(int)w height:(int)h
                                screenSize:(CGSize)screenSize;

/// 颜色距离(0~195075，0=相同)
+ (int)colorDiffBetween:(int)a and:(int)b;

@end

NS_ASSUME_NONNULL_END
