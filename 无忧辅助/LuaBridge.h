//
//  LuaBridge.h
//  无忧辅助 - OC ↔ Lua 函数桥接
//

#import <Foundation/Foundation.h>
#include "lua.h"

/// 全局脚本停止标志（ScriptEngine 设置，LuaBridge 检查）
extern volatile int _global_script_stop_flag;

/// 向 Lua VM 注册所有桥接函数（点击、滑动、找色、截图等）
void lua_register_bridge_functions(lua_State *L);

/// 设置日志回调（OC 端接收 Lua 的 log() 输出）
void lua_set_log_callback(lua_State *L, void (^handler)(NSString *msg));
