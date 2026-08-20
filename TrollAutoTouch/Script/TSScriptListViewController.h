//
//  TSScriptListViewController.h
//  TrollAutoTouch
//
//  脚本列表 — 配置标签页，显示 .lua/.tas 脚本文件
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSScriptListViewController : UIViewController

// ── 选中脚本 (音量键快速运行 / 列表勾选显示) ──
// 持久化到 NSUserDefaults, 重启 App 后保持上次选中状态。
// name 为纯文件名 (如 "farm.lua"), 空串表示未选中。
+ (NSString *)selectedScriptName;
+ (void)setSelectedScriptName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END