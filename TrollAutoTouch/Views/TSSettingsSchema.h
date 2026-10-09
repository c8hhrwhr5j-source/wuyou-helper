//
//  TSSettingsSchema.h
//  TrollAutoTouch
//
//  UIKit 原生设置 UI 的 schema 数据模型。
//
//  脚本可通过两种方式声明设置:
//    1) 文件约定: 在 /var/mobile/touch/lua/ui/<脚本名>/schema.lua 写一个返回
//       {sections = {...}} 的 Lua 表 (由 TSLuaBridge 加载后传入 +schemaFromLuaState:)
//    2) 动态传入: ui.openForm("name", schemaTable) —— schemaTable 结构同 (1)
//
//  存储层完全复用现有 settings.json, 控件的当前值由 -loadValuesFromJSON: 写入
//  currentValue, 保存时回写同一文件, 与 HTML 设置 UI 兼容。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 行控件类型
typedef NS_ENUM(NSInteger, TSSettingsRowType) {
    TSSettingsRowTypeSwitch    = 1,  // 开关 (bool)
    TSSettingsRowTypeStepper   = 2,  // 整数步进
    TSSettingsRowTypeSlider    = 3,  // 连续滑块
    TSSettingsRowTypeSegmented = 4,  // 分段选择 (2~5 项)
    TSSettingsRowTypeSelect    = 5,  // 单选 (下拉菜单, iOS14+; HUD 承载时回退二级列表)
    TSSettingsRowTypeText      = 6,  // 单行文本
    TSSettingsRowTypeTextLong  = 7,  // 多行文本
    TSSettingsRowTypeNumber    = 8,  // 数字输入
    TSSettingsRowTypeDate      = 9,  // 日期/时间
    TSSettingsRowTypeDuration  = 10, // 时长 (countDownTimer)
    TSSettingsRowTypeColor     = 11, // 取色器
    TSSettingsRowTypeMulti     = 12, // 多选列表
    TSSettingsRowTypeAction    = 13, // 动作按钮
    TSSettingsRowTypeInfo      = 14, // 静态说明文字
    TSSettingsRowTypeCheckbox  = 15, // 复选框 (bool, 右侧色块, 点击整行可切换)
    TSSettingsRowTypeCheckGroup = 16, // 复选框组 (多选, 每行 N 个色块按钮, 点击名字变色)
};

typedef NS_ENUM(NSInteger, TSSettingsDateMode) {
    TSSettingsDateModeDateTime = 0,  // 日期+时间
    TSSettingsDateModeDate     = 1,  // 仅日期
    TSSettingsDateModeTime     = 2,  // 仅时间
};

/// 单行设置 (一个控件)
@interface TSSettingsRow : NSObject

// ── 通用 ──
@property (nonatomic, assign) TSSettingsRowType type;
@property (nonatomic, copy)   NSString *key;             // 写入 settings.json 的字段名
@property (nonatomic, copy)   NSString *label;           // 显示标签
@property (nonatomic, copy, nullable) NSString *placeholder;
@property (nonatomic, strong, nullable) id defaultValue; // schema 声明的默认值

// ── stepper / slider / number 数值范围 ──
@property (nonatomic, assign) double minValue;
@property (nonatomic, assign) double maxValue;
@property (nonatomic, assign) double step;               // 0 = 不限步长
@property (nonatomic, copy, nullable) NSString *format;  // 数字格式化串, e.g. "%.1fx"
@property (nonatomic, assign) BOOL showValueInline;      // 滑块右侧实时显示当前值

// ── checkGroup ──
/// 每行排几个色块 (默认 3, 取值 1~5)
@property (nonatomic, assign) NSInteger columns;

// ── segmented / select / multi ──
@property (nonatomic, copy, nullable) NSArray<NSString *> *options;
// multi 行的候选项 (与 options 区分: segmented 用 options, multi 用 multiOptions,
// 避免 segmented 行被误用 multi 解释器)
@property (nonatomic, copy, nullable) NSArray<NSString *> *multiOptions;

// ── text / number ──
@property (nonatomic, copy, nullable) NSString *keyboardType; // "default"/"url"/"email"/"number"/"decimal"

// ── date ──
@property (nonatomic, assign) TSSettingsDateMode dateMode;

// ── duration ──
@property (nonatomic, copy, nullable) NSString *unit;     // 单位提示, e.g. "秒"/"分钟"

// ── action ──
/// 回调 Lua 注册表引用 (LUA_NOREF 表示无回调)。
/// view controller 触发时通过 TS_LuaCallRegistryRef(L, ref) 调用。
@property (nonatomic, assign) int luaCallbackRef;

// ── 依赖显示: visibleWhenKey 行的 currentValue == visibleWhenValue 时本行可见 ──
@property (nonatomic, copy, nullable) NSString *visibleWhenKey;
@property (nonatomic, strong, nullable) id visibleWhenValue;

// ── 校验 ──
@property (nonatomic, copy, nullable) NSString *validatorType; // "url"/"email"/"number"/"decimal"
@property (nonatomic, copy, nullable) NSString *validatorMessage;

// ── 运行时 (加载 settings.json 后填充) ──
@property (nonatomic, strong, nullable) id currentValue;

/// 是否处于隐藏状态 (依赖显示未满足)
@property (nonatomic, assign) BOOL hiddenByDependency;
@end

/// 一组设置 (UITableView 的 section)
@interface TSSettingsSection : NSObject
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *footer;
@property (nonatomic, copy) NSArray<TSSettingsRow *> *rows;
@end

/// 整个 schema
@interface TSSettingsSchema : NSObject
@property (nonatomic, copy) NSArray<TSSettingsSection *> *sections;
@property (nonatomic, copy) NSString *scriptName;
@property (nonatomic, copy, nullable) NSString *title;

/// 从 lua_State 栈顶的 table 构建 schema (table 不会被弹出, 调用方负责)。
/// luaState 必须指向 lua_State* (本文件不直接 #import "lua.h" 以避免污染 Views 层,
/// 调用方需保证类型一致)。
+ (nullable instancetype)schemaFromLuaState:(void *)luaState
                              topTableIndex:(int)idx
                                 scriptName:(NSString *)name
                                      error:(NSError **)error;

/// 从磁盘加载: /var/mobile/touch/lua/ui/<name>/schema.lua
/// 调用方负责传入有效的 lua_State (用于执行 schema.lua 文件)。
+ (nullable instancetype)loadSchemaForScriptName:(NSString *)name
                                       luaState:(void *)luaState
                                           error:(NSError **)error;

/// 查找 ui 目录中的 schema.lua (返回绝对路径, 不存在返回 nil)
+ (nullable NSString *)schemaFilePathForScriptName:(NSString *)name;

/// 把所有非依赖隐藏的 row 展开为扁平数组 (按 section 顺序, 跳过 info 行) ——
/// 供"应用到视图"和"收集 currentValue 回写"使用。
- (NSArray<TSSettingsRow *> *)allVisibleRows;
@end

NS_ASSUME_NONNULL_END
