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
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSScriptUIViewController : UIViewController

/// 以脚本名创建 (脚本名即网页目录名 /ui/<name>/)
- (instancetype)initWithScriptName:(NSString *)name title:(nullable NSString *)title;

/// 设置页结束回调 (主线程调用): didRun=YES 表示用户点"开始运行", NO 表示点"返回"关闭。
/// 供脚本内 ui.open() 阻塞等待用; 主界面手动打开时可不设置。
@property (nonatomic, copy) void (^onFinish)(BOOL didRun);

@end

NS_ASSUME_NONNULL_END
