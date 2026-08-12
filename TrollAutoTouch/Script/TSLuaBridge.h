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

/// 当前正在运行的脚本完整路径(nil 表示未在运行)
@property (nonatomic, copy, nullable) NSString *runningPath;

/// 在后台线程执行 Lua 脚本文件
- (void)runFile:(NSString *)path;

/// 在后台线程执行 Lua 代码字符串
- (void)runString:(NSString *)code;

/// 请求停止当前脚本(脚本下一次调用 mSleep/sleep 时抛出错误中断)
- (void)stop;

@end

NS_ASSUME_NONNULL_END
