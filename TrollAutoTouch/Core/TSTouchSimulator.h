//
//  TSTouchSimulator.h
//  TrollAutoTouch
//
//  高层自动化门面: 把"截屏 + 找色 + 触摸"组合成易用 API。
//  对应原版脚本里 findColor + tap 的常用组合。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSTouchSimulator : NSObject

+ (instancetype)shared;

/// 在整屏找色并点击。点击相对命中点偏移 (offsetX,offsetY)。
/// @return 是否找到并点击
- (BOOL)tapColor:(int)color sim:(CGFloat)sim
      offsetX:(CGFloat)offsetX offsetY:(CGFloat)offsetY;

/// 在区域内找色并点击
- (BOOL)tapColor:(int)color sim:(CGFloat)sim
            rect:(CGRect)rect
        offsetX:(CGFloat)offsetX offsetY:(CGFloat)offsetY;

/// 找多色并点击
- (BOOL)tapMultiColor:(int)mainColor
                rect:(CGRect)rect
          mainColorSim:(CGFloat)sim
               offsets:(NSArray<NSDictionary *> *)offsets
             offsetSim:(CGFloat)offsetSim
               offsetX:(CGFloat)offsetX offsetY:(CGFloat)offsetY;

/// 原语: 截屏
- (BOOL)capture:(uint8_t *_Nullable *_Nullable)pixels width:(int *)w height:(int *)h;
/// 原语: 点击
- (void)tapAt:(CGPoint)point;
/// 原语: 滑动
- (void)swipeFrom:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)d;

@end

NS_ASSUME_NONNULL_END
