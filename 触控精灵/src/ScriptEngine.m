/**
 *  ScriptEngine.m
 *  Lua 5.4 虚拟机生命周期管理 + 脚本执行引擎
 *
 *  后台线程执行，支持暂停/继续/停止
 *  注意: lua_sethook 要求纯 C 函数指针，不用 ObjC block 或 C++ lambda
 */

#import "ScriptEngine.h"
#import "LuaBridge.h"
#import "ScreenCapture.h"
#import "TouchSimulation.h"

// ---- Lua 头文件 ----
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

// ---- lua_sethook 是 C 回调，必须用 C 全局变量 ----
// _global_script_stop_flag 与 LuaBridge.m 共享，
// 这样 Lua 的 stop_script() 和 UI 停止按钮都能生效
extern volatile int _global_script_stop_flag;
static volatile BOOL   _globalPaused  = NO;
static NSCondition    *_globalPauseCondition = nil;

// ---- 前置声明 ----
static void lua_hook_callback(lua_State *L, lua_Debug *ar);

@interface ScriptEngine () {
    lua_State *_luaState;
    NSThread  *_executionThread;
}
@end

@implementation ScriptEngine

+ (instancetype)shared {
    static ScriptEngine *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[ScriptEngine alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _state = ScriptStateIdle;
        _luaState = NULL;
        if (!_globalPauseCondition) {
            _globalPauseCondition = [[NSCondition alloc] init];
        }
        _globalPaused = NO;
    }
    return self;
}

#pragma mark - Lua 虚拟机生命周期

- (BOOL)initialize {
    if (_luaState) return YES;

    _luaState = luaL_newstate();
    if (!_luaState) {
        [self _emitLog:@"❌ 无法创建 Lua 虚拟机"];
        return NO;
    }

    // 加载标准库
    luaL_openlibs(_luaState);

    // 注册原生函数
    lua_register_all_native_functions(_luaState);

    // 设置日志回调
    __weak typeof(self) weakSelf = self;
    lua_set_log_callback(_luaState, ^(NSString *msg) {
        [weakSelf _emitLog:msg];
    });

    [self _emitLog:@"✅ Lua 5.4 虚拟机初始化成功"];
    return YES;
}

- (void)destroy {
    [self stop];
    if (_luaState) {
        lua_close(_luaState);
        _luaState = NULL;
    }
    [self _emitLog:@"Lua 虚拟机已销毁"];
}

#pragma mark - 脚本执行

- (BOOL)runScript:(NSString *)luaCode {
    if (!_luaState) {
        [self _emitLog:@"❌ Lua 虚拟机未初始化"];
        return NO;
    }
    if (_state == ScriptStateRunning) {
        [self _emitLog:@"⚠️ 已有脚本正在运行，请先停止"];
        return NO;
    }
    return [self _executeCode:luaCode];
}

- (BOOL)runScriptFile:(NSString *)path {
    NSError *err;
    NSString *code = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:&err];
    if (!code) {
        [self _emitLog:[NSString stringWithFormat:@"❌ 读取脚本失败: %@", err.localizedDescription]];
        return NO;
    }
    return [self runScript:code];
}

#pragma mark - 内部控制

- (BOOL)_executeCode:(NSString *)code {
    _global_script_stop_flag = 0;
    _globalPaused  = NO;

    [self _setState:ScriptStateRunning];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [weakSelf _executeInThread:code];
    });

    return YES;
}

- (void)_executeInThread:(NSString *)code {
    @autoreleasepool {
        _executionThread = [NSThread currentThread];

        const char *luaCode = [code UTF8String];

        // 使用 luaL_loadstring + lua_pcall 获得语法错误处理
        int loadRet = luaL_loadstring(_luaState, luaCode);
        if (loadRet != LUA_OK) {
            const char *err = lua_tostring(_luaState, -1);
            [self _emitLog:[NSString stringWithFormat:@"❌ 脚本语法错误: %s", err ? err : "unknown"]];
            lua_pop(_luaState, 1);
            [self _finishExecution];
            return;
        }

        // 推入 debug.traceback 作为错误处理函数
        lua_getglobal(_luaState, "debug");
        if (lua_istable(_luaState, -1)) {
            lua_getfield(_luaState, -1, "traceback");
            if (lua_isfunction(_luaState, -1)) {
                lua_insert(_luaState, -3);   // debug 表移到 stack[-3]
                lua_pop(_luaState, 1);        // pop 一个多余的
            } else {
                lua_pop(_luaState, 2);
                lua_pushnil(_luaState);
            }
        } else {
            lua_pop(_luaState, 1);
            lua_pushnil(_luaState);
        }
        int errfunc = lua_gettop(_luaState) - 1;

        // ====== 注入超时钩子（纯 C 函数指针，不是 block） ======
        lua_sethook(_luaState, lua_hook_callback, LUA_MASKCOUNT, 10000);

        // 执行脚本
        int ret = lua_pcall(_luaState, 0, 0, errfunc);

        // 清除钩子
        lua_sethook(_luaState, NULL, 0, 0);

        if (ret != LUA_OK) {
            const char *err = lua_tostring(_luaState, -1);
            NSString *errMsg = [NSString stringWithUTF8String:err ? err : "unknown"];
            if ([errMsg containsString:@"脚本已被用户停止"]) {
                [self _emitLog:@"⏹ 脚本已停止"];
            } else {
                [self _emitLog:[NSString stringWithFormat:@"❌ 脚本执行错误: %@", errMsg]];
            }
            lua_pop(_luaState, 1);
        } else {
            [self _emitLog:@"✅ 脚本执行完毕"];
        }

        lua_pop(_luaState, 1); // pop error function (nil)
        [self _finishExecution];
    }
}

- (void)_finishExecution {
    [[ScreenCapture shared] releaseCapture];
    _executionThread = nil;
    _globalPaused = NO;
    [self _setState:ScriptStateIdle];
}

#pragma mark - 暂停 / 继续 / 停止

- (void)pause {
    if (_state != ScriptStateRunning) return;
    [_globalPauseCondition lock];
    _globalPaused = YES;
    [_globalPauseCondition unlock];
    [self _setState:ScriptStatePaused];
    [self _emitLog:@"⏸ 脚本已暂停"];
}

- (void)resume {
    if (_state != ScriptStatePaused) return;
    [_globalPauseCondition lock];
    _globalPaused = NO;
    [_globalPauseCondition signal];
    [_globalPauseCondition unlock];
    [self _setState:ScriptStateRunning];
    [self _emitLog:@"▶ 脚本已恢复"];
}

- (void)stop {
    if (_state == ScriptStateIdle) return;

    [self _setState:ScriptStateStopping];
    _global_script_stop_flag = 1;

    [_globalPauseCondition lock];
    _globalPaused = NO;
    [_globalPauseCondition signal];
    [_globalPauseCondition unlock];

    [self _emitLog:@"⏹ 正在停止脚本..."];
}

#pragma mark - 屏幕尺寸

- (CGSize)getScreenSize {
    return [ScreenCapture shared].screenSize;
}

#pragma mark - 内部

- (void)_setState:(ScriptState)state {
    _state = state;
    if (self.stateChangeHandler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.stateChangeHandler(state);
        });
    }
}

- (void)_emitLog:(NSString *)msg {
    if (self.logHandler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.logHandler(msg);
        });
    }
}

@end

// ============================================================
// lua_sethook 回调 — 必须是纯 C 函数
// ============================================================
static void lua_hook_callback(lua_State *L, lua_Debug *ar) {
    (void)ar; // unused

    // 暂停处理
    if (_globalPaused) {
        [_globalPauseCondition lock];
        while (_globalPaused && !_global_script_stop_flag) {
            [_globalPauseCondition wait];
        }
        [_globalPauseCondition unlock];
    }

    // 停止处理
    if (_global_script_stop_flag) {
        luaL_error(L, "脚本已被用户停止");
    }
}
