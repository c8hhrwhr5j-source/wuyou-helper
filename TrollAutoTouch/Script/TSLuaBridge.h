//
//  TSLuaBridge.h
//  TrollAutoTouch
//
//  Lua 桥接参考(可选)。原版 TrollAutoScript 用 Lua 5.x + 原生 .so 扩展作为脚本层，
//  本工程默认用自带的 TSScriptEngine(DSL) 即可运行。若需要完整 Lua 兼容，
//  按下面的步骤接入 Lua 5.4，并在本文件实现 native 函数注册。
//
//  接入步骤:
//   1) 把 Lua 5.4 源码 (lua.h / lauxlib.h / lualib.h + *.c) 加入工程，编译为静态库。
//   2) 在本文件实现 +load，创建 lua_State 并注册下表函数。
//   3) 用 luaL_dostring / luaL_dofile 执行用户脚本。
//
//  对齐原版脚本 API(常见 TouchScript 风格):
//    findColor(color, x1,y1,x2,y2, sim) -> x,y | nil
//    getColor(x, y) -> 0xRRGGBB
//    tap(x, y)
//    touchDown(index, x, y) / touchMove(index, x, y) / touchUp(index, x, y)
//    swipe(x1,y1,x2,y2, ms)
//    snapshot() / keepScreen(true|false)
//    mSleep(ms)
//    getScreenSize() -> w, h
//    logStr / toast(msg)
//
//  示例注册(伪代码，需要 lua.h):
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSLuaBridge : NSObject
+ (instancetype)shared;
- (void)runFile:(NSString *)path;
- (void)runString:(NSString *)code;
- (void)stop;
@end

NS_ASSUME_NONNULL_END

/*
// ===== 启用 Lua 时取消注释并在工程引入 Lua 源码 =====
#import "lua.h"
#import "lauxlib.h"
#import "lualib.h"
#import "TSTouchSimulator.h"
#import "TSHIDEventTouch.h"
#import "TSScreenCapture.h"
#import "TSColorFinder.h"

static int l_mSleep(lua_State *L) {
    [NSThread sleepForTimeInterval:luaL_checkinteger(L, 1) / 1000.0];
    return 0;
}
static int l_tap(lua_State *L) {
    CGPoint p = CGPointMake((CGFloat)luaL_checknumber(L, 1), (CGFloat)luaL_checknumber(L, 2));
    [[TSHIDEventTouch shared] tapAtPoint:p duration:0.05];
    return 0;
}
static int l_swipe(lua_State *L) {
    CGPoint a = CGPointMake((CGFloat)luaL_checknumber(L,1),(CGFloat)luaL_checknumber(L,2));
    CGPoint b = CGPointMake((CGFloat)luaL_checknumber(L,3),(CGFloat)luaL_checknumber(L,4));
    NSTimeInterval d = luaL_checkinteger(L,5) / 1000.0;
    [[TSHIDEventTouch shared] swipeFromPoint:a toPoint:b duration:d steps:MAX(2,(NSInteger)(d*60))];
    return 0;
}
static int l_findColor(lua_State *L) {
    int color = (int)luaL_checkinteger(L, 1);
    CGFloat x1=(CGFloat)luaL_checknumber(L,2), y1=(CGFloat)luaL_checknumber(L,3);
    CGFloat x2=(CGFloat)luaL_checknumber(L,4), y2=(CGFloat)luaL_checknumber(L,5);
    CGFloat sim = (CGFloat)luaL_optnumber(L, 6, 0.9);
    CGRect r = CGRectMake(x1,y1, x2-x1, y2-y1);
    uint8_t *px=NULL; int w=0,h=0;
    if (![[TSScreenCapture shared] captureScreenToRGBA:&px width:&w height:&h] || !px) { lua_pushnil(L); return 1; }
    CGSize ss = [UIScreen mainScreen].bounds.size;
    TSColorResult *res = [TSColorFinder findColor:color rect:r sim:sim pixels:px width:w height:h screenSize:ss];
    free(px);
    if (!res) { lua_pushnil(L); return 1; }
    lua_pushnumber(L, res.point.x);
    lua_pushnumber(L, res.point.y);
    return 2;
}
static int l_getColor(lua_State *L) {
    CGFloat x=(CGFloat)luaL_checknumber(L,1), y=(CGFloat)luaL_checknumber(L,2);
    uint8_t *px=NULL; int w=0,h=0;
    if (![[TSScreenCapture shared] captureScreenToRGBA:&px width:&w height:&h] || !px) { lua_pushinteger(L,0); return 1; }
    CGSize ss=[UIScreen mainScreen].bounds.size;
    int c = [TSColorFinder getColorAtPoint:CGPointMake(x,y) pixels:px width:w height:h screenSize:ss];
    free(px);
    lua_pushinteger(L, c);
    return 1;
}
static const luaL_Reg tasLib[] = {
    {"mSleep", l_mSleep}, {"tap", l_tap}, {"swipe", l_swipe},
    {"findColor", l_findColor}, {"getColor", l_getColor},
    {NULL, NULL}
};

@implementation TSLuaBridge {
    lua_State *_L;
    NSThread *_thread;
    volatile BOOL _stop;
}
+ (instancetype)shared { static TSLuaBridge *i; static dispatch_once_t t; dispatch_once(&t,^{i=[TSLuaBridge new];}); return i; }
- (instancetype)init { self=[super init]; if(self){ _L=luaL_newstate(); luaL_openlibs(_L); luaL_newlib(_L, tasLib); lua_setglobal(_L, "tas"); } return self; }
- (void)runFile:(NSString *)path { _stop=NO; _thread=[[NSThread alloc]initWithTarget:self selector:@selector(_runF:) object:path]; [_thread start]; }
- (void)runString:(NSString *)code { _stop=NO; _thread=[[NSThread alloc]initWithTarget:self selector:@selector(_runS:) object:code]; [_thread start]; }
- (void)_runF:(NSString *)p { @autoreleasepool{ luaL_dofile(_L, p.UTF8String); } }
- (void)_runS:(NSString *)c { @autoreleasepool{ luaL_dostring(_L, c.UTF8String); } }
- (void)stop { _stop=YES; }
@end
*/
