/**
 *  LuaBridge.h
 *  OC 原生函数注册到 Lua 全局环境
 *
 *  所有对外 Lua 接口统一在此注册:
 *    get_screen_color, find_color, click, long_click,
 *    swipe, sleep, log, stop_script, get_screen_size
 */

#import <Foundation/Foundation.h>
#import "lua.h"

/// 将所有原生函数注册到指定的 Lua 虚拟机
void lua_register_all_native_functions(lua_State *L);

/// 设置日志回调（OC 端接收 Lua 的 log() 输出）
void lua_set_log_callback(lua_State *L, void (^handler)(NSString *msg));
