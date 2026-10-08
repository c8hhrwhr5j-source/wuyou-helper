//
//  TSNativeSettingsViewController.h
//  TrollAutoTouch
//
//  UIKit 原生设置页 view controller, 与现有 TSScriptUIViewController (HTML
//  WKWebView 设置页) 并存。
//
//  数据契约:
//    - 输入: TSSettingsSchema (解析自 schema.lua 或 ui.openForm 传入的 table)
//    - 初始值: /var/mobile/touch/lua/<scriptName>.settings.json 存在则读入, 否则用 schema 的 defaultValue
//    - 保存: 写回同一文件, 格式与 HTML 设置页完全兼容 (NSDictionary -> JSON)
//    - onFinish(didRun): 与 HTML 版完全相同, 上层 l_ui_open 据此决定是注入 settings 后
//      启动脚本, 还是直接返回 false
//
//  样式: 独立设计, 不复用任何 HTML/WKWebView 资源, 与现有 TSScriptUIViewController
//  完全隔离。Apple HIG 风格的 UITableView 分组列表。
//

#import <UIKit/UIKit.h>
#import "TSSettingsSchema.h"

NS_ASSUME_NONNULL_BEGIN

@interface TSNativeSettingsViewController : UIViewController

- (instancetype)initWithSchema:(TSSettingsSchema *)schema;

/// 设置页结束回调 (主线程): didRun=YES 表示用户点"保存运行", NO 表示点"保存"或"取消"。
/// 供脚本内 ui.open() 阻塞等待用。
@property (nonatomic, copy) void (^onFinish)(BOOL didRun);

/// 是否由网页"取消"按钮触发关闭 (只读)
@property (nonatomic, readonly) BOOL cancelRequested;

/// HUD 承载模式: YES 表示该页面由 TSHUDHost 系统级层承载 (App 在后台、
/// 游戏等 app 在前台时 ui.open 弹出), 关闭时从 HUD 层移除 view。
@property (nonatomic, assign) BOOL hostedInHUD;

@end

NS_ASSUME_NONNULL_END
