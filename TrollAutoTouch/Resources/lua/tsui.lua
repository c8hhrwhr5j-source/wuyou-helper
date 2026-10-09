--[[=============================================================================
  tsui.lua —— TrollAutoTouch 声明式原生 UI 框架（底层实现）

  设计目标
  --------
  脚本侧只写「一个 build 函数 + 一段业务逻辑」，其余全部下沉到这里：
    · 表单生命周期：build -> ui.openForm(阻塞) -> 取回值 -> 落盘 -> (可选)下一轮
    · 默认值推断与合并：row 不写 default 也能拿到合法初值
    · 配置持久化：<脚本名>.settings.json；被 visibleWhen 隐藏的行也不会丢数据
    · 事件分发：spec.on[key]（值变化）、spec.actions[key]（动作按钮）
    · 按键分派：build 可直接写成 { ["战士"]=..., ["法师"]=... } 表
    · 按键直取环境：build 内可直接写 if role == "战士" then（等价 v.role）

  加载方式
  --------
  引擎在脚本执行前自动加载本文件（设备 /var/mobile/touch/lua/tsui.lua 优先，
  其次 App 内置 TrollAutoTouch.app/lua/tsui.lua），并把它挂到已有的全局 ui 表上，
  因此脚本里无需 require，直接用 ui.form{...} / ui.run() 即可。
  旧接口 ui.open / ui.openForm 原样保留，互不冲突。

  最小用法
  --------
    ui.form{
        title    = "师门任务",
        defaults = { role = "战士", speed = 1.0 },
        build    = function(v)
            if role == "战士" then                      -- 裸变量直取（也可写 v.role）
                return { rows = { {type="number", key="rage", label="怒气阈值"} } }
            end
            return { rows = { {type="switch", key="fast", label="极速模式"} } }
        end,
        actions  = { actSave = function(v) ui.save() end },
    }
    if ui.run() then
        -- 用户点了『运行』，ui.get("role") / ui.values() 即最新配置
    end
=============================================================================]]

local M = {}

-- 引擎注册的全局 ui 表（含 C 实现 ui.open / ui.openForm）
local ui = _G.ui
if type(ui) ~= "table" then
    ui = {}
    _G.ui = ui
end

local sformat = string.format
local spcall  = pcall
local sselect = select

local function logf(...)
    if type(logStr) ~= "function" then return end
    local n = sselect("#", ...)
    if n == 0 then return end
    local parts = {}
    for i = 1, n do parts[i] = tostring((sselect(i, ...))) end
    spcall(logStr, table.concat(parts, " "))
end

--==================================================================================
-- 0. 状态
--==================================================================================
local S = {
    spec     = nil,
    values   = {},     -- 当前配置: key -> value
    keys     = {},     -- 需要持久化的 key（有序）
    keySet   = {},
    hooks    = {},     -- key -> function(newVal, values)
    actions  = {},     -- key -> function(values)
    name     = nil,    -- 脚本名（决定 settings.json 文件名）
    path     = nil,
    round    = 0,
}

function S:addKey(k)
    if type(k) ~= "string" or #k == 0 or self.keySet[k] then return end
    self.keySet[k] = true
    self.keys[#self.keys + 1] = k
end

--==================================================================================
-- 1. 平台工具（对引擎 API 做防御式封装，老引擎缺接口也不会崩）
--==================================================================================
local function baseName(p)
    if type(p) ~= "string" or #p == 0 then return nil end
    local s = p:match("([^/\\]+)[/\\]*$")
    if not s or #s == 0 then return nil end
    s = s:gsub("%.[Ll][Uu][Aa]$", "")
    if #s == 0 then return nil end
    return s
end

local function guessName()
    local d = _G._SCRIPT_DIR_ or _G._PROJECT_DIR_
    if type(d) == "string" and #d > 0 then
        local n = baseName(d)
        if n then return n end
    end
    return baseName(_G._SCRIPT_PATH_) or "script"
end

local function luaDir()
    if type(file) == "table" and type(file.luaDir) == "function" then
        local ok, d = spcall(file.luaDir)
        if ok and type(d) == "string" and #d > 0 then return d end
    end
    return "/var/mobile/touch/lua"
end

local function readText(path)
    if type(path) ~= "string" or #path == 0 then return nil end
    if type(file) == "table" and type(file.read) == "function" then
        local ok, data = spcall(file.read, path)
        if ok and type(data) == "string" and #data > 0 then return data end
    end
    local f = io and io.open and io.open(path, "rb")
    if f then
        local data = f:read("*a")
        f:close()
        if type(data) == "string" and #data > 0 then return data end
    end
    return nil
end

local function writeText(path, text)
    if type(path) ~= "string" or #path == 0 or type(text) ~= "string" then return false end
    if type(file) == "table" and type(file.write) == "function" then
        local ok, ret = spcall(file.write, path, text)
        if ok and ret ~= false then return true end
    end
    local f = io and io.open and io.open(path, "wb")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

local function decodeJSON(text)
    if type(text) ~= "string" then return nil end
    if type(json) == "table" and type(json.decode) == "function" then
        local ok, t = spcall(json.decode, text)
        if ok and type(t) == "table" then return t end
    end
    return nil
end

local function encodeJSON(t)
    if type(json) ~= "table" or type(json.encode) ~= "function" then return nil end
    local ok, s = spcall(json.encode, t)
    if ok and type(s) == "string" then return s end
    return nil
end

--==================================================================================
-- 2. 值管理
--==================================================================================
local function absorbTable(t, override)
    if type(t) ~= "table" then return end
    for k, v in pairs(t) do
        if type(k) == "string" and v ~= nil then
            if override or S.values[k] == nil then S.values[k] = v end
            S:addKey(k)
        end
    end
end

-- 按 type 推断一个合法初值（用户不写 default 也不会出现脏控件状态）
local function inferDefault(row)
    local t = row.type
    local opts = row.options
    if t == "switch" or t == "checkbox" then return false end
    if t == "checkGroup" or t == "multi" then return {} end
    if t == "stepper" or t == "slider" or t == "number" then
        return tonumber(row.min) or 0
    end
    if t == "duration" then return tonumber(row.min) or 60 end
    if t == "date" then return os.time() end
    if t == "color" then return "#000000" end
    if (t == "segmented" or t == "select") and type(opts) == "table" then
        return opts[1]
    end
    if t == "text" or t == "textLong" then return "" end
    return nil
end

--==================================================================================
-- 3. schema 处理
--==================================================================================
-- 兼容三种写法:
--   1) { title=?, sections={ {title=?,rows={...}}, ... } }
--   2) { {title=?,rows={...}}, ... }        -- 省略 sections, 直接给 section 数组
--   3) { title=?, rows={...} }              -- 只有一个 section
local function eachRow(schema, fn)
    if type(schema) ~= "table" then return end
    local list
    if type(schema.rows) == "table" then
        list = { schema }
    elseif type(schema.sections) == "table" then
        list = schema.sections
    elseif #schema > 0 then
        list = schema
    end
    if type(list) ~= "table" then return end
    for _, sec in ipairs(list) do
        if type(sec) == "table" then
            local rows = sec.rows
            if type(rows) ~= "table" then rows = sec end
            for i, row in ipairs(rows) do
                if type(row) == "table" and row.type then fn(row, sec, i) end
            end
        end
    end
end

-- 下沉点①: 自动补 default、自动接管 action 行的 onTap
local function prepareSchema(schema)
    eachRow(schema, function(row)
        local t = row.type
        if t == "info" then return end
        local k = row.key
        if type(k) ~= "string" or #k == 0 then return end
        S:addKey(k)

        if t == "action" then
            local userFn = row.onTap
            row.onTap = function(cur)
                if type(cur) == "table" then
                    for kk, vv in pairs(cur) do
                        if type(kk) == "string" then S.values[kk] = vv end
                    end
                end
                local fn = S.actions[k]
                if type(fn) ~= "function" and type(userFn) == "function" then fn = userFn end
                if type(fn) == "function" then
                    local ok, err = spcall(fn, S.values)
                    if not ok then logf("[ui] action[" .. k .. "] 回调出错:", err) end
                end
            end
            return
        end

        if row.default == nil then
            local v = S.values[k]
            if v == nil then
                v = inferDefault(row)
                S.values[k] = v
            end
            row.default = v
        end
    end)
end

--==================================================================================
-- 4. 按键直取环境（让 build 内直接写 if role == "战士" then）
--==================================================================================
local function makeEnv()
    local env = {}
    return setmetatable(env, {
        __index = function(_, k)
            local v = S.values[k]
            if v ~= nil then return v end
            local spec = S.spec
            if spec and type(spec.env) == "table" then
                local e = spec.env[k]
                if e ~= nil then return e end
            end
            return _G[k]          -- math / string / ui / toast ... 仍可正常使用
        end,
    })
end

-- 把函数的 _ENV 上值换成我们的环境表（找不到 _ENV 就静默跳过）
local function bindEnv(fn, env)
    if type(fn) ~= "function" then return false end
    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then return false end
    local i = 1
    while true do
        local name = debug.getupvalue(fn, i)
        if not name then return false end
        if name == "_ENV" then
            debug.setupvalue(fn, i, env)
            return true
        end
        i = i + 1
    end
end

local function callBuild(fn, env)
    if type(fn) ~= "function" then return fn end
    bindEnv(fn, env)
    return fn(env)
end

-- 下沉点②: 支持 build = function(v) ... 或 build = { ["战士"]=..., ["法师"]=... }
local function buildSchema()
    local spec = S.spec
    local src = spec.build
    if src == nil then src = spec.schema end
    if src == nil then return nil end

    local env = makeEnv()
    if type(src) == "function" then return callBuild(src, env) end

    if type(src) == "table" then
        local byKey = spec.by
        if byKey == nil then
            if S.values.role ~= nil then byKey = "role"
            elseif S.values.mode ~= nil then byKey = "mode"
            else byKey = S.keys[1] end
        end
        local cur = byKey and S.values[byKey] or nil
        local item = (cur ~= nil) and src[cur] or nil
        if item == nil then item = src["*"] or src.default or src.other end
        if item == nil then return nil end
        return callBuild(item, env)
    end
    return nil
end

local function fireHooks()
    for k, fn in pairs(S.hooks) do
        local ok, err = spcall(fn, S.values[k], S.values)
        if not ok then logf("[ui] on[" .. tostring(k) .. "] 回调出错:", err) end
    end
end

--==================================================================================
-- 5. 公开接口（全部挂在全局 ui 表上）
--==================================================================================

--- 注册表单（不阻塞）; 可链式: ui.form{...}:run()
function M.form(spec)
    assert(type(spec) == "table", "ui.form(spec): 参数必须是表")

    S.spec   = spec
    S.values = {}
    S.keys   = {}
    S.keySet = {}
    S.hooks  = {}
    S.actions = {}
    S.round  = 0
    S.name   = spec.name or guessName()
    S.path   = spec.path or (luaDir() .. "/" .. S.name .. ".settings.json")

    -- 显式声明的 key 先登记, 保证 ui.keys() 的顺序稳定
    if type(spec.keys) == "table" then
        for _, k in ipairs(spec.keys) do S:addKey(k) end
    end

    absorbTable(spec.defaults, false)   -- 1) 声明的默认值
    absorbTable(_G.settings, true)      -- 2) 引擎注入的全局 settings（上次保存值）
    absorbTable(decodeJSON(readText(S.path)), true)  -- 3) 磁盘文件兜底

    if type(spec.on) == "table" then
        for k, fn in pairs(spec.on) do
            if type(k) == "string" and type(fn) == "function" then S.hooks[k] = fn end
        end
    end
    if type(spec.actions) == "table" then
        for k, fn in pairs(spec.actions) do
            if type(k) == "string" and type(fn) == "function" then S.actions[k] = fn end
        end
    end
    return M
end
M.define = M.form

--- 显示表单并等待操作（阻塞）
---   返回 true : 用户点『运行』（值已写盘, ui.get/ui.values() 可用）
---   返回 false: 用户点『取消』(引擎会停止脚本) / 引擎不支持 / build 出错
function M.run()
    local spec = S.spec
    if type(spec) ~= "table" then
        logf("[ui] ui.run(): 请先调用 ui.form{...}")
        return false
    end
    if type(ui.openForm) ~= "function" then
        logf("[ui] 当前引擎不支持 ui.openForm, 请升级 TrollAutoTouch")
        return false
    end

    while true do
        S.round = S.round + 1

        local schema = buildSchema()
        if type(schema) ~= "table" then
            logf("[ui] build 未返回有效的 schema 表, 已终止")
            return false
        end
        prepareSchema(schema)

        if spec.persist ~= false then M.save() end

        local ok, ran = spcall(ui.openForm, S.name, schema, {
            headerTitle    = spec.header or spec.title,
            orientation    = spec.orientation,
            autoCloseAfter = spec.autoCloseAfter,
        })
        if not ok then
            logf("[ui] 表单异常:", ran)
            return false
        end
        if ran ~= true then
            return false        -- 取消: 引擎已 stop 脚本
        end

        -- 下沉点③: 引擎只写了「表单里出现且可见」的 key, 这里合并后再完整落盘,
        --          被 visibleWhen 隐藏的行、以及本轮未渲染的 key 都不会丢
        M._absorb()
        if spec.persist ~= false then M.save() end
        fireHooks()

        if type(spec.onRun) == "function" then
            local okRun, cont = spcall(spec.onRun, S.values, S.round)
            if not okRun then logf("[ui] onRun 出错:", cont) end
            if cont ~= true then return true end
            -- 返回 true -> 用最新值重新 build + 重开表单（更新数据闭环）
        else
            return true
        end
    end
end
M.show = M.run

--- 取全局 settings 表的值覆盖到内部状态（引擎在表单确认后刷新它）
function M._absorb()
    local s = _G.settings
    if type(s) ~= "table" then return end
    for k, v in pairs(s) do
        if type(k) == "string" and v ~= nil then S.values[k] = v end
    end
end

--- 取一个 key 的值
function M.get(k, d)
    local v = S.values[k]
    if v == nil then return d end
    return v
end
M.value = M.get

--- 设置一个 key（saveNow=true 时立即写盘）
function M.set(k, v, saveNow)
    if type(k) ~= "string" or #k == 0 then return false end
    S.values[k] = v
    S:addKey(k)
    if saveNow then return M.save() end
    return true
end

--- 当前全部值的引用（只读场景建议用 ui.snapshot()）
function M.values() return S.values end

--- 当前全部值的浅拷贝
function M.snapshot()
    local t = {}
    for k, v in pairs(S.values) do t[k] = v end
    return t
end

--- 立即写盘（<脚本名>.settings.json）
function M.save()
    local spec = S.spec
    if spec and spec.persist == false then return false end
    local out = {}
    for _, k in ipairs(S.keys) do
        local v = S.values[k]
        if v ~= nil then out[k] = v end
    end
    local text = encodeJSON(out)
    if not text then return false end
    return writeText(S.path, text)
end

--- 从磁盘重新读取配置
function M.reload()
    local t = decodeJSON(readText(S.path))
    if not t then return false end
    absorbTable(t, true)
    return true
end

--- 恢复默认值（only 为 key 时只恢复该键）
function M.reset(only)
    local defs = (S.spec and S.spec.defaults) or {}
    if type(only) == "string" then
        S.values[only] = defs[only]
        return true
    end
    for k, v in pairs(defs) do S.values[k] = v end
    return true
end

--- 注册值回调（本轮结束、值已刷新后触发）
function M.on(k, fn)
    if type(k) == "string" and type(fn) == "function" then
        S.hooks[k] = fn
        return true
    end
    return false
end

--- 注册动作按钮回调（schema 里只需写 type="action", key="xxx"）
function M.action(k, fn)
    if type(k) == "string" and type(fn) == "function" then
        S.actions[k] = fn
        return true
    end
    return false
end

--- 按某个 key 的当前值做分派（声明式逻辑分支）
---   ui.branch("role", { ["战士"]=function(v) ... end, ["*"]=function(v) ... end })
function M.branch(key, map, ...)
    if type(map) ~= "table" then return nil end
    local v = S.values[key]
    local fn = map[v] or map["*"] or map.default
    if type(fn) == "function" then return fn(...) end
    return fn
end

function M.keys() return S.keys end
function M.name() return S.name end
function M.settingsPath() return S.path end
function M.round() return S.round end
function M.spec() return S.spec end

M.version = "1.0"

--==================================================================================
-- 6. 挂到全局 ui 表（引擎用 loadbuffer 直接执行本文件, 不经过 require）
--==================================================================================
for k, v in pairs(M) do
    if ui[k] == nil then ui[k] = v end   -- 不覆盖 C 实现(open/openForm 等)
end
_G.ui = ui
_G.tsui = ui

return M
