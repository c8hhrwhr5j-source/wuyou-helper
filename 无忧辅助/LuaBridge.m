//
//  LuaBridge.m
//  无忧辅助 - OC ↔ Lua 函数桥接实现（模块表风格）
//

#import "LuaBridge.h"
#import "ScreenCapture.h"
#import "TouchSimulation.h"
#import "AppManager.h"
#import <UIKit/UIKit.h>
#import <string.h>
#import <stdlib.h>
#import <unistd.h>
#include "lauxlib.h"

// 前向声明 Slide 辅助函数（l_touch_slide 在其定义之前引用）
static int l_touch_slide_gc(lua_State *L);
static int l_touch_slide_step(lua_State *L);
static int l_touch_slide_delay(lua_State *L);
static int l_touch_slide_on(lua_State *L);
static int l_touch_slide_move(lua_State *L);
static int l_touch_slide_up(lua_State *L);
static TouchSlide *l_checkSlide(lua_State *L, int idx);

// 日志回调
static void (^g_logCallback)(NSString *) = nil;

// 停止标志 — 与 ScriptEngine 共享
volatile int _global_script_stop_flag = 0;

// MARK: - 工具辅助

static void l_stopCheck(lua_State *L) {
    if (_global_script_stop_flag) {
        lua_pushstring(L, "script interrupted");
        lua_error(L);
    }
}

static int l_stopScript_cfunc(lua_State *L) {
    _global_script_stop_flag = 1;
    return 0;
}

// MARK: - 全局函数（兼容旧 API）

static int l_log(lua_State *L) {
    const char *msg = luaL_checkstring(L, 1);
    NSString *nsMsg = [NSString stringWithUTF8String:msg];
    if (g_logCallback) g_logCallback(nsMsg);
    return 0;
}

static int l_sleep(lua_State *L) {
    lua_Integer ms = luaL_checkinteger(L, 1);
    if (ms <= 0) return 0;
    lua_Integer elapsed = 0;
    while (elapsed < ms) {
        if (_global_script_stop_flag) {
            lua_pushstring(L, "script interrupted during sleep");
            lua_error(L);
            return 0;
        }
        lua_Integer chunk = 100;
        if (elapsed + chunk > ms) chunk = ms - elapsed;
        usleep((useconds_t)(chunk * 1000));
        elapsed += chunk;
    }
    return 0;
}

// MARK: - 兼容旧 API（click / hold / swipe / find_color）

// --- click(x, y) ---
static int l_click(lua_State *L) {
    CGFloat x = luaL_checknumber(L, 1);
    CGFloat y = luaL_checknumber(L, 2);
    [[TouchSimulation sharedInstance] clickAtX:x y:y];
    return 0;
}

// --- hold(x, y, ms?) ---
static int l_hold(lua_State *L) {
    CGFloat x = luaL_checknumber(L, 1);
    CGFloat y = luaL_checknumber(L, 2);
    NSInteger ms = luaL_optinteger(L, 3, 500);
    [[TouchSimulation sharedInstance] holdAtX:x y:y duration:ms];
    return 0;
}

// --- swipe(x1, y1, x2, y2, durationMs?) ---
static int l_swipe(lua_State *L) {
    CGFloat x1 = luaL_checknumber(L, 1);
    CGFloat y1 = luaL_checknumber(L, 2);
    CGFloat x2 = luaL_checknumber(L, 3);
    CGFloat y2 = luaL_checknumber(L, 4);
    NSInteger ms = luaL_optinteger(L, 5, 500);
    [[TouchSimulation sharedInstance] swipeFromX:x1 y:y1 toX:x2 y:y2 duration:ms];
    return 0;
}

// --- find_color(r, g, b, fuzzy?, ltx?, lty?, rbx?, rby?) → x, y ---
static int l_find_color(lua_State *L) {
    int r = (int)luaL_checkinteger(L, 1);
    int g = (int)luaL_checkinteger(L, 2);
    int b = (int)luaL_checkinteger(L, 3);
    int fuzzy = (int)luaL_optinteger(L, 4, 100);
    int ltx   = (int)luaL_optinteger(L, 5, 0);
    int lty   = (int)luaL_optinteger(L, 6, 0);
    int rbx   = (int)luaL_optinteger(L, 7, 0);
    int rby   = (int)luaL_optinteger(L, 8, 0);

    int tolerance = (int)((100.0 - fuzzy) / 100.0 * 255);
    if (tolerance < 0) tolerance = 0;

    ScreenColor target = {r, g, b};
    CGPoint result = [[ScreenCapture sharedInstance] findColor:target
                                                     tolerance:tolerance
                                                           x1:ltx y1:lty x2:rbx y2:rby];
    if (result.x < 0) {
        lua_pushnil(L);
        lua_pushnil(L);
        return 2;
    }
    lua_pushinteger(L, (lua_Integer)result.x);
    lua_pushinteger(L, (lua_Integer)result.y);
    return 2;
}

// MARK: - 屏幕模块 screen.*

// --- screen.resolution() → width, height ---
static int l_screen_resolution(lua_State *L) {
    CGSize size = [[ScreenCapture sharedInstance] screenSize];
    lua_pushinteger(L, (lua_Integer)size.width);
    lua_pushinteger(L, (lua_Integer)size.height);
    return 2;
}

// --- screen.colorBits() → color ---
static int l_screen_colorBits(lua_State *L) {
    // iOS 设备均为 32 位色（8位 R + 8位 G + 8位 B + 8位 A）
    lua_pushinteger(L, 32);
    return 1;
}

// --- screen.keep(on, colors?, fuzzy?) ---
static int l_screen_keep(lua_State *L) {
    luaL_checktype(L, 1, LUA_TBOOLEAN);
    BOOL on = lua_toboolean(L, 1);

    if (on) {
        [[ScreenCapture sharedInstance] keepScreen];
    } else {
        [[ScreenCapture sharedInstance] releaseScreen];
    }
    return 0;
}

// --- screen.rotate(deg) ---
static int l_screen_rotate(lua_State *L) {
    int deg = (int)luaL_checkinteger(L, 1);
    [[ScreenCapture sharedInstance] setRotation:deg];
    return 0;
}

// --- screen.getColor(x, y) → color ---
static int l_screen_getColor(lua_State *L) {
    CGFloat x = luaL_checknumber(L, 1);
    CGFloat y = luaL_checknumber(L, 2);
    ScreenColor color = [[ScreenCapture sharedInstance] colorAtX:(int)x y:(int)y];
    // 返回十进制 RGB 颜色值 (R<<16 | G<<8 | B)
    uint32_t hex = ((uint32_t)color.r << 16) | ((uint32_t)color.g << 8) | (uint32_t)color.b;
    lua_pushinteger(L, hex);
    return 1;
}

// --- screen.getColorRGB(x, y) → r, g, b ---
static int l_screen_getColorRGB(lua_State *L) {
    CGFloat x = luaL_checknumber(L, 1);
    CGFloat y = luaL_checknumber(L, 2);
    ScreenColor color = [[ScreenCapture sharedInstance] colorAtX:(int)x y:(int)y];
    lua_pushinteger(L, color.r);
    lua_pushinteger(L, color.g);
    lua_pushinteger(L, color.b);
    return 3;
}

// --- screen.findColor(colors, fuzzy?, ltx?, lty?, rbx?, rby?, all?) → x, y ---
// colors 为 table: {color1, offx2, offy2, color2, offx3, offy3, color3, ...}
static int l_screen_findColor(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    // 解析颜色数组
    int len = (int)lua_rawlen(L, 1);
    if (len < 1) {
        lua_pushinteger(L, -1);
        lua_pushinteger(L, -1);
        return 2;
    }

    // 取第一个颜色作为主目标色
    lua_rawgeti(L, 1, 1);
    uint32_t mainColor = (uint32_t)luaL_checkinteger(L, -1);
    lua_pop(L, 1);

    int r = (mainColor >> 16) & 0xFF;
    int g = (mainColor >> 8) & 0xFF;
    int b = mainColor & 0xFF;

    int fuzzy = (int)luaL_optinteger(L, 2, 100);
    // 将 1-100 精度转换为容差：精度100→容差0，精度50→容差约32
    int tolerance = (int)((100.0 - fuzzy) / 100.0 * 255);
    if (tolerance < 0) tolerance = 0;

    int ltx = (int)luaL_optinteger(L, 3, 0);
    int lty = (int)luaL_optinteger(L, 4, 0);
    int rbx = (int)luaL_optinteger(L, 5, 0);
    int rby = (int)luaL_optinteger(L, 6, 0);

    BOOL all = NO;
    if (lua_gettop(L) >= 7) {
        all = lua_toboolean(L, 7);
    }

    ScreenColor target = {r, g, b};

    if (all) {
        // 返回所有匹配坐标的 table
        NSArray<NSValue *> *results = [[ScreenCapture sharedInstance] findAllColors:target
                                                                          tolerance:tolerance
                                                                                 x1:ltx y1:lty x2:rbx y2:rby];
        lua_newtable(L);
        int idx = 1;
        for (NSValue *val in results) {
            CGPoint pt = [val CGPointValue];
            lua_newtable(L);
            lua_pushinteger(L, (lua_Integer)pt.x);
            lua_rawseti(L, -2, 1);
            lua_pushinteger(L, (lua_Integer)pt.y);
            lua_rawseti(L, -2, 2);
            lua_rawseti(L, -2, idx++);
        }
        return 1;
    } else {
        CGPoint result = [[ScreenCapture sharedInstance] findColor:target
                                                         tolerance:tolerance
                                                               x1:ltx y1:lty x2:rbx y2:rby];
        if (result.x < 0) {
            lua_pushinteger(L, -1);
            lua_pushinteger(L, -1);
            return 2;
        }
        lua_pushinteger(L, (lua_Integer)result.x);
        lua_pushinteger(L, (lua_Integer)result.y);
        return 2;
    }
}

// --- screen.snapshot(path, x?, y?, w?, h?) ---
static int l_screen_snapshot(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    int x = (int)luaL_optinteger(L, 2, 0);
    int y = (int)luaL_optinteger(L, 3, 0);
    int w = (int)luaL_optinteger(L, 4, 0);
    int h = (int)luaL_optinteger(L, 5, 0);

    BOOL ok;
    if (w == 0 || h == 0) {
        ok = [[ScreenCapture sharedInstance] snapshotToPath:[NSString stringWithUTF8String:path]];
    } else {
        ok = [[ScreenCapture sharedInstance] snapshotToPath:[NSString stringWithUTF8String:path]
                                                         x:x y:y w:w h:h];
    }
    lua_pushboolean(L, ok);
    return 1;
}

// --- screen.isReady() → bool ---
static int l_screen_isReady(lua_State *L) {
    BOOL ready = [[ScreenCapture sharedInstance] isConnected];
    lua_pushboolean(L, ready);
    return 1;
}

// --- screen.refresh() — 重连 IOMFB（后台恢复取色）---
static int l_screen_refresh(lua_State *L) {
    [[ScreenCapture sharedInstance] reconnectScreen];
    return 0;
}

// --- screen.alive() → bool — 取色是否存活（读中点测试）---
static int l_screen_alive(lua_State *L) {
    BOOL alive = [[ScreenCapture sharedInstance] isScreenAlive];
    lua_pushboolean(L, alive);
    return 1;
}

// MARK: - 触控模块 touch.*

// --- touch.down(id, x, y) ---
static int l_touch_down(lua_State *L) {
    uint32_t fingerID = (uint32_t)luaL_checkinteger(L, 1);
    CGFloat x = luaL_checknumber(L, 2);
    CGFloat y = luaL_checknumber(L, 3);
    [[TouchSimulation sharedInstance] downAtX:x y:y fingerID:fingerID];
    return 0;
}

// --- touch.move(id, x, y) ---
static int l_touch_move(lua_State *L) {
    uint32_t fingerID = (uint32_t)luaL_checkinteger(L, 1);
    CGFloat x = luaL_checknumber(L, 2);
    CGFloat y = luaL_checknumber(L, 3);
    [[TouchSimulation sharedInstance] moveAtX:x y:y fingerID:fingerID];
    return 0;
}

// --- touch.up(id) ---
static int l_touch_up(lua_State *L) {
    uint32_t fingerID = (uint32_t)luaL_checkinteger(L, 1);
    [[TouchSimulation sharedInstance] upFinger:fingerID];
    return 0;
}

// --- touch.tap(x, y, ms?, id?) ---
static int l_touch_tap(lua_State *L) {
    CGFloat x = luaL_checknumber(L, 1);
    CGFloat y = luaL_checknumber(L, 2);
    int ms = (int)luaL_optinteger(L, 3, 50);
    uint32_t fingerID = (uint32_t)luaL_optinteger(L, 4, 0);
    [[TouchSimulation sharedInstance] tapAtX:x y:y delayMs:ms fingerID:fingerID];
    return 0;
}

// --- touch.tapRandom(x, y, r?, ms?, id?) ---
static int l_touch_tapRandom(lua_State *L) {
    CGFloat x = luaL_checknumber(L, 1);
    CGFloat y = luaL_checknumber(L, 2);
    int range = (int)luaL_optinteger(L, 3, 5);
    int ms = (int)luaL_optinteger(L, 4, 50);
    uint32_t fingerID = (uint32_t)luaL_optinteger(L, 5, 0);
    [[TouchSimulation sharedInstance] tapRandomAtX:x y:y range:range delayMs:ms fingerID:fingerID];
    return 0;
}

// --- touch.slide(id?) → 返回 Slide 对象 ---
static int l_touch_slide(lua_State *L) {
    uint32_t fingerID = (uint32_t)luaL_optinteger(L, 1, 0);

    // 用 void* + memcpy 存储 ObjC 指针，避免 ARC 所有权推断冲突
    void *ud = lua_newuserdata(L, sizeof(CFTypeRef));
    CFTypeRef cfObj = CFBridgingRetain([[TouchSimulation sharedInstance] slideWithFingerID:fingerID]);
    memcpy(ud, &cfObj, sizeof(cfObj));

    // 设置 metatable
    luaL_newmetatable(L, "TouchSlide");

    lua_pushstring(L, "__gc");
    lua_pushcfunction(L, l_touch_slide_gc);
    lua_settable(L, -3);

    lua_pushstring(L, "__index");
    lua_newtable(L);

    lua_pushstring(L, "step");
    lua_pushcfunction(L, l_touch_slide_step);
    lua_settable(L, -3);

    lua_pushstring(L, "delay");
    lua_pushcfunction(L, l_touch_slide_delay);
    lua_settable(L, -3);

    lua_pushstring(L, "on");
    lua_pushcfunction(L, l_touch_slide_on);
    lua_settable(L, -3);

    lua_pushstring(L, "move");
    lua_pushcfunction(L, l_touch_slide_move);
    lua_settable(L, -3);

    lua_pushstring(L, "up");
    lua_pushcfunction(L, l_touch_slide_up);
    lua_settable(L, -3);

    lua_settable(L, -3);

    lua_setmetatable(L, -2);
    return 1;
}

// Slide 对象方法
static int l_touch_slide_gc(lua_State *L) {
    CFTypeRef cfObj;
    memcpy(&cfObj, luaL_checkudata(L, 1, "TouchSlide"), sizeof(cfObj));
    if (cfObj) {
        CFBridgingRelease(cfObj);
        // 清零防止重入
        cfObj = NULL;
        memcpy(lua_touserdata(L, 1), &cfObj, sizeof(cfObj));
    }
    return 0;
}

static TouchSlide *l_checkSlide(lua_State *L, int idx) {
    CFTypeRef cfObj;
    memcpy(&cfObj, luaL_checkudata(L, idx, "TouchSlide"), sizeof(cfObj));
    return (__bridge TouchSlide *)cfObj;
}

static int l_touch_slide_step(lua_State *L) {
    TouchSlide *slide = l_checkSlide(L, 1);
    int step = (int)luaL_checkinteger(L, 2);
    [slide step:step];
    lua_settop(L, 1); // 返回自身，支持链式调用
    return 1;
}

static int l_touch_slide_delay(lua_State *L) {
    TouchSlide *slide = l_checkSlide(L, 1);
    int delayMs = (int)luaL_checkinteger(L, 2);
    [slide delay:delayMs];
    lua_settop(L, 1);
    return 1;
}

static int l_touch_slide_on(lua_State *L) {
    TouchSlide *slide = l_checkSlide(L, 1);
    CGFloat x = luaL_checknumber(L, 2);
    CGFloat y = luaL_checknumber(L, 3);
    [slide on:x y:y];
    lua_settop(L, 1);
    return 1;
}

static int l_touch_slide_move(lua_State *L) {
    TouchSlide *slide = l_checkSlide(L, 1);
    CGFloat x = luaL_checknumber(L, 2);
    CGFloat y = luaL_checknumber(L, 3);
    [slide move:x y:y];
    lua_settop(L, 1);
    return 1;
}

static int l_touch_slide_up(lua_State *L) {
    TouchSlide *slide = l_checkSlide(L, 1);
    [slide up];
    lua_settop(L, 1);
    return 1;
}

// MARK: - 应用模块 app.*

// --- app.frontBid() → bundleId ---
static int l_app_frontBid(lua_State *L) {
    NSString *bid = [[AppManager sharedInstance] frontBid];
    lua_pushstring(L, bid ? [bid UTF8String] : "");
    return 1;
}

// --- app.run(bundleId) ---
static int l_app_run(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    BOOL ok = [[AppManager sharedInstance] runApp:[NSString stringWithUTF8String:bid]];
    lua_pushboolean(L, ok);
    return 1;
}

// --- app.kill(bundleId) ---
static int l_app_kill(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    BOOL ok = [[AppManager sharedInstance] killApp:[NSString stringWithUTF8String:bid]];
    lua_pushboolean(L, ok);
    return 1;
}

// --- app.running(bundleId) → bool ---
static int l_app_running(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    BOOL running = [[AppManager sharedInstance] isAppRunning:[NSString stringWithUTF8String:bid]];
    lua_pushboolean(L, running);
    return 1;
}

// --- app.bundlePath(bundleId) → path ---
static int l_app_bundlePath(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    NSString *path = [[AppManager sharedInstance] bundlePath:[NSString stringWithUTF8String:bid]];
    lua_pushstring(L, path ? [path UTF8String] : "");
    return 1;
}

// MARK: - 注册表

// app 模块函数表
static const luaL_Reg g_appLib[] = {
    {"frontBid",    l_app_frontBid},
    {"run",         l_app_run},
    {"kill",        l_app_kill},
    {"running",     l_app_running},
    {"bundlePath",  l_app_bundlePath},
    {NULL, NULL},
};

// screen 模块函数表
static const luaL_Reg g_screenLib[] = {
    {"resolution",   l_screen_resolution},
    {"colorBits",    l_screen_colorBits},
    {"keep",         l_screen_keep},
    {"rotate",       l_screen_rotate},
    {"getColor",     l_screen_getColor},
    {"getColorRGB",  l_screen_getColorRGB},
    {"findColor",    l_screen_findColor},
    {"snapshot",     l_screen_snapshot},
    {"isReady",      l_screen_isReady},
    {"refresh",      l_screen_refresh},
    {"alive",        l_screen_alive},
    {NULL, NULL},
};

// touch 模块函数表
static const luaL_Reg g_touchLib[] = {
    {"down",       l_touch_down},
    {"move",       l_touch_move},
    {"up",         l_touch_up},
    {"tap",        l_touch_tap},
    {"tapRandom",  l_touch_tapRandom},
    {"slide",      l_touch_slide},
    {NULL, NULL},
};

// 全局函数（兼容旧 API）
static const luaL_Reg g_globalFunctions[] = {
    {"log",              l_log},
    {"sleep",            l_sleep},
    {"click",            l_click},
    {"hold",             l_hold},
    {"swipe",            l_swipe},
    {"find_color",       l_find_color},
    {"get_resolution",   l_screen_resolution},    // 别名
    {"get_screen_color", l_screen_getColorRGB},   // 别名
    {NULL, NULL},
};

// MARK: - 公开接口

void lua_register_bridge_functions(lua_State *L) {
    // 重置停止标志
    _global_script_stop_flag = 0;

    // 注册全局函数（兼容旧 API）
    const luaL_Reg *gf = g_globalFunctions;
    for (; gf->name; gf++) {
        lua_register(L, gf->name, gf->func);
    }

    // 注册 screen 模块表
    luaL_newlib(L, g_screenLib);
    lua_setglobal(L, "screen");

    // 注册 touch 模块表
    luaL_newlib(L, g_touchLib);
    lua_setglobal(L, "touch");

    // 注册 app 模块表
    luaL_newlib(L, g_appLib);
    lua_setglobal(L, "app");

    // 注册 stop_script 全局函数
    lua_register(L, "stop_script", l_stopScript_cfunc);
}

void lua_set_log_callback(lua_State *L, void (^handler)(NSString *msg)) {
    (void)L;
    g_logCallback = [handler copy];
}
