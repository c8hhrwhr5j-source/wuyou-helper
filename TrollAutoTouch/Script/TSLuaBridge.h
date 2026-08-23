//
//  TSLuaBridge.h
//  TrollAutoTouch
//
//  Lua 脚本引擎桥接 —— 对齐原版 TrollAutoScript 的 Lua 脚本 API。
//
//  原版 TrollAutoScript 用 Lua 5.x + 原生 .so 扩展作为脚本层，
//  本类嵌入 Lua 5.4 并注册了原版 TouchScript 风格的全局函数:
//    findColor / findColors / findImage / getColor
//    tap / touchDown / touchMove / touchUp / swipe / stroke
//    snapshot / keepScreen / getScreenSize
//    mSleep / logStr / toast
//  以及命名模块: touch / screen / sys / device / json / appNode / app
//    pasteboard / plist / file / key / str
//
//  用法:
//    TSLuaBridge *lua = [TSLuaBridge shared];
//    lua.logHandler = ^(NSString *s){ NSLog(@"%@", s); };
//    [lua runFile:path];   // 后台线程执行
//    [lua stop];           // 请求停止(脚本下一次 mSleep 时中断)

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 脚本运行状态变化通知（userInfo: @{@"running": @(BOOL), @"path": NSString?}）
FOUNDATION_EXPORT NSNotificationName const TSLuaRunningStateChangedNotification;

@interface TSLuaBridge : NSObject

+ (instancetype)shared;

/// 脚本运行日志回调(主线程)
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *message);

/// 是否正在运行脚本
@property (nonatomic, assign) BOOL isRunning;

/// 是否处于暂停状态(仅脚本运行中有效)
@property (nonatomic, assign) BOOL isPaused;

/// 当前正在运行的脚本完整路径(nil 表示未在运行)
@property (nonatomic, copy, nullable) NSString *runningPath;

/// 在后台线程执行 Lua 脚本文件
- (void)runFile:(NSString *)path;

/// 在后台线程执行 Lua 代码字符串
- (void)runString:(NSString *)code;

/// 请求停止当前脚本(脚本下一次调用 mSleep/sleep 时抛出错误中断)
- (void)stop;

/// 暂停当前脚本(线程阻塞在指令钩子/mSleep 处, 可随时 resume 或 stop)
- (void)pause;

/// 恢复被 pause 暂停的脚本
- (void)resume;

// ── 常驻音量键监听 (TAS 服务开启时由 App 启动调用) ──
/// 启动常驻音量键轮询。统一在 -_handleVolumeKey 内按运行状态分流:
///   脚本运行中 → 控制菜单(暂停/停止/注入); 空闲 → 弹"运行脚本/取消"选择。
- (void)startGlobalVolumeMonitoring;

/// 停止常驻音量键轮询 (TAS 服务关闭时调用)。
- (void)stopGlobalVolumeMonitoring;

@end

NS_ASSUME_NONNULL_END
