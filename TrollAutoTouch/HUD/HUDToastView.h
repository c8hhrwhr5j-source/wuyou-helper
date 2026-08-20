//
//  HUDToastView.h
//  TrollAutoTouch
//
//  自绘 toast 浮层视图: 在 TSHUDHost 系统级托管窗口上显示的短提示卡片
//  (原版 TrollAutoScript HUDServices/BLToastView 的等效实现)。
//  无遮罩、不拦截触摸, 淡入显示后到时自动淡出移除, 全程非阻塞。
//
//  线程模型: 视图本身在主线程使用; TSHUDHost 负责从任意线程派发到主线程。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HUDToastView : UIView

/// 初始化并布局 (不显示)。
/// @param text     提示文本 (可多行)
/// @param duration 显示时长(秒), 到时自动淡出
/// @param hidden   弱化模式: YES 时用顶部小字半透明样式,
///                 尽量不占用屏幕中部找色区域 (原版 sys.toast 的"是否隐藏"语义)
- (instancetype)initWithText:(NSString *)text
                    duration:(NSTimeInterval)duration
                      hidden:(BOOL)hidden;

/// 按容器尺寸(宿主内容层, 旋转后宽高已交换)布局。
/// 主线程调用; 加入容器后也可随时重排。
- (void)layoutInContainerSize:(CGSize)size;

/// 加入父视图后调用: 淡入显示, 启动到时淡出计时。
- (void)show;

@end

NS_ASSUME_NONNULL_END
