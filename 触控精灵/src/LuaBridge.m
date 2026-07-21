/**
 *  LuaBridge.m
 *  OC → Lua 函数绑定
 *
 *  所有对外 Lua 接口统一在此注册:
 *    get_screen_color(x, y) → r, g, b
 *    find_color(x1,y1,x2,y2,r,g,b,sim) → x, y
 *    click(x, y)
 *    long_click(x, y, ms)
 *    swipe(x1, y1, x2, y2, ms)
 *    sleep(ms)
 *    log(msg)
 *    stop_script()
 *    get_screen_size() → w, h
 */

#import "LuaBridge.h"
#import "ScreenCapture.h"
#import "TouchSimulation.h"
#import <UIKit/UIKit.h>
#import <unistd.h>
#import <stdlib.h>

// 日志回调
static void (^g_logCallback)(NSString *) = nil;

// 停止标志 — 与 ScriptEngine 共享（ScriptEngine 设为 1，Lua 的 stop_script() 也设为 1）
volatile int _global_script_stop_flag = 0;

static void native_log(lua_State *L, const char *fmt, ...) {
    char buf[4096];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    NSString *msg = [NSString stringWithUTF8String:buf];
    if (g_logCallback) g_logCallback(msg);

    // 同时压入 Lua 栈作为返回值
    lua_pushstring(L, buf);
}

// ============================================================
// Lua C 回调函数
// ============================================================

/// get_screen_size() → width, height
static int l_get_screen_size(lua_State *L) {
    CGSize sz = [ScreenCapture shared].screenSize;
    lua_pushinteger(L, (lua_Integer)sz.width);
    lua_pushinteger(L, (lua_Integer)sz.height);
    return 2;
}

/// get_screen_color(x, y) → r, g, b
static int l_get_screen_color(lua_State *L) {
    int x = (int)luaL_checkinteger(L, 1);
    int y = (int)luaL_checkinteger(L, 2);

    [[ScreenCapture shared] refreshCapture];

    uint8_t r, g, b;
    if ([[ScreenCapture shared] getColorAtX:x y:y red:&r green:&g blue:&b]) {
        lua_pushinteger(L, r);
        lua_pushinteger(L, g);
        lua_pushinteger(L, b);
    } else {
        lua_pushinteger(L, 0);
        lua_pushinteger(L, 0);
        lua_pushinteger(L, 0);
    }
    return 3;
}

/// find_color(x1, y1, x2, y2, targetR, targetG, targetB, similarity) → x, y
static int l_find_color(lua_State *L) {
    int x1 = (int)luaL_checkinteger(L, 1);
    int y1 = (int)luaL_checkinteger(L, 2);
    int x2 = (int)luaL_checkinteger(L, 3);
    int y2 = (int)luaL_checkinteger(L, 4);
    int tr = (int)luaL_checkinteger(L, 5);
    int tg = (int)luaL_checkinteger(L, 6);
    int tb = (int)luaL_checkinteger(L, 7);
    int sim = (int)luaL_checkinteger(L, 8);

    [[ScreenCapture shared] refreshCapture];

    CGRect rect = CGRectMake(x1, y1, x2 - x1, y2 - y1);
    int fx, fy;
    BOOL found = [[ScreenCapture shared] findColorInRect:rect
                                               targetRed:tr
                                             targetGreen:tg
                                              targetBlue:tb
                                              similarity:sim
                                                    outX:&fx
                                                    outY:&fy];
    lua_pushinteger(L, found ? fx : 0);
    lua_pushinteger(L, found ? fy : 0);
    return 2;
}

/// click(x, y)
static int l_click(lua_State *L) {
    int x = (int)luaL_checkinteger(L, 1);
    int y = (int)luaL_checkinteger(L, 2);
    [[TouchSimulation shared] clickAtX:x y:y];
    return 0;
}

/// long_click(x, y, delay_ms)
static int l_long_click(lua_State *L) {
    int x = (int)luaL_checkinteger(L, 1);
    int y = (int)luaL_checkinteger(L, 2);
    int ms = (int)luaL_checkinteger(L, 3);
    [[TouchSimulation shared] longClickAtX:x y:y durationMs:ms];
    return 0;
}

/// swipe(x1, y1, x2, y2, delay_ms)
static int l_swipe(lua_State *L) {
    int x1 = (int)luaL_checkinteger(L, 1);
    int y1 = (int)luaL_checkinteger(L, 2);
    int x2 = (int)luaL_checkinteger(L, 3);
    int y2 = (int)luaL_checkinteger(L, 4);
    int ms = (int)luaL_checkinteger(L, 5);
    [[TouchSimulation shared] swipeFromX:x1 y:y1 toX:x2 y:y2 durationMs:ms];
    return 0;
}

/// sleep(ms) — USleep 阻断式等待，支持暂停恢复
static int l_sleep(lua_State *L) {
    int ms = (int)luaL_checkinteger(L, 1);
    if (ms <= 0) return 0;

    // 分段 sleep，每 100ms 检查一次停止标志（通过 ScriptEngine 的全局标志）
    int remaining = ms;
    while (remaining > 0) {
        if (_global_script_stop_flag) {
            lua_pushboolean(L, 0);
            return 1;
        }
        int chunk = remaining > 100 ? 100 : remaining;
        usleep(chunk * 1000);
        remaining -= chunk;
    }
    return 0;
}

/// log(message)
static int l_log(lua_State *L) {
    const char *msg = luaL_checkstring(L, 1);
    if (g_logCallback) {
        g_logCallback([NSString stringWithUTF8String:msg]);
    }
    return 0;
}

/// stop_script() — 设置停止标志
static int l_stop_script(lua_State *L) {
    _global_script_stop_flag = 1;
    return 0;
}

// ============================================================
// 注册表
// ============================================================

static const luaL_Reg g_nativeFunctions[] = {
    {"get_screen_size",  l_get_screen_size},
    {"get_screen_color", l_get_screen_color},
    {"find_color",       l_find_color},
    {"click",            l_click},
    {"long_click",       l_long_click},
    {"swipe",            l_swipe},
    {"sleep",            l_sleep},
    {"log",              l_log},
    {"stop_script",      l_stop_script},
    {NULL, NULL}
};

void lua_register_all_native_functions(lua_State *L) {
    // 注册到全局表
    lua_getglobal(L, "_G");
    for (const luaL_Reg *lib = g_nativeFunctions; lib->func; lib++) {
        lua_pushcfunction(L, lib->func);
        lua_setfield(L, -2, lib->name);
    }
    lua_pop(L, 1);

    // 重置停止标志
    _global_script_stop_flag = 0;
}

void lua_set_log_callback(lua_State *L, void (^handler)(NSString *msg)) {
    g_logCallback = [handler copy];
}
