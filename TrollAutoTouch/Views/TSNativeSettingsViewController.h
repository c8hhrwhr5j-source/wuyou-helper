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

/// HUD 承载模式下表单的方向偏好 (前台 present 模式不生效, 跟随 app 方向)。
/// 设置 formOrientation 后, TSHUDHost 在 _attachVCToHUD 阶段会对表单 view
/// 应用反旋转 (inverse transform), 让表单视觉上呈现指定方向而不被 HUD 内容层
/// 旋转带偏。
typedef NS_ENUM(NSInteger, TSNativeFormOrientation) {
    /// 默认: 跟随脚本坐标系 (screen.init 设的方向) / 跟随前台 app。
    /// HUD 承载下表单继承内容层的旋转 (横屏游戏中横屏显示)。
    TSNativeFormOrientationAuto = 0,
    /// 强制竖屏。HUD 内容层在横屏时, 表单 view 应用 -host.transform,
    /// 视觉上始终竖屏呈现 (适合: 横屏游戏中希望用竖屏表单看完整列表)。
    TSNativeFormOrientationPortrait = 1,
    /// 强制横屏。HUD 内容层在竖屏时, 表单 view 旋转 +90°,
    /// 视觉上始终横屏呈现 (适合: 竖屏游戏中希望宽表单填屏)。
    TSNativeFormOrientationLandscape = 2,
};

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

/// 表单方向偏好 (HUD 承载模式生效)。默认 TSNativeFormOrientationAuto。
/// 仅在 HUD 承载下由 TSHUDHost 读取并应用反旋转;
/// 前台 present 时此属性被忽略 (跟随 TrollAutoTouch app 方向)。
/// 设为 TSNativeFormOrientationPortrait / Landscape 后, 关闭表单时此属性
/// 不影响 HUD 内容层的旋转 (那是 screen.init 控制的)。
@property (nonatomic, assign) TSNativeFormOrientation formOrientation;

/// 自动关闭时间 (秒)。默认 0 = 不自动关闭。
/// > 0 时表单加载后启动倒计时, 归零自动触发 "运行" 流程 (保存设置 + 启动脚本)。
/// 倒计时期间用户可随时点 "取消" (停止脚本 + 关闭表单) 或 "运行" (立即结束倒计时)。
/// 0 时不显示倒计时标签, 行为与历史一致 (用户必须手动点按钮)。
/// 典型用法: 30 (梦幻西游脚本兜底配置时弹表单, 30s 未操作按当前设置继续)。
@property (nonatomic, assign) NSTimeInterval autoCloseAfter;

@end

NS_ASSUME_NONNULL_END
