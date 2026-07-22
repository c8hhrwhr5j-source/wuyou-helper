//
//  ScriptEngine.m
//  无忧辅助 - Lua 脚本引擎实现
//

#import "ScriptEngine.h"
#import "LuaBridge.h"
#import "ScreenCapture.h"
#import "TouchSimulation.h"
#import <UIKit/UIKit.h>

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

// ---- lua_sethook 是 C 回调，必须用 C 全局变量 ----
// _global_script_stop_flag 与 LuaBridge.m 共享，
// 这样 Lua 的 stop_script() 和 UI 停止按钮都能生效
extern volatile int _global_script_stop_flag;
static volatile BOOL   _globalPaused  = NO;
static UIBackgroundTaskIdentifier _bgTask = UIBackgroundTaskInvalid;
static NSCondition    *_globalPauseCondition = nil;

// lua_sethook 回调（每条 Lua 指令后触发，纯 C）
static void lua_hook_callback(lua_State *L, lua_Debug *ar) {
    (void)ar;
    // 暂停检查
    if (_globalPaused) {
        [_globalPauseCondition lock];
        while (_globalPaused && !_global_script_stop_flag) {
            [_globalPauseCondition wait];
        }
        [_globalPauseCondition unlock];
    }

    // 停止检查
    if (_global_script_stop_flag) {
        luaL_error(L, "script stopped by user");
    }
}

@interface ScriptEngine () {
    lua_State *_luaState;
    NSThread *_executionThread;
}
@end

@implementation ScriptEngine

+ (instancetype)sharedEngine {
    static ScriptEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ScriptEngine alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _state = ScriptStateIdle;
        _luaState = NULL;
        _globalPauseCondition = [[NSCondition alloc] init];
        _globalPaused = NO;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

// MARK: - 公开接口

- (BOOL)runScript:(NSString *)code {
    if (_state == ScriptStateRunning || _state == ScriptStatePaused) {
        [self _log:@"脚本已在运行中，请先停止"];
        return NO;
    }
    if (!code || code.length == 0) {
        [self _log:@"脚本代码为空"];
        return NO;
    }

    // 开启后台任务，防止进入后台后线程被挂起
    if (_bgTask == UIBackgroundTaskInvalid) {
        _bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"LuaScript" expirationHandler:^{
            // 系统即将结束时清理
            if (_bgTask != UIBackgroundTaskInvalid) {
                [[UIApplication sharedApplication] endBackgroundTask:_bgTask];
                _bgTask = UIBackgroundTaskInvalid;
            }
        }];
        NSLog(@"[ScriptEngine] Background task started: %lu", (unsigned long)_bgTask);
    }

    [self _setState:ScriptStateRunning];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [weakSelf _executeCode:code];
    });

    return YES;
}

- (BOOL)runScriptFile:(NSString *)path {
    NSError *error = nil;
    NSString *code = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:&error];
    if (error || !code) {
        [self _log:[NSString stringWithFormat:@"读取文件失败: %@", error.localizedDescription]];
        [self _setState:ScriptStateError];
        return NO;
    }
    return [self runScript:code];
}

- (void)pause {
    if (_state != ScriptStateRunning) return;
    [_globalPauseCondition lock];
    _globalPaused = YES;
    [_globalPauseCondition unlock];
    [self _setState:ScriptStatePaused];
}

- (void)resume {
    if (_state != ScriptStatePaused) return;
    [_globalPauseCondition lock];
    _globalPaused = NO;
    [_globalPauseCondition signal];
    [_globalPauseCondition unlock];
    [self _setState:ScriptStateRunning];
}

- (void)stop {
    if (_state == ScriptStateIdle || _state == ScriptStateStopping) return;

    [self _setState:ScriptStateStopping];
    _global_script_stop_flag = 1;

    [_globalPauseCondition lock];
    _globalPaused = NO;
    [_globalPauseCondition signal];
    [_globalPauseCondition unlock];
}

- (CGSize)screenSize {
    // 使用 nativeBounds 获取实际像素尺寸（与触控精灵一致）
    return [[UIScreen mainScreen] nativeBounds].size;
}

+ (NSString *)defaultScript {
    return
        @"-- 无忧辅助 Lua 示例脚本\n"
        @"-- 可用函数: log(), sleep(), click(), hold(), swipe()\n"
        @"--           get_screen_color(), find_color(), get_resolution()\n"
        @"--           stop_script()\n"
        @"\n"
        @"function main()\n"
        @"    log(\"=== 脚本开始 ===\")\n"
        @"    \n"
        @"    -- 获取屏幕分辨率\n"
        @"    local w, h = get_resolution()\n"
        @"    log(string.format(\"屏幕: %d x %d\", w, h))\n"
        @"    \n"
        @"    -- 取屏幕中心点的颜色\n"
        @"    local r, g, b = get_screen_color(w / 2, h / 2)\n"
        @"    log(string.format(\"中心颜色: RGB(%d,%d,%d)\", r, g, b))\n"
        @"    \n"
        @"    -- 延时\n"
        @"    sleep(500)\n"
        @"    \n"
        @"    -- 点击屏幕中心\n"
        @"    -- click(w / 2, h / 2)\n"
        @"    \n"
        @"    log(\"=== 脚本结束 ===\")\n"
        @"end\n"
        @"\n"
        @"main()\n";
}

// MARK: - 内部实现

- (BOOL)_executeCode:(NSString *)code {
    _global_script_stop_flag = 0;
    _globalPaused  = NO;

    // 创建 Lua VM
    _luaState = luaL_newstate();
    if (!_luaState) {
        [self _log:@"创建 Lua VM 失败"];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _setState:ScriptStateError];
        });
        return NO;
    }

    // 加载标准库
    luaL_openlibs(_luaState);

    // 注册自定义函数
    lua_register_bridge_functions(_luaState);

    // 设置日志回调（ScriptEngine 是单例，用强引用避免 weakSelf 变 nil 丢日志）
    lua_set_log_callback(_luaState, ^(NSString *msg) {
        [self _log:msg];
    });

    // 把日志回调也注入到 TouchSimulation，确保触控诊断日志可见
    [TouchSimulation sharedInstance].logHandler = ^(NSString *msg) {
        [self _log:msg];
    };
    [[TouchSimulation sharedInstance] logDiagnostic];

    // 设置指令钩子（用于暂停/停止检测，每 10000 条指令触发一次，与触控精灵一致）
    lua_sethook(_luaState, lua_hook_callback, LUA_MASKCOUNT, 10000);

    // 执行脚本（与触控精灵一致：最简 lua_pcall，不带 debug.traceback 错误处理）
    int status = luaL_loadstring(_luaState, [code UTF8String]);
    if (status == LUA_OK) {
        [self _log:@"[ScriptEngine] 开始执行 main()"];
        status = lua_pcall(_luaState, 0, 0, 0);
        // 只有非手动停止时才打印"已返回"
        if (!_global_script_stop_flag) {
            [self _log:@"[ScriptEngine] main() 已返回"];
        }
    }

    if (status != LUA_OK) {
        // 手动停止导致的 luaL_error 不当作错误
        if (_global_script_stop_flag) {
            lua_pop(_luaState, 1);
        } else {
            const char *err = lua_tostring(_luaState, -1);
            NSString *errMsg = err ? [NSString stringWithUTF8String:err] : @"未知错误";
            NSString *phase = (status == LUA_ERRSYNTAX) ? @"语法错误" :
                              (status == LUA_ERRMEM) ? @"内存不足" :
                              (status == LUA_ERRRUN) ? @"运行时错误" :
                              (status == LUA_ERRERR) ? @"错误处理错误" : @"未知错误";
            [self _log:[NSString stringWithFormat:@"脚本错误 [%@]: %@", phase, errMsg]];
            lua_pop(_luaState, 1);
        }
    }

    // 清理
    lua_close(_luaState);
    _luaState = NULL;

    // 结束后台任务
    if (_bgTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:_bgTask];
        _bgTask = UIBackgroundTaskInvalid;
        NSLog(@"[ScriptEngine] Background task ended");
    }

    // 更新状态
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_global_script_stop_flag && self->_state != ScriptStateError) {
            [self _setState:ScriptStateIdle];
        } else if (status != LUA_OK) {
            [self _setState:ScriptStateError];
        } else {
            [self _setState:ScriptStateIdle];
        }
    });

    return status == LUA_OK;
}

- (void)_log:(NSString *)message {
    NSLog(@"[Lua] %@", message);
    if (self.logHandler) {
        self.logHandler(message);
    }
}

- (void)_setState:(ScriptState)newState {
    _state = newState;
    if (self.stateChangeHandler) {
        self.stateChangeHandler(newState);
    }
}

@end
