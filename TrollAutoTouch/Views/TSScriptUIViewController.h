//
//  TSScriptUIViewController.h
//  TrollAutoTouch
//
//  脚本网页设置 UI 容器: 全屏 WKWebView 显示脚本的网页设置页
//  (http://127.0.0.1:<port>/ui/<name>/index.html)。
//
//  约定 (参照 AutoJS resources/ui 风格):
//    脚本:     /var/mobile/touch/lua/<name>.lua
//    设置页:   /var/mobile/touch/lua/ui/<name>/index.html (设备, 优先)
//              或 bundle www/ui/<name>/index.html (内置示例)
//    设置数据: /var/mobile/touch/lua/<name>.settings.json (网页经 HTTP API 读写)
//    运行:     网页 POST /api/ui/run → 服务器保存设置并发通知 →
//              本控制器自动关闭, 主界面启动脚本
//    取消:     网页 POST /api/ui/cancel → 服务器发通知 →
//              本控制器停止当前脚本并关闭设置页
//
//  注: 本容器为全屏无导航栏模式, 左上角不带返回按钮;
//      关闭/取消统一由网页底部"取消"按钮触发。

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSScriptUIViewController : UIViewController

/// 以脚本名创建 (脚本名即网页目录名 /ui/<name>/)
- (instancetype)initWithScriptName:(NSString *)name title:(nullable NSString *)title;

/// 设置页结束回调 (主线程调用): didRun=YES 表示用户点"保存运行", NO 表示点"取消"关闭。
/// 供脚本内 ui.open() 阻塞等待用; 主界面手动打开时可不设置。
@property (nonatomic, copy) void (^onFinish)(BOOL didRun);

/// 是否由网页"取消"按钮触发关闭 (只读, 供脚本内 ui.open() 判断是否已自行关闭)。
@property (nonatomic, readonly) BOOL cancelRequested;

/// HUD 承载模式: YES 表示该页面由 TSHUDHost 系统级层承载 (App 在后台、
/// 游戏等 app 在前台时 ui.open 弹出), 其 view 直接挂到 HUD 内容层而不是
/// 被 present。关闭时直接从 HUD 层移除 view, 不再走 dismissViewControllerAnimated:。
@property (nonatomic, assign) BOOL hostedInHUD;

@end

NS_ASSUME_NONNULL_END
