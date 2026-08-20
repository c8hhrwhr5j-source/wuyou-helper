//
//  TSHUDHost.h
//  TrollAutoTouch
//
//  进程内 HUD 宿主 (单 App 架构):
//  合并自原 HUDServices 独立 app 的全局弹窗能力, 在主 App 进程内
//  自建全屏透明窗口并注册到 SpringBoard 的 accessibility window hosting,
//  从而在任意前台 App 之上显示全局弹窗 (音量键菜单/脚本阻塞确认等)。
//
//  与旧双 App 架构的区别: 不再需要独立 HUDServices.app、CPDistributedMessagingCenter
//  跨进程消息、TrollStore 多 app 安装。HUD 弹窗随主 App 进程存在,
//  桌面只显示 TrollAutoTouch 一个图标。
//
//  线程模型: presentAlertWithTitle: 为阻塞式调用 (可在任意线程调用),
//  内部把视图展示派发到主线程, 用信号量等待用户点击/超时后返回按钮文本。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSHUDHost : NSObject

/// 单例。App 启动时调用一次 start 即可创建窗口并注册系统级托管。
+ (instancetype)shared;

/// 启动 HUD 宿主: 创建全屏透明窗口, 延迟注册 SBS accessibility 托管。
/// 幂等, 可重复调用。
- (void)start;

/// 全局阻塞式弹窗: 在任意前台 App 之上显示自绘弹窗, 等待用户点击或超时。
/// @param title   弹窗标题, 可为空
/// @param message 弹窗内容
/// @param buttons 按钮文本数组; 空数组 + timeout<=0 时自动兜底一个"确定"按钮;
///                空数组 + timeout>0 时纯自动消失
/// @param timeout 超时秒数; <=0 表示永久显示直到点击
/// @return 用户点击的按钮文本; 超时/宿主不可用时返回 nil
- (nullable NSString *)presentAlertWithTitle:(nullable NSString *)title
                                     message:(nullable NSString *)message
                                     buttons:(nullable NSArray<NSString *> *)buttons
                                     timeout:(NSTimeInterval)timeout;

/// 全局非阻塞 toast: 在任意前台 App 之上短暂显示一条提示, 到时自动消失。
/// 不阻塞调用线程 (异步派发主线程), 且不拦截任何触摸
/// (toast 卡片 userInteractionEnabled=NO, 命中即穿透)。
/// @param text     提示文本
/// @param duration 显示时长(秒); <=0 时用默认 1 秒
/// @param hidden   弱化模式: YES 时用屏幕顶部小字样式, 尽量不占用
///                 屏幕中部找色区域 (对应原版 sys.toast 的"是否隐藏"语义)
- (void)showToast:(NSString *)text
         duration:(NSTimeInterval)duration
           hidden:(BOOL)hidden;

/// 设置脚本坐标系方向 (对应 Lua screen.init): 0=竖屏(home在下) 1=横屏(home在右) 2=横屏(home在左)。
/// HUD 弹窗/toast 内容层随之旋转, 与脚本坐标系保持一致 (横屏游戏时弹窗横屏显示)。
/// 线程安全: 内部派发主线程应用。
- (void)setScriptOrientation:(NSInteger)orientation;

/// 当前脚本方向下的 HUD 内容层布局尺寸 (旋转后宽高已交换, 主线程读取)。
/// 供弹窗/toast 在旋转坐标系下布局使用。
- (CGSize)scriptContentSize;

/// 当前 HUD 宿主状态描述 (SBS 类可用性 / 是否已注册系统级托管 / 失败标志 / 前后台)。
/// 供诊断日志输出, 避免"已就绪"这类误导性信息。
- (NSString *)registrationStatusDescription;

@end

NS_ASSUME_NONNULL_END
