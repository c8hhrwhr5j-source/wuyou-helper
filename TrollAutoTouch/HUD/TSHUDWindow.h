//
//  TSHUDWindow.h
//  TrollAutoTouch
//
//  悬浮窗: 悬浮球 + 向左展开的快捷按钮组 (暂停/恢复、启动/停止、关闭)
//  所有按钮仅图标, 不显示文字。点击悬浮球本体可展开/收回按钮组。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TSHUDAction) {
    TSHUDActionPause        = 0, // 暂停/恢复当前 Lua 脚本
    TSHUDActionToggleScript = 1, // 启动/停止当前选中的 Lua 脚本
    TSHUDActionClose        = 2, // 关闭悬浮球
};

@interface TSHUDWindow : UIWindow

@property (nonatomic, copy, nullable) void (^actionHandler)(TSHUDAction action);

/// 是否正在录制 (无录制按钮, 保留属性以防旧调用)
@property (nonatomic, assign) BOOL recording;

+ (instancetype)shared;
- (void)show;
- (void)hide;
- (void)setScriptRunning:(BOOL)running;

@end

NS_ASSUME_NONNULL_END
