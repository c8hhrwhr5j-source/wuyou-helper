//
//  HUDCustomAlertView.h
//  TrollAutoTouch
//
//  自绘弹窗视图: 在 TSHUDHost 系统级托管窗口上显示的自定义 UI 弹窗画面,
//  替代系统 UIAlertController。标题/内容/1~N 按钮/超时自动消失,
//  视觉样式完全自控 (深色圆角卡片, 类似游戏内 UI)。
//
//  线程模型: 视图本身在主线程使用; TSHUDHost 负责后台线程阻塞等待。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HUDCustomAlertView : UIView

/// 初始化并布局 (不显示)。
/// buttons 为空数组时: timeout>0 纯自动消失; timeout<=0 自动兜底一个"确定"按钮。
/// resultBlock 在按钮点击/超时时回调: 返回按钮文本, 超时返回 nil。
/// 视图展示结束后会自动从父视图移除。
- (instancetype)initWithTitle:(nullable NSString *)title
                      message:(nullable NSString *)message
                      buttons:(NSArray<NSString *> *)buttons
                      timeout:(NSTimeInterval)timeout
                     onResult:(nullable void (^)(NSString *_Nullable result))resultBlock;

/// 加入父视图后调用: 淡入显示, 并启动超时计时。
- (void)show;

@end

NS_ASSUME_NONNULL_END
