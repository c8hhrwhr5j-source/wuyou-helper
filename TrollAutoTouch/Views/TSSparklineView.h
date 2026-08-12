//
//  TSSparklineView.h
//  TrollAutoTouch
//
//  迷你折线图 —— 用于性能监控面板的 CPU/MEM/网络 sparkline
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSSparklineView : UIView

/// 数据点 (0.0~1.0)
@property (nonatomic, copy) NSArray<NSNumber *> *values;
/// 线条颜色
@property (nonatomic, strong) UIColor *strokeColor;
/// 渐变填充颜色 (nil 则无填充)
@property (nonatomic, strong, nullable) UIColor *fillColor;
/// 柱状模式 (用于 MEM 显示)
@property (nonatomic, assign) BOOL barMode;

- (void)appendValue:(CGFloat)v;

@end

NS_ASSUME_NONNULL_END