//
//  HUDAlertPresenter.h
//  HUDServices
//
//  负责在高 windowLevel 的窗口上展示 UIAlertController。
//  该方法为阻塞式调用(需在后台线程调用), 返回用户点击的按钮文本;
//  若设置了 timeout 且超时未点击, 自动消失并返回 nil。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HUDAlertPresenter : NSObject

/// presenter: 用于 present alert 的 UIViewController (通常为窗口的 rootViewController)
- (instancetype)initWithPresenter:(UIViewController *)presenter;

/// 阻塞式展示对话框。后台线程调用, 返回点击的按钮文本或 nil(超时)。
/// buttons 为空时默认显示"确定"。
- (nullable NSString *)presentAlertWithTitle:(nullable NSString *)title
                                     message:(nullable NSString *)message
                                     buttons:(nullable NSArray<NSString *> *)buttons
                                     timeout:(NSTimeInterval)timeout;

/// 阻塞式展示自绘弹窗 (HUDCustomAlertView, 替代系统 UIAlertController)。
/// 视觉为深色圆角卡片, 覆盖全屏; 语义与 presentAlertWithTitle: 完全一致:
/// 后台线程调用, 返回点击的按钮文本或 nil(超时自动消失)。
/// buttons 为空时: timeout>0 纯自动消失, timeout<=0 补"确定"按钮。
- (nullable NSString *)presentCustomAlertWithTitle:(nullable NSString *)title
                                           message:(nullable NSString *)message
                                           buttons:(nullable NSArray<NSString *> *)buttons
                                           timeout:(NSTimeInterval)timeout;

@end

NS_ASSUME_NONNULL_END
