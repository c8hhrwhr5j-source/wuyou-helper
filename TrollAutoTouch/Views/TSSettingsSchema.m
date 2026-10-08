//
//  TSSettingsSchema.m
//  TrollAutoTouch
//
//  schema.lua 文件或 ui.openForm 传入的 table -> TSSettingsSchema 模型。
//  本文件允许 #import lua.h (其他 View 层文件不要 import, 保持分层)。
//

#import "TSSettingsSchema.h"
#import "TSPaths.h"
#import "lua.h"
#import "lauxlib.h"
#import "lualib.h"

#pragma mark - 错误域
static NSString * const TSSettingsSchemaErrorDomain = @"TSSettingsSchemaError";

#pragma mark - TSSettingsRow

@implementation TSSettingsRow
- (instancetype)init {
    if ((self = [super init])) {
        _minValue = 0;
        _maxValue = 1;
        _step = 0;
        _showValueInline = YES;
        _dateMode = TSSettingsDateModeDateTime;
        _luaCallbackRef = LUA_NOREF;
    }
    return self;
}
@end

@implementation TSSettingsSection
@end

#pragma mark - 辅助: 安全的 Lua 取值

/// 从 table at idx 读取 string 字段; 不存在/类型不匹配返回 nil
static NSString *_Nullable tsSchema_getStringField(lua_State *L, int idx, const char *field) {
    lua_getfield(L, idx, field);
    NSString *ret = nil;
    if (lua_isstring(L, -1)) {
        const char *s = lua_tostring(L, -1);
        if (s) ret = [NSString stringWithUTF8String:s];
    }
    lua_pop(L, 1);
    return ret;
}

/// 从 table at idx 读取 number 字段; 不存在/类型不匹配返回 def
static double tsSchema_getNumberField(lua_State *L, int idx, const char *field, double def) {
    lua_getfield(L, idx, field);
    double ret = def;
    if (lua_isnumber(L, -1)) ret = lua_tonumber(L, -1);
    lua_pop(L, 1);
    return ret;
}

/// 从 table at idx 读取 boolean 字段; 不存在/类型不匹配返回 def
static BOOL tsSchema_getBoolField(lua_State *L, int idx, const char *field, BOOL def) {
    lua_getfield(L, idx, field);
    BOOL ret = def;
    if (lua_isboolean(L, -1)) ret = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return ret;
}

/// 从 table at idx 读取 string array 字段 (元素必须是 string); 失败返回 nil
static NSArray<NSString *> *_Nullable tsSchema_getStringArrayField(lua_State *L, int idx, const char *field) {
    lua_getfield(L, idx, field);
    NSMutableArray<NSString *> *out = nil;
    if (lua_istable(L, -1)) {
        out = [NSMutableArray array];
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
            // stack: table, key, value
            if (lua_isstring(L, -1)) {
                const char *s = lua_tostring(L, -1);
                if (s) [out addObject:[NSString stringWithUTF8String:s]];
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);
    return out;
}

/// 从 table at idx 读取任意 Lua 值, 转成 ObjC id (NSDictionary/NSArray/NSString/NSNumber)
/// 供 defaultValue / currentValue / visibleWhenValue 使用
static id _Nullable tsSchema_getLuaValue(lua_State *L, int idx) {
    if (lua_isnil(L, idx)) return nil;
    if (lua_isboolean(L, idx)) return @(lua_toboolean(L, idx));
    if (lua_isnumber(L, idx)) return @(lua_tonumber(L, idx));
    if (lua_isstring(L, idx)) {
        const char *s = lua_tostring(L, idx);
        return s ? [NSString stringWithUTF8String:s] : nil;
    }
    if (lua_istable(L, idx)) {
        // 判断是 array 还是 dict: 检查键是否全是 1..n
        BOOL isArray = YES;
        int n = 0;
        lua_pushnil(L);
        while (lua_next(L, idx) != 0) {
            n++;
            if (!lua_isnumber(L, -2)) { isArray = NO; lua_pop(L, 1); break; }
            int k = (int)lua_tointeger(L, -2);
            if (k != n) { isArray = NO; lua_pop(L, 1); break; }
            lua_pop(L, 1);
        }
        if (isArray && n > 0) {
            NSMutableArray *arr = [NSMutableArray arrayWithCapacity:n];
            for (int i = 1; i <= n; i++) {
                lua_rawgeti(L, idx, i);
                id v = tsSchema_getLuaValue(L, lua_gettop(L));
                if (v) [arr addObject:v];
                lua_pop(L, 1);
            }
            return arr;
        } else {
            // dict
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            lua_pushnil(L);
            while (lua_next(L, idx) != 0) {
                if (lua_isstring(L, -2)) {
                    const char *k = lua_tostring(L, -2);
                    id v = tsSchema_getLuaValue(L, lua_gettop(L));
                    if (k && v) dict[[NSString stringWithUTF8String:k]] = v;
                }
                lua_pop(L, 1);
            }
            return dict;
        }
    }
    return nil;
}

#pragma mark - 行解析

/// 解析一行 (table at idx) -> TSSettingsRow. 失败返回 nil
static TSSettingsRow *_Nullable tsSchema_parseRow(lua_State *L, int idx, NSError **error) {
    // idx 必须为正 (绝对索引)
    NSString *typeStr = tsSchema_getStringField(L, idx, "type");
    if (typeStr.length == 0) {
        if (error) *error = [NSError errorWithDomain:TSSettingsSchemaErrorDomain
                                                  code:1
                                              userInfo:@{NSLocalizedDescriptionKey: @"row 缺少 type 字段"}];
        return nil;
    }

    TSSettingsRowType type = 0;
    if ([typeStr isEqualToString:@"switch"])        type = TSSettingsRowTypeSwitch;
    else if ([typeStr isEqualToString:@"stepper"])  type = TSSettingsRowTypeStepper;
    else if ([typeStr isEqualToString:@"slider"])   type = TSSettingsRowTypeSlider;
    else if ([typeStr isEqualToString:@"segmented"]) type = TSSettingsRowTypeSegmented;
    else if ([typeStr isEqualToString:@"select"])   type = TSSettingsRowTypeSelect;
    else if ([typeStr isEqualToString:@"text"])     type = TSSettingsRowTypeText;
    else if ([typeStr isEqualToString:@"textLong"]) type = TSSettingsRowTypeTextLong;
    else if ([typeStr isEqualToString:@"number"])   type = TSSettingsRowTypeNumber;
    else if ([typeStr isEqualToString:@"date"])     type = TSSettingsRowTypeDate;
    else if ([typeStr isEqualToString:@"duration"]) type = TSSettingsRowTypeDuration;
    else if ([typeStr isEqualToString:@"color"])    type = TSSettingsRowTypeColor;
    else if ([typeStr isEqualToString:@"multi"])    type = TSSettingsRowTypeMulti;
    else if ([typeStr isEqualToString:@"action"])   type = TSSettingsRowTypeAction;
    else if ([typeStr isEqualToString:@"info"])     type = TSSettingsRowTypeInfo;
    else if ([typeStr isEqualToString:@"checkbox"])  type = TSSettingsRowTypeCheckbox;
    else {
        if (error) *error = [NSError errorWithDomain:TSSettingsSchemaErrorDomain
                                                  code:2
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"未知的 type: %@", typeStr]}];
        return nil;
    }

    TSSettingsRow *row = [[TSSettingsRow alloc] init];
    row.type = type;

    if (type == TSSettingsRowTypeInfo) {
        // info 行只有 text 字段, 无 key
        lua_getfield(L, idx, "text");
        if (lua_isstring(L, -1)) {
            const char *s = lua_tostring(L, -1);
            if (s) row.label = [NSString stringWithUTF8String:s];
        }
        lua_pop(L, 1);
        return row.label.length ? row : nil;
    }

    row.key   = tsSchema_getStringField(L, idx, "key");
    row.label = tsSchema_getStringField(L, idx, "label");
    if (row.key.length == 0 || row.label.length == 0) {
        if (error) *error = [NSError errorWithDomain:TSSettingsSchemaErrorDomain
                                                  code:3
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                            @"row 必须有 key 和 label 字段"}];
        return nil;
    }
    row.placeholder = tsSchema_getStringField(L, idx, "placeholder");

    // default
    lua_getfield(L, idx, "default");
    if (!lua_isnil(L, -1)) {
        row.defaultValue = tsSchema_getLuaValue(L, lua_gettop(L));
    }
    lua_pop(L, 1);

    // 数值
    row.minValue = tsSchema_getNumberField(L, idx, "min", 0);
    row.maxValue = tsSchema_getNumberField(L, idx, "max", 1);
    if (row.maxValue < row.minValue) row.maxValue = row.minValue + 1;
    row.step    = tsSchema_getNumberField(L, idx, "step", 0);
    row.format  = tsSchema_getStringField(L, idx, "format");
    row.showValueInline = tsSchema_getBoolField(L, idx, "showValue", YES);
    if (type == TSSettingsRowTypeStepper) {
        // stepper 默认 step=1
        if (row.step <= 0) row.step = 1;
    }

    // options
    row.options = tsSchema_getStringArrayField(L, idx, "options");
    if (type == TSSettingsRowTypeSegmented && row.options.count > 5) {
        // 分段控件最多 5 项, 多的截断 (iOS UISegmentedControl 上限)
        row.options = [row.options subarrayWithRange:NSMakeRange(0, 5)];
    }

    // keyboard
    row.keyboardType = tsSchema_getStringField(L, idx, "keyboard");

    // date mode
    NSString *dm = tsSchema_getStringField(L, idx, "mode");
    if ([dm isEqualToString:@"date"]) row.dateMode = TSSettingsDateModeDate;
    else if ([dm isEqualToString:@"time"]) row.dateMode = TSSettingsDateModeTime;
    else row.dateMode = TSSettingsDateModeDateTime;

    // duration
    row.unit = tsSchema_getStringField(L, idx, "unit");
    if (type == TSSettingsRowTypeDuration && row.unit.length == 0) row.unit = @"秒";

    // color
    if (type == TSSettingsRowTypeColor) {
        if (!row.defaultValue) {
            // default 也可由 color 字段提供
            NSString *hex = tsSchema_getStringField(L, idx, "color");
            if (hex) row.defaultValue = hex;
        }
    }

    // multi
    if (type == TSSettingsRowTypeMulti) {
        row.multiOptions = row.options;
        row.options = nil;
        if (!row.defaultValue) row.defaultValue = @[];
    }

    // checkbox: 无 default 时默认 false, 保证保存时键一定写入 settings.json
    //   (switch 无 default 时 currentValue 为 nil 不落盘, checkbox 场景是任务清单,
    //    每个 key 都应存在, 这里补 @NO)
    if (type == TSSettingsRowTypeCheckbox) {
        if (![row.defaultValue isKindOfClass:[NSNumber class]]) row.defaultValue = @NO;
    }

    // action 回调
    if (type == TSSettingsRowTypeAction) {
        lua_getfield(L, idx, "onTap");
        if (lua_isfunction(L, -1)) {
            // 把函数注册到 registry, 返回 ref
            lua_pushvalue(L, -1);     // dup 函数
            row.luaCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX);
        }
        lua_pop(L, 1);
    }

    // 依赖显示
    row.visibleWhenKey = tsSchema_getStringField(L, idx, "visibleWhen");
    if (row.visibleWhenKey.length) {
        lua_getfield(L, idx, "visibleWhenValue");
        if (!lua_isnil(L, -1)) {
            row.visibleWhenValue = tsSchema_getLuaValue(L, lua_gettop(L));
        }
        lua_pop(L, 1);
    }

    // 校验
    row.validatorType = tsSchema_getStringField(L, idx, "validator");
    row.validatorMessage = tsSchema_getStringField(L, idx, "validatorMessage");

    // segmented/select 默认值
    if ((type == TSSettingsRowTypeSegmented || type == TSSettingsRowTypeSelect)
        && !row.defaultValue && row.options.count > 0) {
        row.defaultValue = row.options.firstObject;
    }

    return row;
}

#pragma mark - section 解析

static TSSettingsSection *_Nullable tsSchema_parseSection(lua_State *L, int idx, NSError **error) {
    if (!lua_istable(L, idx)) {
        if (error) *error = [NSError errorWithDomain:TSSettingsSchemaErrorDomain
                                                  code:4
                                              userInfo:@{NSLocalizedDescriptionKey: @"section 不是 table"}];
        return nil;
    }
    TSSettingsSection *s = [[TSSettingsSection alloc] init];
    s.title = tsSchema_getStringField(L, idx, "title");
    s.footer = tsSchema_getStringField(L, idx, "footer");

    NSMutableArray<TSSettingsRow *> *rows = [NSMutableArray array];
    lua_getfield(L, idx, "rows");
    if (lua_istable(L, -1)) {
        int n = (int)lua_rawlen(L, -1);
        for (int i = 1; i <= n; i++) {
            lua_rawgeti(L, -1, i);
            if (lua_istable(L, -1)) {
                NSError *rowErr = nil;
                TSSettingsRow *r = tsSchema_parseRow(L, lua_gettop(L), &rowErr);
                if (r) [rows addObject:r];
                else if (rowErr) {
                    NSLog(@"[SettingsSchema] 跳过一行: %@", rowErr.localizedDescription);
                }
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    s.rows = rows;
    return s;
}

#pragma mark - TSSettingsSchema

@implementation TSSettingsSchema

+ (nullable NSString *)schemaFilePathForScriptName:(NSString *)name {
    if (name.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    // 设备目录
    NSString *devPath = [[[[TSPaths luaDir] stringByAppendingPathComponent:@"ui"]
                          stringByAppendingPathComponent:name]
                         stringByAppendingPathComponent:@"schema.lua"];
    if ([fm fileExistsAtPath:devPath]) return devPath;
    // 内置 bundle
    NSString *bundlePath = [[[[[NSBundle mainBundle] resourcePath]
                              stringByAppendingPathComponent:@"www"]
                             stringByAppendingPathComponent:@"ui"]
                            stringByAppendingPathComponent:name];
    bundlePath = [bundlePath stringByAppendingPathComponent:@"schema.lua"];
    if ([fm fileExistsAtPath:bundlePath]) return bundlePath;
    return nil;
}

+ (nullable instancetype)loadSchemaForScriptName:(NSString *)name
                                       luaState:(void *)luaState
                                           error:(NSError **)error {
    lua_State *L = (lua_State *)luaState;
    NSString *path = [self schemaFilePathForScriptName:name];
    if (!path) {
        if (error) *error = [NSError errorWithDomain:TSSettingsSchemaErrorDomain
                                                  code:100
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"未找到 %@ 的 schema.lua", name]}];
        return nil;
    }
    // 加载并执行 schema.lua, 期望返回一个 table
    int err = luaL_loadfile(L, path.UTF8String);
    if (err != 0) {
        NSString *msg = [NSString stringWithUTF8String:lua_tostring(L, -1)];
        lua_pop(L, 1);
        if (error) *error = [NSError errorWithDomain:TSSettingsSchemaErrorDomain
                                                  code:101
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"加载 schema.lua 失败: %@", msg]}];
        return nil;
    }
    err = lua_pcall(L, 0, 1, 0);
    if (err != 0) {
        NSString *msg = [NSString stringWithUTF8String:lua_tostring(L, -1)];
        lua_pop(L, 1);
        if (error) *error = [NSError errorWithDomain:TSSettingsSchemaErrorDomain
                                                  code:102
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"执行 schema.lua 失败: %@", msg]}];
        return nil;
    }
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        if (error) *error = [NSError errorWithDomain:TSSettingsSchemaErrorDomain
                                                  code:103
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                            @"schema.lua 必须 return 一个 table"}];
        return nil;
    }
    // stack top: schema table
    TSSettingsSchema *schema = [self schemaFromLuaState:L
                                          topTableIndex:lua_gettop(L)
                                             scriptName:name
                                                  error:error];
    lua_pop(L, 1);  // 弹出 schema table
    return schema;
}

+ (nullable instancetype)schemaFromLuaState:(void *)luaState
                              topTableIndex:(int)idx
                                 scriptName:(NSString *)name
                                      error:(NSError **)error {
    lua_State *L = (lua_State *)luaState;
    if (idx < 0) idx = lua_gettop(L) + idx + 1;  // 支持负索引
    if (!lua_istable(L, idx)) {
        if (error) *error = [NSError errorWithDomain:TSSettingsSchemaErrorDomain
                                                  code:200
                                              userInfo:@{NSLocalizedDescriptionKey: @"schema 不是 table"}];
        return nil;
    }
    TSSettingsSchema *s = [[TSSettingsSchema alloc] init];
    s.scriptName = [name copy];
    s.title = tsSchema_getStringField(L, idx, "title");
    if (s.title.length == 0) s.title = name;

    NSMutableArray<TSSettingsSection *> *sections = [NSMutableArray array];
    // 两种 schema 形态:
    //   A) {sections = {{title, rows={...}}, ...}}  —— 显式分组
    //   B) {{title, rows={...}}, ...}  直接是 sections 数组
    lua_getfield(L, idx, "sections");
    int tableIdx;
    if (lua_istable(L, -1)) {
        tableIdx = (int)lua_gettop(L);
    } else {
        lua_pop(L, 1);
        tableIdx = idx;  // 直接是数组
    }

    int n = (int)lua_rawlen(L, tableIdx);
    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, tableIdx, i);
        if (lua_istable(L, -1)) {
            NSError *secErr = nil;
            TSSettingsSection *sec = tsSchema_parseSection(L, (int)lua_gettop(L), &secErr);
            if (sec) [sections addObject:sec];
            else if (secErr) {
                NSLog(@"[SettingsSchema] 跳过一组: %@", secErr.localizedDescription);
            }
        }
        lua_pop(L, 1);
    }
    if (tableIdx != idx) lua_pop(L, 1);  // 弹出 "sections" table

    s.sections = sections;
    return s;
}

- (NSArray<TSSettingsRow *> *)allVisibleRows {
    NSMutableArray *out = [NSMutableArray array];
    for (TSSettingsSection *s in self.sections) {
        for (TSSettingsRow *r in s.rows) {
            if (r.hiddenByDependency) continue;
            [out addObject:r];
        }
    }
    return out;
}

@end
