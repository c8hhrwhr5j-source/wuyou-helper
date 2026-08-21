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

/// 预热: 预创建 CAContext (contextId 非零) 供 SBS 系统级托管复用。
/// 解决"冷启动后首次按音量键要按多次才出暂停/运行弹窗"——
/// 首次弹窗才惰性注册托管, 而 _acquireContextId 在 app 刚启动/后台时首次
/// 创建 CAContext 常返回 ctxId=0 → 注册重试又被弹窗"未注册且后台"提前
/// 中止 (活跃内容计数归零), 前几次按键弹窗被静默跳过。
/// App 启动(前台激活)时预热成功后, 首次按键 _acquireContextId 立即返回
/// 非零 ctxId → 托管注册即时完成 → 弹窗秒开。
/// 只预创建 context 不注册托管 (惰性托管不变, 不残留全屏托管窗口吞触摸)。
/// 可任意线程调用, 幂等。
- (void)prepareOverlayContext;

/// 等待 SBS 系统级托管注册完成 (弹窗路径兜底, 阻塞调用)。
/// @param timeout 最长等待秒数
/// @return YES 表示已注册成功 (或已判定彻底失败之外的可显示状态); NO 表示超时
/// 调用前提: 调用前必须已 _bumpActiveContent 且等待期间不 drop,
/// 否则 _registerAccessibilityHostingWithRetryCount: 的 0.5s 重试会因
/// 无活跃内容而中止, 永远注册不上。
- (BOOL)waitForAccessibilityHostingWithTimeout:(NSTimeInterval)timeout;

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

/// 在系统级 HUD 层承载一个全屏 UIViewController (其 view 直接挂到 HUD 内容层)。
/// 用于 App 在后台、游戏等 app 在前台时, ui.open 的网页设置页也能直接弹出
/// 到任意前台 App 之上。非阻塞, 可在任意线程调用 (内部派发主线程挂载)。
/// @param vc 要承载的 view controller, 内部会全屏铺满内容层并触发 appearance 回调
/// @return 是否成功显示; SBS 未托管成功 且 app 不在前台时返回 NO (调用方应视为不可用)
- (BOOL)presentViewControllerInHUD:(UIViewController *)vc;

/// 从 HUD 层移除之前承载的 UIViewController 的 view。
/// 线程安全: 内部派发主线程执行。
- (void)dismissViewControllerFromHUD:(UIViewController *)vc;

/// 当前 HUD 宿主状态描述 (SBS 类可用性 / 是否已注册系统级托管 / 失败标志 / 前后台)。
/// 供诊断日志输出, 避免"已就绪"这类误导性信息。
- (NSString *)registrationStatusDescription;

@end

NS_ASSUME_NONNULL_END
