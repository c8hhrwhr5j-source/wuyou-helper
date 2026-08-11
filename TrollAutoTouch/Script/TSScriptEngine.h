//
//  TSScriptEngine.h
//  TrollAutoTouch
//
//  轻量行式 DSL 脚本引擎。
//  Lua 模式见 TSLuaBridge.h, 默认使用内置 DSL(无需外部依赖)。
//
//  使用方式:
//   1) TSScriptEngine DSL (本文件) — 推荐，零依赖
//       [[TSScriptEngine shared] runFile:path delegate:self];
//   2) Lua 模式 — 需引入 Lua 5.4 源码
//       [[TSLuaBridge shared] runFile:path];
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 日志代理
@protocol TSLogDelegate <NSObject>
- (void)log:(NSString *)message;
@end

/// 日志回调 Block (向后兼容)
typedef void(^TSScriptLogHandler)(NSString *line);

@interface TSScriptEngine : NSObject

+ (instancetype)shared;

/// 日志回调(向后兼容，新代码请用 delegate)
@property (nonatomic, copy, nullable) TSScriptLogHandler logHandler;

#pragma mark - 新 API (推荐)

/// 运行脚本文件
- (void)runFile:(NSString *)path delegate:(nullable id<TSLogDelegate>)delegate;

/// 运行脚本字符串
- (void)runString:(NSString *)code delegate:(nullable id<TSLogDelegate>)delegate;

/// 暂停
- (void)pause;

/// 恢复
- (void)resume;

/// 停止
- (void)stop;

/// 是否正在运行
@property (nonatomic, readonly) BOOL isRunning;

@end

NS_ASSUME_NONNULL_END
