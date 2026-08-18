//
//  TSHUDService.h — HUD 全局弹窗服务 (方案 B)
//
//  主 App 侧客户端: 负责部署/启动隐藏的 HUDServices 独立 app,
//  并通过 CPDistributedMessagingCenter 请求它在任意前台 app 之上
//  弹出系统风格对话框 (sys.alert / sys.alertButtons 的全局版本)。
//
//  使用前提: TrollAutoScript.app/HUD/HUDServices.app 随主包分发,
//  且主 App 拥有 MobileInstallation / LaunchServices / SpringBoard 权限
//  (见 TrollAutoTouch.entitlements)。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSHUDService : NSObject

+ (instancetype)sharedInstance;

/// 全局阻塞式弹窗。
/// @param title   标题
/// @param message 内容
/// @param buttons 按钮文本数组(为空时 HUD 侧默认显示"确定")
/// @param timeout 超时秒数 (<=0 表示永久显示直到点击)
/// @return 用户点击的按钮文本; nil 表示超时/用户取消/HUD 不可用
- (nullable NSString *)showAlertWithTitle:(nullable NSString *)title
                                  message:(nullable NSString *)message
                                  buttons:(nullable NSArray<NSString *> *)buttons
                                  timeout:(NSTimeInterval)timeout;

/// HUD 是否已安装
- (BOOL)isHUDInstalled;

/// 确保 HUD 服务可用 (TrollStore 多 app tipa 已随包注册时直接复用;
/// 老设备/越狱且 MobileInstallation 权限生效时回退现场安装)
- (BOOL)installHUD;

/// 启动 HUD 服务 (若未运行)
- (BOOL)ensureHUDRunning;

@end

NS_ASSUME_NONNULL_END
