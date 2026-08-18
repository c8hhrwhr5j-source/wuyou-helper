//
//  TSHUDService.h — HUD 全局弹窗服务 (单 App 架构)
//
//  主 App 侧服务入口: 弹窗由 TSHUDHost 在 TrollAutoTouch 进程内完成
//  (自建全屏透明窗口 + SBSAccessibilityWindowHostingController 系统级托管),
//  不再需要独立 HUDServices app 与 CPDistributedMessagingCenter 跨进程通信。
//
//  使用前提: 主 App 拥有 com.apple.springboard.accessibility-window-hosting
//  entitlement (见 TrollAutoTouch.entitlements)。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSHUDService : NSObject

+ (instancetype)sharedInstance;

/// 全局阻塞式弹窗。
/// @param title   标题
/// @param message 内容
/// @param buttons 按钮文本数组(为空数组时: timeout>0 纯自动消失; timeout<=0 自动补"确定")
/// @param timeout 超时秒数 (<=0 表示永久显示直到点击)
/// @return 用户点击的按钮文本; nil 表示超时/宿主不可用
- (nullable NSString *)showAlertWithTitle:(nullable NSString *)title
                                  message:(nullable NSString *)message
                                  buttons:(nullable NSArray<NSString *> *)buttons
                                  timeout:(NSTimeInterval)timeout;

/// 预热 HUD 宿主: 提前创建系统级托管窗口, 使首次弹窗即时可用。
/// App 启动/脚本启动时可调用一次; 幂等。
- (void)warmUp;

@end

NS_ASSUME_NONNULL_END
