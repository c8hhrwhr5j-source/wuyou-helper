//
//  TSHUDWindow.h
//  TrollAutoTouch
//
//  悬浮控制窗(HUD): 可拖动圆形主按钮 + 长按展开控制面板。
//  控制面板包含: 启停脚本 / 录制触控 / 回放 / 缓存截屏 / 拍照 / 设备信息
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 面板操作类型
typedef NS_ENUM(NSInteger, TSHUDAction) {
    TSHUDActionToggleScript,  // 启动/停止脚本
    TSHUDActionRecord,        // 开始/停止录制
    TSHUDActionPlayRecord,    // 回放录制
    TSHUDActionKeepScreen,    // 缓存截屏
    TSHUDActionScreenshot,    // 保存截屏
    TSHUDActionDeviceInfo,    // 设备信息
    TSHUDActionAppTree,       // UI 树
    TSHUDActionStopAll,       // 全部停止
};

/// 操作回调
typedef void(^TSHUDActionBlock)(TSHUDAction action);

@interface TSHUDWindow : UIWindow

+ (instancetype)shared;

/// 显示悬浮窗
- (void)show;
/// 隐藏
- (void)hide;

/// 设置操作回调
- (void)setActionHandler:(TSHUDActionBlock _Nullable)handler;

/// 更新录制按钮状态
- (void)setRecording:(BOOL)recording;

/// 更新脚本运行状态
- (void)setScriptRunning:(BOOL)running;

@end

NS_ASSUME_NONNULL_END
