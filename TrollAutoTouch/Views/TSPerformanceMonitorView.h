//
//  TSPerformanceMonitorView.h
//  TrollAutoTouch
//
//  性能监控面板：CPU/MEM/网络 使用率 + sparkline 实时刷新
//

#import <UIKit/UIKit.h>
#import "TSSparklineView.h"

NS_ASSUME_NONNULL_BEGIN

@interface TSPerformanceMonitorView : UIView

- (void)startUpdating;
- (void)stopUpdating;

@end

NS_ASSUME_NONNULL_END