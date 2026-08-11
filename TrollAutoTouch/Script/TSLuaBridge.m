//
//  TSLuaBridge.m
//  TrollAutoTouch
//
//  完整 Lua 桥接实现。嵌入 Lua 5.4 源码后激活全部原生模块:
//    touch / sys / screen / appNode / device / http
//
//  集成步骤:
//   1) 将 lua-5.4.x/src/*.c (排除 lua.c luac.c) 加入工程编译为静态库
//   2) Header Search Paths 加入 lua-5.4.x/src
//   3) 取消本文件底部的注释区块
//
//  当前工程默认使用 TSScriptEngine(DSL)，无需 Lua 也可编译运行。
//

#import "TSLuaBridge.h"
#import "TSHIDEventTouch.h"
#import "TSScreenCapture.h"
#import "TSColorFinder.h"
#import "TSTouchSimulator.h"
#import "TSAppManager.h"
#import "TSKeyboardInjector.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonCrypto.h>

// ============================================================
//  以下为完整 Lua 桥接实现。需要引入 Lua 5.4 头文件。
//  当前为注释状态，接入 Lua 源码后取消注释即可。
// ============================================================

/*
#import "lua.h"
#import "lauxlib.h"
#import "lualib.h"

#pragma mark - 工具函数

/// 从 lua_State 栈顶获取 CGRect: 支持 Rect(x,y,w,h) 或 4 个 number
static CGRect l_optRect(lua_State *L, int idx) {
    if (lua_type(L, idx) == LUA_TTABLE) {
        lua_getfield(L, idx, "x");     CGFloat x = (CGFloat)luaL_optnumber(L, -1, 0);
        lua_getfield(L, idx, "y");     CGFloat y = (CGFloat)luaL_optnumber(L, -1, 0);
        lua_getfield(L, idx, "width");  CGFloat w = (CGFloat)luaL_optnumber(L, -1, 0);
        lua_getfield(L, idx, "height"); CGFloat h = (CGFloat)luaL_optnumber(L, -1, 0);
        lua_pop(L, 4);
        return CGRectMake(x, y, w, h);
    }
    CGFloat x = (CGFloat)luaL_optnumber(L, idx, 0);
    CGFloat y = (CGFloat)luaL_optnumber(L, idx+1, 0);
    CGFloat w = (CGFloat)luaL_optnumber(L, idx+2, 0);
    CGFloat h = (CGFloat)luaL_optnumber(L, idx+3, 0);
    return CGRectMake(x, y, w, h);
}

#pragma mark - touch 模块

static int l_touch_tap(lua_State *L) {
    CGPoint p = CGPointMake((CGFloat)luaL_checknumber(L, 1), (CGFloat)luaL_checknumber(L, 2));
    NSTimeInterval dur = (NSTimeInterval)luaL_optnumber(L, 3, 0.05);
    [[TSHIDEventTouch shared] tapAtPoint:p duration:dur];
    return 0;
}

static int l_touch_down(lua_State *L) {
    int index = (int)luaL_optinteger(L, 1, 0);
    CGPoint p = CGPointMake((CGFloat)luaL_checknumber(L, 2), (CGFloat)luaL_checknumber(L, 3));
    [[TSHIDEventTouch shared] touchDownAtPoint:p index:index];
    return 0;
}

static int l_touch_move(lua_State *L) {
    int index = (int)luaL_optinteger(L, 1, 0);
    CGPoint p = CGPointMake((CGFloat)luaL_checknumber(L, 2), (CGFloat)luaL_checknumber(L, 3));
    [[TSHIDEventTouch shared] touchMoveAtPoint:p index:index];
    return 0;
}

static int l_touch_up(lua_State *L) {
    int index = (int)luaL_optinteger(L, 1, 0);
    CGPoint p = CGPointMake((CGFloat)luaL_checknumber(L, 2), (CGFloat)luaL_checknumber(L, 3));
    [[TSHIDEventTouch shared] touchUpAtPoint:p index:index];
    return 0;
}

static int l_touch_swipe(lua_State *L) {
    CGPoint a = CGPointMake((CGFloat)luaL_checknumber(L, 1), (CGFloat)luaL_checknumber(L, 2));
    CGPoint b = CGPointMake((CGFloat)luaL_checknumber(L, 3), (CGFloat)luaL_checknumber(L, 4));
    NSTimeInterval d = (NSTimeInterval)luaL_optnumber(L, 5, 300) / 1000.0;
    NSInteger steps = (NSInteger)luaL_optinteger(L, 6, MAX(2, (NSInteger)(d * 60)));
    [[TSHIDEventTouch shared] swipeFromPoint:a toPoint:b duration:d steps:steps];
    return 0;
}

/// 多点触控轨迹: touch.move(x1,y1, x2,y2, ...)
static int l_touch_stroke(lua_State *L) {
    int n = lua_gettop(L);
    if (n < 4 || n % 2 != 0) { luaL_error(L, "参数应成对出现 (x1,y1,x2,y2,...)"); return 0; }
    int points = n / 2;
    NSTimeInterval duration = (NSTimeInterval)luaL_optnumber(L, -1, 500) / 1000.0;
    
    // 第1点: down
    CGPoint p0 = CGPointMake((CGFloat)luaL_checknumber(L, 1), (CGFloat)luaL_checknumber(L, 2));
    [[TSHIDEventTouch shared] touchDownAtPoint:p0 index:0];
    NSTimeInterval dt = duration / (NSTimeInterval)(points - 1);
    
    for (int i = 1; i < points; i++) {
        CGPoint pi = CGPointMake((CGFloat)luaL_checknumber(L, i*2+1), (CGFloat)luaL_checknumber(L, i*2+2));
        [NSThread sleepForTimeInterval:dt];
        [[TSHIDEventTouch shared] touchMoveAtPoint:pi index:0];
    }
    [NSThread sleepForTimeInterval:0.02];
    CGPoint plast = CGPointMake((CGFloat)luaL_checknumber(L, n-1), (CGFloat)luaL_checknumber(L, n));
    [[TSHIDEventTouch shared] touchUpAtPoint:plast index:0];
    return 0;
}

#pragma mark - screen 模块

static int l_screen_capture(lua_State *L) {
    uint8_t *px = NULL; int w = 0, h = 0;
    if (![[TSScreenCapture shared] captureScreenToRGBA:&px width:&w height:&h] || !px) {
        lua_pushnil(L);
        return 1;
    }
    lua_createtable(L, 0, 3);
    lua_pushstring(L, "pixels");
    lua_pushlightuserdata(L, px);
    lua_settable(L, -3);
    lua_pushstring(L, "width");
    lua_pushinteger(L, w);
    lua_settable(L, -3);
    lua_pushstring(L, "height");
    lua_pushinteger(L, h);
    lua_settable(L, -3);
    return 1;
}

static int l_screen_getColor(lua_State *L) {
    CGFloat x = (CGFloat)luaL_checknumber(L, 1);
    CGFloat y = (CGFloat)luaL_checknumber(L, 2);
    uint8_t *px = NULL; int w = 0, h = 0;
    if (![[TSScreenCapture shared] captureScreenToRGBA:&px width:&w height:&h] || !px) {
        lua_pushinteger(L, 0);
        return 1;
    }
    CGSize ss = [UIScreen mainScreen].bounds.size;
    int c = [TSColorFinder getColorAtPoint:CGPointMake(x, y) pixels:px width:w height:h screenSize:ss];
    free(px);
    lua_pushinteger(L, c);
    return 1;
}

static int l_screen_findColor(lua_State *L) {
    int color = (int)luaL_checkinteger(L, 1);
    CGRect rect = l_optRect(L, 2);
    CGFloat sim = (CGFloat)luaL_optnumber(L, 6, 0.9);
    
    uint8_t *px = NULL; int w = 0, h = 0;
    if (![[TSScreenCapture shared] captureScreenToRGBA:&px width:&w height:&h] || !px) {
        lua_pushnil(L);
        return 1;
    }
    CGSize ss = [UIScreen mainScreen].bounds.size;
    TSColorResult *res = [TSColorFinder findColor:color rect:rect sim:sim pixels:px width:w height:h screenSize:ss];
    free(px);
    
    if (!res) { lua_pushnil(L); return 1; }
    lua_pushnumber(L, res.point.x);
    lua_pushnumber(L, res.point.y);
    return 2;
}

static int l_screen_findColors(lua_State *L) {
    int mainColor = (int)luaL_checkinteger(L, 1);
    CGRect rect = l_optRect(L, 2);
    
    // 偏移点表: {{x=dx,y=dy,color=0xRRGGBB}, ...}
    luaL_checktype(L, 6, LUA_TTABLE);
    NSMutableArray *offsets = [NSMutableArray array];
    lua_pushnil(L);
    while (lua_next(L, 6)) {
        if (lua_istable(L, -1)) {
            lua_getfield(L, -1, "x");     CGFloat dx = (CGFloat)lua_tonumber(L, -1); lua_pop(L, 1);
            lua_getfield(L, -1, "y");     CGFloat dy = (CGFloat)lua_tonumber(L, -1); lua_pop(L, 1);
            lua_getfield(L, -1, "color"); int oc = (int)lua_tointeger(L, -1); lua_pop(L, 1);
            [offsets addObject:@{@"x": @(dx), @"y": @(dy), @"color": @(oc)}];
        }
        lua_pop(L, 1);
    }
    
    CGFloat sim = (CGFloat)luaL_optnumber(L, 7, 0.9);
    CGFloat offSim = (CGFloat)luaL_optnumber(L, 8, sim);
    
    uint8_t *px = NULL; int w = 0, h = 0;
    if (![[TSScreenCapture shared] captureScreenToRGBA:&px width:&w height:&h] || !px) {
        lua_pushnil(L); return 1;
    }
    CGSize ss = [UIScreen mainScreen].bounds.size;
    TSColorResult *res = [TSColorFinder findMultiColor:mainColor rect:rect mainColorSim:sim
                                              offsets:offsets offsetSim:offSim
                                              pixels:px width:w height:h screenSize:ss];
    free(px);
    
    if (!res) { lua_pushnil(L); return 1; }
    lua_pushnumber(L, res.point.x);
    lua_pushnumber(L, res.point.y);
    return 2;
}

#pragma mark - sys 模块

static int l_sys_sleep(lua_State *L) {
    NSInteger ms = luaL_checkinteger(L, 1);
    [NSThread sleepForTimeInterval:(NSTimeInterval)ms / 1000.0];
    return 0;
}

static int l_sys_toast(lua_State *L) {
    const char *msg = luaL_checkstring(L, 1);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil
            message:[NSString stringWithUTF8String:msg]
            preferredStyle:UIAlertControllerStyleAlert];
        UIWindowScene *scene = (UIWindowScene *)[UIApplication sharedApplication].connectedScenes.allObjects.firstObject;
        [scene.keyWindow.rootViewController presentViewController:ac animated:YES completion:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [ac dismissViewControllerAnimated:YES completion:nil];
        });
    });
    return 0;
}

static int l_sys_info(lua_State *L) {
    UIDevice *d = [UIDevice currentDevice];
    CGSize ss = [UIScreen mainScreen].bounds.size;
    CGFloat scale = [UIScreen mainScreen].scale;
    
    lua_createtable(L, 0, 8);
    lua_pushstring(L, "name");       lua_pushstring(L, d.name.UTF8String);            lua_settable(L, -3);
    lua_pushstring(L, "model");      lua_pushstring(L, d.model.UTF8String);           lua_settable(L, -3);
    lua_pushstring(L, "systemName"); lua_pushstring(L, d.systemName.UTF8String);      lua_settable(L, -3);
    lua_pushstring(L, "systemVersion"); lua_pushstring(L, d.systemVersion.UTF8String); lua_settable(L, -3);
    lua_pushstring(L, "width");      lua_pushinteger(L, (lua_Integer)ss.width);       lua_settable(L, -3);
    lua_pushstring(L, "height");     lua_pushinteger(L, (lua_Integer)ss.height);      lua_settable(L, -3);
    lua_pushstring(L, "scale");      lua_pushnumber(L, scale);                        lua_settable(L, -3);
    lua_pushstring(L, "identifierForVendor"); lua_pushstring(L, d.identifierForVendor.UUIDString.UTF8String); lua_settable(L, -3);
    return 1;
}

static int l_sys_getScreenSize(lua_State *L) {
    CGSize ss = [UIScreen mainScreen].bounds.size;
    lua_pushnumber(L, ss.width);
    lua_pushnumber(L, ss.height);
    return 2;
}

static int l_sys_getBattery(lua_State *L) {
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    lua_pushnumber(L, [UIDevice currentDevice].batteryLevel);
    lua_pushinteger(L, (lua_Integer)[UIDevice currentDevice].batteryState);
    return 2;
}

static int l_sys_getIP(lua_State *L) {
    // 获取WiFi IP
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    NSString *ip = @"";
    if (getifaddrs(&interfaces) == 0) {
        temp_addr = interfaces;
        while (temp_addr) {
            if (temp_addr->ifa_addr->sa_family == AF_INET &&
                [[NSString stringWithUTF8String:temp_addr->ifa_name] isEqualToString:@"en0"]) {
                char addr[INET_ADDRSTRLEN];
                inet_ntop(AF_INET, &((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr, addr, sizeof(addr));
                ip = [NSString stringWithUTF8String:addr];
                break;
            }
            temp_addr = temp_addr->ifa_next;
        }
        freeifaddrs(interfaces);
    }
    lua_pushstring(L, ip.UTF8String);
    return 1;
}

#pragma mark - device 模块

static int l_device_info(lua_State *L) {
    UIDevice *d = [UIDevice currentDevice];
    CGSize ss = [UIScreen mainScreen].bounds.size;
    
    lua_createtable(L, 0, 6);
    lua_pushstring(L, "name");          lua_pushstring(L, d.name.UTF8String);            lua_settable(L, -3);
    lua_pushstring(L, "model");         lua_pushstring(L, d.model.UTF8String);           lua_settable(L, -3);
    lua_pushstring(L, "systemVersion"); lua_pushstring(L, d.systemVersion.UTF8String);   lua_settable(L, -3);
    lua_pushstring(L, "width");         lua_pushinteger(L, (lua_Integer)ss.width);       lua_settable(L, -3);
    lua_pushstring(L, "height");        lua_pushinteger(L, (lua_Integer)ss.height);      lua_settable(L, -3);
    lua_pushstring(L, "udid");          lua_pushstring(L, d.identifierForVendor.UUIDString.UTF8String); lua_settable(L, -3);
    return 1;
}

#pragma mark - JSON 模块

static int l_json_encode(lua_State *L) {
    // Lua table -> JSON string (简单实现)
    if (lua_type(L, 1) != LUA_TTABLE) {
        lua_pushstring(L, lua_tostring(L, 1));
        return 1;
    }
    
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    lua_pushnil(L);
    while (lua_next(L, 1)) {
        NSString *key = [NSString stringWithUTF8String:lua_tostring(L, -2)];
        if (lua_isnumber(L, -1)) {
            dict[key] = @(lua_tonumber(L, -1));
        } else if (lua_isboolean(L, -1)) {
            dict[key] = @(lua_toboolean(L, -1));
        } else {
            dict[key] = [NSString stringWithUTF8String:lua_tostring(L, -1) ?: ""];
        }
        lua_pop(L, 1);
    }
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (jsonData) {
        lua_pushstring(L, [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding].UTF8String);
    } else {
        lua_pushstring(L, "{}");
    }
    return 1;
}

static int l_json_decode(lua_State *L) {
    // JSON string -> Lua table (使用系统 NSJSONSerialization)
    const char *jsonStr = luaL_checkstring(L, 1);
    NSData *data = [[NSString stringWithUTF8String:jsonStr] dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) { lua_pushnil(L); return 1; }

    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || !obj) { lua_pushnil(L); return 1; }

    // 递归转换 NSObject -> Lua table
    _pushNSObjectToLua(L, obj);
    return 1;
}

/// 递归将 NSObject (NSDictionary/NSArray/NSString/NSNumber/NSNull) 推入 Lua 栈
static void _pushNSObjectToLua(lua_State *L, id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        lua_createtable(L, 0, (int)[obj count]);
        for (id key in obj) {
            _pushNSObjectToLua(L, key);       // 键
            _pushNSObjectToLua(L, obj[key]);  // 值
            lua_settable(L, -3);
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        lua_createtable(L, (int)[obj count], 0);
        for (NSUInteger i = 0; i < [obj count]; i++) {
            lua_pushinteger(L, (lua_Integer)(i + 1));
            _pushNSObjectToLua(L, obj[i]);
            lua_settable(L, -3);
        }
    } else if ([obj isKindOfClass:[NSString class]]) {
        lua_pushstring(L, [obj UTF8String]);
    } else if ([obj isKindOfClass:[NSNumber class]]) {
        if (strcmp([obj objCType], @encode(BOOL)) == 0) {
            lua_pushboolean(L, [obj boolValue]);
        } else {
            lua_pushnumber(L, [obj doubleValue]);
        }
    } else {
        lua_pushnil(L);
    }
}

#pragma mark - pasteboard 模块

static int l_pb_read(lua_State *L) {
    NSString *s = [UIPasteboard generalPasteboard].string;
    if (s) { lua_pushstring(L, s.UTF8String); }
    else   { lua_pushstring(L, ""); }
    return 1;
}

static int l_pb_write(lua_State *L) {
    const char *s = luaL_checkstring(L, 1);
    [UIPasteboard generalPasteboard].string = [NSString stringWithUTF8String:s];
    lua_pushboolean(L, 1);
    return 1;
}

static int l_pb_clear(lua_State *L) {
    [[UIPasteboard generalPasteboard] setString:@""];
    lua_pushboolean(L, 1);
    return 1;
}

static int l_pb_has(lua_State *L) {
    BOOL has = ([UIPasteboard generalPasteboard].string.length > 0);
    lua_pushboolean(L, has);
    return 1;
}

#pragma mark - plist 模块

static int l_plist_read(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    id obj = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithUTF8String:path]];
    if (!obj) obj = [NSArray arrayWithContentsOfFile:[NSString stringWithUTF8String:path]];
    if (!obj) { lua_pushnil(L); return 1; }
    _pushNSObjectToLua(L, obj);
    return 1;
}

static int l_plist_write(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    // 第二个参数需要是 table (会转为 NSDictionary)
    // 简化: 仅支持字符串写入
    NSDictionary *dict = nil;
    if (lua_istable(L, 2)) {
        NSMutableDictionary *md = [NSMutableDictionary dictionary];
        lua_pushnil(L);
        while (lua_next(L, 2)) {
            NSString *key = [NSString stringWithUTF8String:lua_tostring(L, -2)];
            if (lua_isnumber(L, -1)) {
                md[key] = @(lua_tonumber(L, -1));
            } else if (lua_isboolean(L, -1)) {
                md[key] = @(lua_toboolean(L, -1));
            } else {
                md[key] = [NSString stringWithUTF8String:lua_tostring(L, -1) ?: ""];
            }
            lua_pop(L, 1);
        }
        dict = md;
    } else if (lua_isstring(L, 2)) {
        dict = @{@"value": [NSString stringWithUTF8String:lua_tostring(L, 2)]};
    }
    BOOL ok = dict ? [dict writeToFile:[NSString stringWithUTF8String:path] atomically:YES] : NO;
    lua_pushboolean(L, ok);
    return 1;
}

#pragma mark - file 模块

static int l_file_exists(lua_State *L) {
    const char *p = luaL_checkstring(L, 1);
    lua_pushboolean(L, [[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithUTF8String:p]]);
    return 1;
}

static int l_file_size(lua_State *L) {
    const char *p = luaL_checkstring(L, 1);
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:[NSString stringWithUTF8String:p] error:nil];
    lua_pushinteger(L, (lua_Integer)[attr[NSFileSize] longLongValue]);
    return 1;
}

static int l_file_isDir(lua_State *L) {
    const char *p = luaL_checkstring(L, 1);
    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithUTF8String:p] isDirectory:&isDir];
    lua_pushboolean(L, isDir);
    return 1;
}

static int l_file_reads(lua_State *L) {
    const char *p = luaL_checkstring(L, 1);
    NSString *s = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:p] encoding:NSUTF8StringEncoding error:nil];
    lua_pushstring(L, s.UTF8String ?: "");
    return 1;
}

static int l_file_writes(lua_State *L) {
    const char *p = luaL_checkstring(L, 1);
    const char *s = luaL_checkstring(L, 2);
    BOOL ok = [[NSString stringWithUTF8String:s] writeToFile:[NSString stringWithUTF8String:p] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    lua_pushboolean(L, ok);
    return 1;
}

static int l_file_mkdir(lua_State *L) {
    const char *p = luaL_checkstring(L, 1);
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:p] withIntermediateDirectories:YES attributes:nil error:nil];
    lua_pushboolean(L, ok);
    return 1;
}

static int l_file_delete(lua_State *L) {
    const char *p = luaL_checkstring(L, 1);
    BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:p] error:nil];
    lua_pushboolean(L, ok);
    return 1;
}

static int l_file_list(lua_State *L) {
    const char *p = luaL_checkstring(L, 1);
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[NSString stringWithUTF8String:p] error:nil];
    lua_createtable(L, (int)items.count, 0);
    for (NSUInteger i = 0; i < items.count; i++) {
        lua_pushinteger(L, (lua_Integer)(i + 1));
        lua_pushstring(L, [items[i] UTF8String]);
        lua_settable(L, -3);
    }
    return 1;
}

#pragma mark - key 模块

static int l_key_press(lua_State *L) {
    const char *action = luaL_checkstring(L, 1);
    TSKeyboardInjector *kb = [TSKeyboardInjector shared];
    NSString *a = [NSString stringWithUTF8String:action];
    if ([a isEqualToString:@"home"])         [kb pressHome];
    else if ([a isEqualToString:@"lock"])    [kb pressLock];
    else if ([a isEqualToString:@"volumeup"])  [kb pressVolumeUp];
    else if ([a isEqualToString:@"volumedown"])[kb pressVolumeDown];
    else if ([a isEqualToString:@"home2x"])    [kb doublePressHome];
    else { lua_pushboolean(L, 0); return 1; }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_key_sendText(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    BOOL ok = [[TSKeyboardInjector shared] inputText:[NSString stringWithUTF8String:text]];
    lua_pushboolean(L, ok);
    return 1;
}

#pragma mark - string 扩展模块

static int l_str_md5(lua_State *L) {
    const char *s = luaL_checkstring(L, 1);
    NSData *d = [[NSString stringWithUTF8String:s] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *ms = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [ms appendFormat:@"%02x", digest[i]];
    lua_pushstring(L, ms.UTF8String);
    return 1;
}

static int l_str_sha256(lua_State *L) {
    const char *s = luaL_checkstring(L, 1);
    NSData *d = [[NSString stringWithUTF8String:s] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *ms = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [ms appendFormat:@"%02x", digest[i]];
    lua_pushstring(L, ms.UTF8String);
    return 1;
}

static int l_str_base64Encode(lua_State *L) {
    const char *s = luaL_checkstring(L, 1);
    NSData *d = [[NSString stringWithUTF8String:s] dataUsingEncoding:NSUTF8StringEncoding];
    lua_pushstring(L, [d base64EncodedStringWithOptions:0].UTF8String);
    return 1;
}

static int l_str_base64Decode(lua_State *L) {
    const char *s = luaL_checkstring(L, 1);
    NSData *d = [[NSData alloc] initWithBase64EncodedString:[NSString stringWithUTF8String:s] options:0];
    NSString *dec = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"";
    lua_pushstring(L, dec.UTF8String ?: "");
    return 1;
}

static int l_str_trim(lua_State *L) {
    const char *s = luaL_checkstring(L, 1);
    NSString *r = [[NSString stringWithUTF8String:s] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    lua_pushstring(L, r.UTF8String);
    return 1;
}

static int l_str_split(lua_State *L) {
    const char *str = luaL_checkstring(L, 1);
    const char *sep = luaL_checkstring(L, 2);
    NSArray *parts = [[NSString stringWithUTF8String:str] componentsSeparatedByString:[NSString stringWithUTF8String:sep]];
    lua_createtable(L, (int)parts.count, 0);
    for (NSUInteger i = 0; i < parts.count; i++) {
        lua_pushinteger(L, (lua_Integer)(i + 1));
        lua_pushstring(L, [parts[i] UTF8String]);
        lua_settable(L, -3);
    }
    return 1;
}

static int l_str_random(lua_State *L) {
    int lo = (int)luaL_checkinteger(L, 1);
    int hi = (int)luaL_checkinteger(L, 2);
    if (lo > hi) { int t = lo; lo = hi; hi = t; }
    lua_pushinteger(L, lo + arc4random_uniform((uint32_t)(hi - lo + 1)));
    return 1;
}

#pragma mark - appNode 模块(UI 层次遍历)

/// 递归遍历视图树，输出为 Lua table
static void _traverseView(UIView *view, lua_State *L) {
    lua_createtable(L, 0, 12);
    
    // 基本信息
    lua_pushstring(L, "class");    lua_pushstring(L, NSStringFromClass([view class]).UTF8String); lua_settable(L, -3);
    lua_pushstring(L, "superClass"); lua_pushstring(L, NSStringFromClass([[view class] superclass]).UTF8String); lua_settable(L, -3);
    
    // 位置与大小
    CGRect f = view.frame;
    lua_pushstring(L, "x");       lua_pushnumber(L, f.origin.x);     lua_settable(L, -3);
    lua_pushstring(L, "y");       lua_pushnumber(L, f.origin.y);     lua_settable(L, -3);
    lua_pushstring(L, "width");   lua_pushnumber(L, f.size.width);   lua_settable(L, -3);
    lua_pushstring(L, "height");  lua_pushnumber(L, f.size.height);  lua_settable(L, -3);
    
    // Accessibility
    lua_pushstring(L, "text");    lua_pushstring(L, view.accessibilityLabel.UTF8String ?: ""); lua_settable(L, -3);
    lua_pushstring(L, "lable");   lua_pushstring(L, view.accessibilityLabel.UTF8String ?: ""); lua_settable(L, -3);
    lua_pushstring(L, "isHidden"); lua_pushboolean(L, view.isHidden); lua_settable(L, -3);
    lua_pushstring(L, "alpha");   lua_pushnumber(L, view.alpha);     lua_settable(L, -3);
    lua_pushstring(L, "address"); lua_pushinteger(L, (lua_Integer)(uintptr_t)view); lua_settable(L, -3);
    
    // 子视图
    NSArray *subviews = view.subviews;
    lua_pushstring(L, "subviews");
    lua_createtable(L, (int)subviews.count, 0);
    for (NSUInteger i = 0; i < subviews.count; i++) {
        _traverseView(subviews[i], L);
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
    lua_settable(L, -3);
}

static int l_appNode_info(lua_State *L) {
    __block int result = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIWindowScene *scene = (UIWindowScene *)[UIApplication sharedApplication].connectedScenes.allObjects.firstObject;
        UIView *rootView = scene.keyWindow;
        if (!rootView) { lua_pushnil(L); result = 1; return; }
        
        _traverseView(rootView, L);
        result = 1;
    });
    return result;
}

#pragma mark - app 模块(应用管理)

static int l_app_frontBid(lua_State *L) {
    NSString *bid = [[TSAppManager shared] frontBid];
    if (bid) {
        lua_pushstring(L, bid.UTF8String);
        lua_pushinteger(L, (lua_Integer)[[TSAppManager shared] frontPid]);
        return 2;
    }
    lua_pushnil(L);
    return 1;
}

static int l_app_isInstalled(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    lua_pushboolean(L, [[TSAppManager shared] isInstalled:[NSString stringWithUTF8String:bid]]);
    return 1;
}

static int l_app_isRunning(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    lua_pushboolean(L, [[TSAppManager shared] isRunning:[NSString stringWithUTF8String:bid]]);
    return 1;
}

static int l_app_open(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    lua_pushboolean(L, [[TSAppManager shared] openApp:[NSString stringWithUTF8String:bid]]);
    return 1;
}

static int l_app_close(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    lua_pushboolean(L, [[TSAppManager shared] closeApp:[NSString stringWithUTF8String:bid]]);
    return 1;
}

static int l_app_uninstall(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    lua_pushboolean(L, [[TSAppManager shared] uninstallApp:[NSString stringWithUTF8String:bid]]);
    return 1;
}

static int l_app_install(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_pushboolean(L, [[TSAppManager shared] installIPA:[NSString stringWithUTF8String:path]]);
    return 1;
}

static int l_app_openUrl(lua_State *L) {
    const char *url = luaL_checkstring(L, 1);
    lua_pushboolean(L, [[TSAppManager shared] openURL:[NSString stringWithUTF8String:url]]);
    return 1;
}

static int l_app_inputText(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    lua_pushboolean(L, [[TSAppManager shared] inputText:[NSString stringWithUTF8String:text]]);
    return 1;
}

static int l_app_info(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    TSAppInfo *info = [[TSAppManager shared] appInfo:[NSString stringWithUTF8String:bid]];
    
    lua_createtable(L, 0, 0);
    lua_pushstring(L, "bundleId");   lua_pushstring(L, info.bundleId.UTF8String);   lua_settable(L, -3);
    lua_pushstring(L, "name");       lua_pushstring(L, info.name.UTF8String);       lua_settable(L, -3);
    lua_pushstring(L, "version");    lua_pushstring(L, info.version.UTF8String);    lua_settable(L, -3);
    lua_pushstring(L, "bundlePath"); lua_pushstring(L, info.bundlePath.UTF8String ?: ""); lua_settable(L, -3);
    lua_pushstring(L, "dataPath");   lua_pushstring(L, info.dataPath.UTF8String ?: "");   lua_settable(L, -3);
    lua_pushstring(L, "pid");        lua_pushinteger(L, info.pid);                  lua_settable(L, -3);
    return 1;
}

#pragma mark - 模块注册

static const luaL_Reg touch_lib[] = {
    {"tap", l_touch_tap},
    {"down", l_touch_down},
    {"move", l_touch_move},
    {"up", l_touch_up},
    {"swipe", l_touch_swipe},
    {"stroke", l_touch_stroke},
    {NULL, NULL}
};

static const luaL_Reg screen_lib[] = {
    {"capture", l_screen_capture},
    {"getColor", l_screen_getColor},
    {"findColor", l_screen_findColor},
    {"findColors", l_screen_findColors},
    // findImage 见 TSTemplateMatcher
    {NULL, NULL}
};

static const luaL_Reg sys_lib[] = {
    {"msleep", l_sys_sleep},
    {"sleep", l_sys_sleep},
    {"toast", l_sys_toast},
    {"info", l_sys_info},
    {"getScreenSize", l_sys_getScreenSize},
    {"getBattery", l_sys_getBattery},
    {"getIP", l_sys_getIP},
    {NULL, NULL}
};

static const luaL_Reg device_lib[] = {
    {"info", l_device_info},
    {NULL, NULL}
};

static const luaL_Reg json_lib[] = {
    {"encode", l_json_encode},
    {"decode", l_json_decode},
    {NULL, NULL}
};

static const luaL_Reg pasteboard_lib[] = {
    {"read",  l_pb_read},
    {"write", l_pb_write},
    {"clear", l_pb_clear},
    {"has",   l_pb_has},
    {NULL, NULL}
};

static const luaL_Reg plist_lib[] = {
    {"read",  l_plist_read},
    {"write", l_plist_write},
    {NULL, NULL}
};

static const luaL_Reg file_lib[] = {
    {"exists", l_file_exists},
    {"size",   l_file_size},
    {"isDir",  l_file_isDir},
    {"reads",  l_file_reads},
    {"writes", l_file_writes},
    {"mkdir",  l_file_mkdir},
    {"delete", l_file_delete},
    {"list",   l_file_list},
    {NULL, NULL}
};

static const luaL_Reg key_lib[] = {
    {"press",    l_key_press},
    {"sendText", l_key_sendText},
    {NULL, NULL}
};

static const luaL_Reg str_lib[] = {
    {"md5",          l_str_md5},
    {"sha256",       l_str_sha256},
    {"base64Encode", l_str_base64Encode},
    {"base64Decode", l_str_base64Decode},
    {"trim",         l_str_trim},
    {"split",        l_str_split},
    {"random",       l_str_random},
    {NULL, NULL}
};

static const luaL_Reg appNode_lib[] = {
    {"info", l_appNode_info},
    {NULL, NULL}
};

static const luaL_Reg app_lib[] = {
    {"frontBid",    l_app_frontBid},
    {"isInstalled", l_app_isInstalled},
    {"isRunning",   l_app_isRunning},
    {"open",        l_app_open},
    {"close",       l_app_close},
    {"uninstall",   l_app_uninstall},
    {"install",     l_app_install},
    {"openUrl",     l_app_openUrl},
    {"inputText",   l_app_inputText},
    {"info",        l_app_info},
    {NULL, NULL}
};

/// 向全局注册一个命名的原生模块
static void l_registerLib(lua_State *L, const char *name, const luaL_Reg *lib) {
    luaL_newlib(L, lib);
    lua_setglobal(L, name);
}

#pragma mark - TSLuaBridge 实现

@implementation TSLuaBridge {
    lua_State *_L;
}

+ (instancetype)shared {
    static TSLuaBridge *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[TSLuaBridge alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _L = luaL_newstate();
        luaL_openlibs(_L);
        
        // 设置模块搜索路径: 脚本目录
        NSString *docPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        lua_getglobal(_L, "package");
        lua_getfield(_L, -1, "path");
        const char *oldPath = lua_tostring(_L, -1);
        NSString *newPath = [NSString stringWithFormat:@"%s;%@/?.lua;%@/svip/lib/?.lua",
                             oldPath, docPath, [[NSBundle mainBundle] bundlePath]];
        lua_pop(_L, 1);
        lua_pushstring(_L, newPath.UTF8String);
        lua_setfield(_L, -2, "path");
        lua_pop(_L, 1);
        
        // 注册所有原生模块
        l_registerLib(_L, "touch", touch_lib);
        l_registerLib(_L, "screen", screen_lib);
        l_registerLib(_L, "sys", sys_lib);
        l_registerLib(_L, "device", device_lib);
        l_registerLib(_L, "json", json_lib);
        l_registerLib(_L, "appNode", appNode_lib);
        l_registerLib(_L, "app", app_lib);
        l_registerLib(_L, "pasteboard", pasteboard_lib);
        l_registerLib(_L, "plist", plist_lib);
        l_registerLib(_L, "file", file_lib);
        l_registerLib(_L, "key", key_lib);
        l_registerLib(_L, "str", str_lib);
        
        // 兼容旧版脚本 API: findColor / tap / mSleep 全局函数
        lua_register(_L, "findColor", l_screen_findColor);
        lua_register(_L, "getColor",  l_screen_getColor);
        lua_register(_L, "tap",       l_touch_tap);
        lua_register(_L, "swipe",     l_touch_swipe);
        lua_register(_L, "mSleep",    l_sys_sleep);
        lua_register(_L, "toast",     l_sys_toast);
        lua_register(_L, "snapshot",  l_screen_capture);
    }
    return self;
}

- (void)dealloc {
    if (_L) { lua_close(_L); _L = NULL; }
}

- (void)runFile:(NSString *)path {
    if (!_L) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (luaL_dofile(_L, path.UTF8String) != LUA_OK) {
            const char *err = lua_tostring(_L, -1);
            NSLog(@"[Lua] 错误: %s", err ?: "unknown");
            lua_pop(_L, 1);
        }
    });
}

- (void)runString:(NSString *)code {
    if (!_L) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (luaL_dostring(_L, code.UTF8String) != LUA_OK) {
            const char *err = lua_tostring(_L, -1);
            NSLog(@"[Lua] 错误: %s", err ?: "unknown");
            lua_pop(_L, 1);
        }
    });
}

- (void)stop {
    // Lua 脚本无法从外部优雅停止，建议在脚本中使用 coroutine.yield
}

@end
*/

// Stub 实现 —— 在未集成 Lua 5.4 源码时保证编译通过。
// 集成后请删除下方 stub，并取消上方注释中的完整实现。

@implementation TSLuaBridge

+ (instancetype)shared {
    static TSLuaBridge *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[TSLuaBridge alloc] init]; });
    return instance;
}

- (void)runFile:(NSString *)path {
    NSLog(@"[LuaBridge] Lua 引擎未集成。请将 lua-5.4.x 源码加入工程并替换此 stub 实现。");
}

- (void)runString:(NSString *)code {
    NSLog(@"[LuaBridge] Lua 引擎未集成。");
}

- (void)stop {
}

@end
