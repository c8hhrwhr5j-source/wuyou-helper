//
//  TSDaemonManager.h
//  TrollAutoTouch
//
//  后台守护服务管理器 —— 对应原版 HUDServices 后台进程。
//
//  功能:
//   - 后台保活(音频/定位模式)
//   - 系统级悬浮窗管理
//   - 通知中心挂件
//   - 启动时自动恢复服务
//
//  用法:
//    [[TSDaemonManager shared] startAll];
//    [[TSDaemonManager shared] showHUD];
//    [[TSDaemonManager shared] hideHUD];
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 后台守护状态
typedef NS_ENUM(NSInteger, TSDaemonState) {
    TSDaemonStateStopped = 0,
    TSDaemonStateStarting,
    TSDaemonStateRunning,
    TSDaemonStateBackground,
};

@interface TSDaemonManager : NSObject

+ (instancetype)shared;

/// 当前守护状态
@property (nonatomic, readonly) TSDaemonState state;

/// 是否在后台运行
@property (nonatomic, readonly) BOOL isInBackground;

/// 后台运行剩余时间(秒)
@property (nonatomic, readonly) NSTimeInterval backgroundTimeRemaining;

/// 启动所有后台服务
- (void)startAll;

/// 停止所有后台服务
- (void)stopAll;

/// 显示系统级悬浮窗
- (void)showHUD;

/// 隐藏系统级悬浮窗
- (void)hideHUD;

/// HUD 是否可见
- (BOOL)isHUDVisible;

/// 注册后台任务(延长后台存活)
- (void)beginBackgroundTask;

/// 结束后台任务
- (void)endBackgroundTask;

/// 播放静默音频保持后台存活
- (void)startSilentAudio;

/// 停止静默音频
- (void)stopSilentAudio;

/// 发送本地通知
- (void)postLocalNotification:(NSString *)title body:(NSString *)body;

@end

NS_ASSUME_NONNULL_END
