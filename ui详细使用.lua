--[==[=================================================================================
  ui详细使用.lua —— TrollAutoTouch「声明式原生 UI」示例 (重构版)

  重构前: 每个脚本都要自己写 DEFAULTS / readSettings / writeSettings / mergeDefaults
          / copyTable / describe / onTap 回调 / default=cfg.xxx 逐行透传 …… 500+ 行样板。
  重构后: 全部样板下沉到引擎侧框架 tsui.lua, 本脚本只剩两件事:
            ① 一个 buildSchema(值) 函数 —— 声明式描述表单长什么样;
            ② 一段业务逻辑(onRun) + 几个按键回调(on / actions)。

  ------------------------------------------------------------------------------
  引擎自动加载的框架接口 (全局 ui 表, 无需 require)
  ------------------------------------------------------------------------------
  ui.form{ ... }                注册表单(不阻塞), 字段见下
  ui.run() / ui.show()          显示表单并阻塞; true=用户点『运行』, false=『取消』
  ui.get(key [, 默认值])        取一个配置值         ui.value = ui.get
  ui.set(key, 值 [, 立即存盘])   改一个配置值
  ui.values() / ui.snapshot()   全部值(引用 / 浅拷贝)
  ui.save() / ui.reload()       立即写盘 / 从磁盘重读
  ui.reset([key])               恢复默认值
  ui.on(key, fn)                注册值回调  fn(新值, 全部值)
  ui.action(key, fn)            注册动作按钮回调  fn(全部值)
  ui.branch(key, 分派表, ...)    按键值分派: ui.branch("role", {["战士"]=fn, ["*"]=fn})
  ui.keys() / ui.name() / ui.settingsPath() / ui.round() / ui.spec()

  ------------------------------------------------------------------------------
  ui.form{...} 的字段 (spec)
  ------------------------------------------------------------------------------
  name          脚本名, 决定 settings.json 文件名 (默认由 _SCRIPT_PATH_ 推导)
  title/header  表单标题 / 顶部大标题
  orientation   "auto" | "portrait" | "landscape"
  autoCloseAfter 秒数, >0 时倒计时归零自动『保存并运行』
  persist       false = 不自动读写 settings.json (默认 true)
  path          自定义配置文件名 (默认 <luaDir>/<name>.settings.json)
  keys          显式声明要持久化的 key 及顺序 (可选, 也会自动收集)
  defaults      默认值表 (可选; 没写的行还会按 type 自动推断初值)
  build         function(v) -> schema  (也可写成按键分派的表, 见文件末尾注释)
  on            按 key 的值回调:    { role = function(val, all) ... end }
  actions       按 key 的动作回调:  { actSave = function(all) ... end }
  onRun         function(all, round) -> true 继续下一轮 / 其它结束
  env           额外注入 build 环境的变量 (可选)

  ------------------------------------------------------------------------------
  build 函数的参数 v:  按键直取环境
  ------------------------------------------------------------------------------
    · v.role            常规写法
    · role              裸变量写法, 完全等价 (引擎把配置注入函数环境)
    两者都能用, 且 math / string / ui / toast 等全局照常可访问。
====================================================================================]==]

local ui = _G.ui
if type(ui) ~= "table" or type(ui.form) ~= "function" then
    logStr("[ui详细使用] 需要声明式 UI 框架: 请升级 TrollAutoTouch, "
        .. "或把 tsui.lua 放到 /var/mobile/touch/lua/ 后重跑")
    return
end

local SCREEN_W, SCREEN_H = getScreenSize()
local SCRIPT_NAME = "ui详细使用"
local LOGWIN = nil          -- 浮动日志窗口句柄

local function log(msg)
    local text = tostring(msg)
    logStr(text)
    if LOGWIN then LOGWIN:addLog(text) end
end

local function joinList(v)
    if type(v) == "table" then
        if #v == 0 then return "(空)" end
        return table.concat(v, "、")
    end
    return tostring(v)
end

--==================================================================================
-- 1. 只有这里需要你写: 声明式描述表单结构 (按 role 分支)
--==================================================================================
local function buildSchema(v)
    local roleRows
    if role == "战士" then                       -- 裸变量=按键直取, 等价 if v.role == "战士"
        roleRows = {
            {type = "number", key = "rage",     label = "怒气阈值",  min = 0, max = 200, step = 10},
            {type = "switch", key = "taunt",    label = "自动嘲讽"},
        }
    elseif role == "法师" then
        roleRows = {
            {type = "slider", key = "manaKeep", label = "保留法力",  min = 0, max = 100, step = 5, format = "%d%%"},
            {type = "switch", key = "aoeFirst", label = "优先群攻"},
        }
    elseif role == "道士" then
        roleRows = {
            {type = "segmented", key = "pet",   label = "召唤兽",   options = {"灵符", "傀儡", "神兽"}},
            {type = "checkbox",  key = "healAlly", label = "给队友加血"},
        }
    else
        roleRows = {{type = "info", text = "未识别角色: " .. tostring(role)}}
    end

    return {
        title = "UI 全功能示例 (声明式)",
        sections = {
            {
                title  = "① 开关 (switch / checkbox)",
                footer = "值类型 bool; default 不用写, 框架自动用上次保存值",
                rows = {
                    {type = "switch",   key = "autoStart",  label = "启动后自动开始"},
                    {type = "checkbox", key = "autoPickup", label = "自动拾取 (点整行文字也能切换)"},
                },
            },
            {
                title  = "② 数值与时间 (slider / stepper / number / duration / date)",
                footer = "date 行 mode=\"time\" 点开后就是时间滚轮",
                rows = {
                    {type = "slider",   key = "speed",    label = "运行速度", min = 0.5, max = 2, step = 0.1, format = "%.1fx"},
                    {type = "stepper",  key = "retry",    label = "失败重试", min = 0, max = 10, step = 1},
                    {type = "number",   key = "coordX",   label = "目标 X 坐标", min = 0, max = 4096, step = 1, keyboard = "number"},
                    {type = "duration", key = "cooldown", label = "冷却时间", unit = "秒"},
                    {type = "date",     key = "alarmAt",  label = "定时启动", mode = "time"},
                },
            },
            {
                title  = "③ 选择与颜色 (segmented / select / multi / checkGroup / color)",
                footer = "select 的角色改了, 第⑦组会在下一次打开表单时切换",
                rows = {
                    {type = "segmented",  key = "mode",        label = "运行模式", options = {"快速", "安全", "自定义"}},
                    {type = "select",     key = "role",        label = "角色",     options = {"战士", "法师", "道士"}},
                    {type = "multi",      key = "targets",     label = "目标列表", options = {"史莱姆", "哥布林", "狼"}},
                    {type = "checkGroup", key = "taskSel",     label = "要执行的任务", columns = 3,
                     options = {"师门任务", "帮派任务", "捉鬼任务", "宝图任务", "运镖任务", "三任务"}},
                    {type = "color",      key = "targetColor", label = "目标颜色"},
                },
            },
            {
                title = "④ 文本 (text / textLong)",
                rows = {
                    {type = "text",     key = "webhook", label = "通知地址", placeholder = "https://example.com/hook",
                     keyboard = "url", validator = "url",
                     validatorMessage = "URL 必须以 http:// 或 https:// 开头"},
                    {type = "textLong", key = "notes",   label = "备注 (多行)"},
                },
            },
            {
                title  = "⑤ 依赖显示 (visibleWhen)",
                footer = "引擎按等值条件实时显隐; 隐藏行的值也不会丢(框架合并后完整落盘)",
                rows = {
                    {type = "switch", key = "advanced", label = "高级模式"},
                    {type = "checkGroup", key = "advancedOpts", label = "高级选项", columns = 3,
                     options = {"日志详细", "失败截图", "自动重启"},
                     visibleWhen = "advanced", visibleWhenValue = true},
                    {type = "text", key = "customUrl", label = "自定义地址 (模式=自定义时出现)",
                     placeholder = "https://", keyboard = "url",
                     visibleWhen = "mode", visibleWhenValue = "自定义"},
                },
            },
            {
                title  = "⑥ 事件绑定 (action)",
                footer = "函数写在 ui.form{ actions = {...} } 里, schema 中只留 key",
                rows = {
                    {type = "info",   text = "下面 4 个按钮演示『事件绑定 + 动态交互』, 不会改动表单本身"},
                    {type = "action", key = "actDump",  label = "① 打印当前全部配置"},
                    {type = "action", key = "actSave",  label = "② 立即保存到 settings.json"},
                    {type = "action", key = "actLog",   label = "③ 显示 / 隐藏浮动日志窗口"},
                    {type = "action", key = "actReset", label = "④ 恢复默认值"},
                },
            },
            {
                title  = "⑦ 角色专属分组 (" .. tostring(role) .. ")",
                footer = "本组由 buildSchema 里的 if role == \"战士\" then ... end 决定",
                rows   = roleRows,
            },
        },
    }
end

--==================================================================================
-- 2. 按键回调: 值变化(on) 与 动作按钮(actions) —— 都只按 key 写
--==================================================================================
local hooks = {
    mode = function(val)
        log("[事件] 运行模式 -> " .. tostring(val) .. " (自定义地址行会实时显示/隐藏)")
    end,
    role = function(val)
        log("[事件] 角色 -> " .. tostring(val) .. " (第⑦组将在下一轮表单切换)")
    end,
    advanced = function(val)
        log("[事件] 高级模式 -> " .. tostring(val))
    end,
}

local createLogWindow   -- 前置声明: actions 里的闭包在运行时引用它

local actions = {
    actDump = function(v)
        local keys = {}
        for _, k in ipairs(ui.keys()) do keys[#keys + 1] = k end
        table.sort(keys)
        log("[动作①] 当前配置 " .. #keys .. " 个 key:")
        for _, k in ipairs(keys) do
            local val = v[k]
            if val ~= nil then                  -- 其它角色专属的 key 会把值为 nil 的跳过
                if type(val) == "table" then val = joinList(val) end
                log(string.format("    %-14s = %s", k, tostring(val)))
            end
        end
        sys.toast("已打印到日志", 1500)
    end,
    actSave = function(v)
        local ok = ui.save()
        log("[动作②] 立即保存 -> " .. tostring(ui.settingsPath()) .. " : " .. tostring(ok))
        sys.toast(ok and "已保存" or "保存失败", 1600)
    end,
    actLog = function(v)
        if LOGWIN then
            LOGWIN:release()
            LOGWIN = nil
            sys.toast("浮动日志窗口已隐藏", 1500)
        else
            LOGWIN = createLogWindow()
            sys.toast("浮动日志窗口已显示", 1500)
        end
    end,
    actReset = function(v)
        ui.reset()          -- 恢复 ui.form 里声明的 defaults
        ui.save()
        log("[动作④] 已恢复默认值, 点『运行』或重开表单生效")
        sys.toast("已恢复默认值", 1600)
    end,
}

--==================================================================================
-- 3. 业务逻辑: 表单返回后执行; 返回 true 表示「用新数据重开表单」(更新数据闭环)
--==================================================================================
local function onRun(v, round)
    log(string.format("── 第 %d 轮业务逻辑: 角色=%s 模式=%s 速度=%sx 重试=%s ──",
                      round, tostring(v.role), tostring(v.mode), tostring(v.speed), tostring(v.retry)))
    log("   任务 = " .. joinList(v.taskSel) .. "    目标 = " .. joinList(v.targets))
    log("   颜色 = " .. tostring(v.targetColor) .. "    冷却 = " .. tostring(v.cooldown) .. " 秒")
    if v.advanced then log("   高级选项 = " .. joinList(v.advancedOpts)) end

    -- 演示按键分派: 不同角色走不同分支 (等价 buildSchema 里的 if role == ... then)
    ui.branch("role", {
        ["战士"] = function() log("   [分派] 战士策略: 近身拉怪 + 怒气技能") end,
        ["法师"] = function() log("   [分派] 法师策略: 保持距离 + 群攻") end,
        ["道士"] = function() log("   [分派] 道士策略: 召唤兽先手 + 辅助") end,
        ["*"]    = function() log("   [分派] 通用策略") end,
    })

    mSleep(400)   -- 模拟真正做事(tap / swipe / 找色 …)

    local choice = sys.alertButtons(
        string.format("第 %d 轮配置已生效, 接下来?", round),
        {"继续编辑(用新值重开表单)", "结束演示"}, SCRIPT_NAME, 0)
    return choice == "继续编辑(用新值重开表单)"
end

--==================================================================================
-- 4. 浮动日志窗口 (UIKit UIWindow + UILabel: 显示 / 隐藏 的演示)
--==================================================================================
function createLogWindow()
    local h = math.floor(SCREEN_H * 0.26)
    local obj = logWindow.init(20, SCREEN_H - h - 30, SCREEN_W - 40, h,
                               0.55,           -- 背景透明度
                               0x101820,       -- 背景色
                               0x00FF66,       -- 默认字色
                               12,             -- 字号
                               false)          -- false=多行追加
    if obj then obj:addLog("浮动日志窗口已就绪 (logWindow.init)", 0xFFFF00, 13) end
    return obj
end

--==================================================================================
-- 5. 主流程: 注册 -> 运行 -> 收尾  (全部封装都在框架里)
--==================================================================================
logWindow.setHideWindowMode(false)      -- true = 面板不进截屏(找色脚本要开)
LOGWIN = createLogWindow()

log("=== " .. SCRIPT_NAME .. " 启动 " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===")
log("App 版本 " .. tostring(sys.version()) .. "   屏幕(脚本坐标) " ..
    math.floor(SCREEN_W) .. "x" .. math.floor(SCREEN_H))

ui.form{
    name    = SCRIPT_NAME,
    title   = "UI 全功能示例 (声明式)",
    header  = "只需写 buildSchema —— 封装全在引擎里",
    keys    = {  -- 显式声明持久化 key 与顺序(可选)
        "role", "mode", "speed", "retry", "cooldown", "alarmAt",
        "autoStart", "autoPickup", "coordX", "targets", "taskSel", "targetColor",
        "webhook", "notes", "advanced", "advancedOpts", "customUrl",
        "rage", "taunt", "manaKeep", "aoeFirst", "pet", "healAlly",
    },
    defaults = {
        role = "战士", mode = "快速", speed = 1.0, retry = 3, cooldown = 300,
        autoStart = true, autoPickup = true, coordX = 100, targets = {"史莱姆"},
        taskSel = {"师门任务", "宝图任务"}, targetColor = "#FF0000",
        webhook = "", notes = "", advanced = false, advancedOpts = {"日志详细"},
    },
    build   = buildSchema,
    on      = hooks,
    actions = actions,
    onRun   = onRun,
}

log("配置文件: " .. tostring(ui.settingsPath()))
log("已注册 key: " .. joinList(ui.keys()))

if ui.run() then
    log("用户点击『运行』: 配置已生效并落盘 (" .. tostring(ui.round()) .. " 轮)")
else
    -- 用户点『取消』时引擎已停止脚本, 此处不要再调用引擎接口
    return
end

LOGWIN:release()
LOGWIN = nil
logWindow.releaseAll()
logStr("演示结束, 配置已保存到: " .. tostring(ui.settingsPath()))

--[==[=================================================================================
  附: 同一份表单还可以写成「按键分派表」形式, 让分支判断也从脚本里消失:

    ui.form{
        by   = "role",                 -- 用哪个 key 的值做分派
        build = {
            ["战士"] = function(v) return { rows = {{type="switch", key="taunt", label="自动嘲讽"}} } end,
            ["法师"] = function(v) return { rows = {{type="switch", key="aoeFirst", label="优先群攻"}} } end,
            ["*"]    = { rows = {{type="info", text="通用配置"}} },   -- 兜底(也可写 default)
        },
        defaults = { role = "战士" },
    }

  或完全函数式:

    local SCHEMA = {
        ["战士"] = {{type="switch", key="taunt", label="自动嘲讽"}},
        ["法师"] = {{type="switch", key="aoeFirst", label="优先群攻"}},
    }
    local function buildSchema(v)
        return { rows = SCHEMA[v.role] or SCHEMA["战士"] }     -- 直接按键取值
    end
====================================================================================]==]
