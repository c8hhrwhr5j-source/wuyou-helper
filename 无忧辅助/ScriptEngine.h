//
//  ScriptEngine.h
//  无忧辅助 - Lua 脚本引擎
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 脚本运行状态
typedef NS_ENUM(NSInteger, ScriptState) {
    ScriptStateIdle = 0,
    ScriptStateRunning,
    ScriptStatePaused,
    ScriptStateStopping,
    ScriptStateError,
};

/// 脚本引擎回调
typedef void (^ScriptLogHandler)(NSString *message);
typedef void (^ScriptStateChangeHandler)(ScriptState newState);

@interface ScriptEngine : NSObject

+ (instancetype)sharedEngine;

/// 当前运行状态
@property (nonatomic, readonly) ScriptState state;

/// 日志回调（Lua 的 log() 输出会通过此 block 发出）
@property (nonatomic, copy, nullable) ScriptLogHandler logHandler;

/// 状态变化回调
@property (nonatomic, copy, nullable) ScriptStateChangeHandler stateChangeHandler;

/// 运行 Lua 脚本代码
- (BOOL)runScript:(NSString *)code;

/// 运行 .lua 文件
- (BOOL)runScriptFile:(NSString *)path;

/// 暂停执行
- (void)pause;

/// 继续执行
- (void)resume;

/// 停止执行
- (void)stop;

/// 获取屏幕尺寸
- (CGSize)screenSize;

/// 获取默认示例脚本
+ (NSString *)defaultScript;

@end

NS_ASSUME_NONNULL_END
