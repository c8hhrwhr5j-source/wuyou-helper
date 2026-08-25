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

/// 把悬浮球本体中心移动到指定屏幕坐标 (物理屏幕坐标, 不触发贴边动画)。
/// 限制在屏内, 横竖屏自适应。线程安全 (内部派发主线程)。
- (void)setBallPoint:(CGPoint)point;

/// 冷启动控制接口 /float 支持:
/// side=0 靠屏幕左边缘, 1 靠右边缘; yPx 为悬浮球中心垂直位置(物理像素, 按屏幕 scale 换算);
/// yPx < 0 表示把悬浮球移到屏幕外隐藏。线程安全 (内部派发主线程)。
- (void)moveBallToSide:(NSInteger)side verticalPx:(CGFloat)yPx;

@end

NS_ASSUME_NONNULL_END
