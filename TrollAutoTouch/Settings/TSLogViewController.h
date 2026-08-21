//
//  TSLogViewController.h
//  TrollAutoTouch
//
//  运行日志查看页 —— 显示全局日志存储(TSLogStore)内容。
//  按来源分两个页面: "脚本日志"(main.lua 主动 log/logStr/print, debug.log)
//  与 "系统日志"(程序自身日志, touch.log), 界面清晰区分来源。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSLogViewController : UIViewController

/// 日志来源模式:
///   @"script" = 脚本日志 (main.lua 主动 log/logStr/print, 来源 debug.log)
///   @"system" = 系统日志 (程序自身日志, 来源 touch.log)
/// 默认 @"system"。
- (instancetype)initWithMode:(NSString *)mode;

@end

NS_ASSUME_NONNULL_END
