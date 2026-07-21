/**
 *  ScriptEngine.h
 *  Lua 5.4 虚拟机封装 — 脚本生命周期管理
 *
 *  单例模式，全应用共享一个 lua_State
 *  运行在后台线程，避免阻塞 UI
 */

#import <Foundation/Foundation.h>

/// 脚本运行状态
typedef NS_ENUM(NSInteger, ScriptState) {
    ScriptStateIdle,      // 空闲
    ScriptStateRunning,   // 运行中
    ScriptStatePaused,    // 已暂停
    ScriptStateStopping,  // 正在停止
};

/// 脚本日志回调
typedef void (^ScriptLogHandler)(NSString *message);
/// 状态变更回调
typedef void (^ScriptStateHandler)(ScriptState state);

@interface ScriptEngine : NSObject

@property (nonatomic, readonly) ScriptState state;
@property (nonatomic, copy) ScriptLogHandler logHandler;
@property (nonatomic, copy) ScriptStateHandler stateChangeHandler;

+ (instancetype)shared;

/// 初始化 Lua 虚拟机并注册原生函数
- (BOOL)initialize;

/// 从字符串执行脚本
- (BOOL)runScript:(NSString *)luaCode;

/// 从文件路径加载并执行脚本
- (BOOL)runScriptFile:(NSString *)path;

/// 暂停脚本执行
- (void)pause;

/// 恢复脚本执行
- (void)resume;

/// 强制停止脚本
- (void)stop;

/// 销毁 Lua 虚拟机，释放资源
- (void)destroy;

/// 获取屏幕尺寸 (width, height)
- (CGSize)getScreenSize;

@end
