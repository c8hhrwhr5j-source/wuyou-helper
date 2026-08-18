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

@end

NS_ASSUME_NONNULL_END
