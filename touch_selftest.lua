-- ============================================================
-- touch_selftest.lua v2 —— 触摸注入自检(系统手势判据 + 候选 senderID 逐个试)
--
-- 【为什么换判据】v1 用"普通点击"做判据, 但点了没反应既可能是注入失败, 也可能是点到
-- 空白处 / 坐标不对 —— 无法定论(上一轮日志就是这样: 点在 QQ音乐 中间, 什么都没发生)。
-- v2 改用一个任何界面都能触发、肉眼绝不会看错的动作做判据:
--       从屏幕顶部往下拉  =  打开【通知中心】
--   通知中心弹出 = 注入链路完全通; 没弹出 = 这个 senderID 不被系统受理。
-- 该手势由系统(SpringBoard)识别, 不依赖前台 app 有没有可点元素, 所以即使
-- TrollAutoTouch 自己在前台也照样能测, 不需要切到别的 app。
--
-- 【怎么跑】在 TrollAutoTouch 里运行本脚本, 然后盯着屏幕(不要切 app), 全程约 1 分钟:
--   ① 先让你用【手指】在屏幕上点几下 —— 引擎据此学出本机真实 senderID(最可信, 不靠猜);
--   ② 然后逐个候选 senderID, 每个做一次"顶部下拉", 每次间隔 12 秒。
--   看到通知中心弹出 → 记住 debug.log 里对应的"候选 N", 那 N 就是本机可用的值。
--   (每次弹出后请手动上滑把它关掉, 再看下一位)
--
-- 【注意】senderID 在 Lua 里一律是【十六进制字符串】(如 "0x931C5CF1E3A24768")。
-- 不要用 tonumber 转成数字: 64 位值超出 double 精度(53 位), 会丢低位变成另一个值,
-- 系统静默丢弃且看不出异常 —— 这正是"排查半天毫无头绪"的经典陷阱。
--
-- 【结果判读】
--   有任意一次弹出  → 注入可用! 用日志末尾给出的 touch.useSenderIDAt(N) 锁定该值即可;
--   一次都不弹      → 不是 senderID 问题, 是更深层(事件结构/权限/系统策略),
--                     请把 debug.log + touch.log 一起发回。
-- ============================================================

local GESTURE = "top_down"   -- 判据手势: top_down=顶部下拉(通知中心, 通用, 默认)
                             --           top_right_down=右上角下拉(全面屏机型的控制中心)
                             --           bottom_up=底部上滑(有 Home 键机型的控制中心)
local ORI = 0                -- 脚本坐标系: 0=竖屏(默认)。手机请保持竖着。
local LEARN_MS = 8000        -- ① 学真实 senderID 的采样时长(毫秒)
local PRE_MS = 3000          -- 每个候选: 提示后多久做手势(毫秒)
local GAP_MS = 12000         -- 每个候选之间的间隔(毫秒, 留时间观察/关掉通知中心)
local LOCK_INDEX = 0         -- 跑完一次后, 把"看到反应的那次序号"(1 起)填这里, 再跑一次即锁定

-- ---------------- 基础封装 ----------------
local function p(...)
    local t = {}
    local n = select("#", ...)
    for i = 1, n do t[#t + 1] = tostring((select(i, ...))) end
    local msg = "[点击自检] " .. table.concat(t, " ")
    if print then print(msg) end
end

local function status()
    if type(touch) == "table" and touch.status then
        local ok, v = pcall(touch.status)
        if ok then return tostring(v) end
    end
    return "(touch.status 不可用)"
end

local function setSenderID(idStr)
    if type(touch) == "table" and touch.setSenderID then
        local ok, got = pcall(touch.setSenderID, idStr)
        if ok then return tostring(got) end
        p("    setSenderID 失败: " .. tostring(got))
    end
    return nil
end

local function screenWH()
    if screen and screen.getSize then
        local ok, w, h = pcall(screen.getSize)
        if ok and tonumber(w) and tonumber(h) then return tonumber(w), tonumber(h) end
    end
    return 750, 1334
end

-- 手势起/终点(脚本坐标系): 起点必须贴屏幕边缘, 系统才会识别成边缘手势。
local function gesturePoints()
    local w, h = screenWH()
    if GESTURE == "top_right_down" then
        return w - 50, 4, w - 50, math.floor(h * 0.55)
    elseif GESTURE == "bottom_up" then
        return math.floor(w / 2), h - 4, math.floor(w / 2), math.floor(h * 0.55)
    end
    return math.floor(w / 2), 4, math.floor(w / 2), math.floor(h * 0.55)
end

local function doGesture()
    local x1, y1, x2, y2 = gesturePoints()
    p(string.format("    执行【%s】(%d,%d) -> (%d,%d) 300ms", GESTURE, x1, y1, x2, y2))
    local ok, err = pcall(swipe, x1, y1, x2, y2, 300)
    if not ok then p("    手势调用异常: " .. tostring(err)) end
end

-- ---------------- 准备 ----------------
p("========== 触摸注入自检 v2 开始 ==========")
if screen and screen.init then screen.init(ORI) end
p("初始状态: " .. status())

if LOCK_INDEX > 0 and type(touch) == "table" and touch.useSenderIDAt then
    local ok, v = pcall(touch.useSenderIDAt, LOCK_INDEX)
    if ok then p("已按 LOCK_INDEX=" .. LOCK_INDEX .. " 锁定 senderID = " .. tostring(v)) end
    p("末态: " .. status())
    p("========== 锁定模式结束 ==========")
    return
end

-- 仅直发: 排除"本应用点击(AX)"兜底干扰 —— AX 只会点击起点, 会污染判定结果。
if type(touch) == "table" and touch.channel then
    pcall(touch.channel, 1)
    p("已切到【仅直发】通道(排除 AX 兜底干扰)")
end

-- ---------------- ① 学习本机真实 senderID(肉手) ----------------
local candidates = {}

-- ⓪ 原版 TrollAutoScript HUDServices 写死的固定值(2026-09-11 逆向确认),
--    现在也是 App 的默认直发值 —— 永远排第一个测, 因为它是"不依赖任何真实触摸"的那一个。
candidates[#candidates + 1] = { id = "0x8000000817319371", label = "原版固定值(逆向确认)" }

if type(touch) == "table" and touch.watch then
    p(string.format("请现在用【手指】在屏幕上点/滑几下(%.0f 秒内; 期间不要跑脚本点击)……",
                    LEARN_MS / 1000))
    local ok, ids = pcall(touch.watch, LEARN_MS)
    if ok and type(ids) == "table" then
        for i = 1, #ids do
            local v = tostring(ids[i] or "")
            if v ~= "" and v ~= "0x0" then
                candidates[#candidates + 1] = { id = v, label = "肉手真实值" }
                p("学习到真实 senderID: " .. v)
            end
        end
        if #candidates == 0 then
            p("未捕获到真实触摸(手指没点? 或系统没把触摸事件下发到本进程)")
        end
    else
        p("touch.watch 调用失败: " .. tostring(ids))
    end
else
    p("touch.watch 不可用(IPA 过旧?), 跳过学习")
end

-- ---------------- ② 服务枚举候选 ----------------
if type(touch) == "table" and touch.senderIDs then
    local ok, list = pcall(touch.senderIDs)
    if ok and type(list) == "table" then
        for i = 1, #list do
            local it = list[i]
            local v = tostring(it.id or "")
            if v ~= "" and v ~= "0x0" then
                local dup = false
                for _, c in ipairs(candidates) do
                    if c.id == v then dup = true; break end
                end
                if not dup then
                    candidates[#candidates + 1] = {
                        id = v,
                        label = string.format("服务枚举 %s/%s usage=0x%X",
                                              tostring(it.product or ""),
                                              tostring(it.transport or ""),
                                              tonumber(it.usage) or 0),
                    }
                end
            end
        end
        p("服务枚举得到候选 " .. #list .. " 个")
    else
        p("touch.senderIDs 调用失败: " .. tostring(list))
    end
else
    p("touch.senderIDs 不可用(IPA 过旧?), 跳过服务枚举")
end

if #candidates == 0 then
    p("没有任何候选 senderID, 无法继续。请确认 IPA 是本次新版。")
    p("========== 自检结束(无候选) ==========")
    return
end

-- 记录测试前的值(字符串), 结束后恢复, 避免把无效候选持久化到配置里
local original = status():match("senderID=(0x%x+)") or nil
if original then p("测试前 senderID = " .. original) end

-- ---------------- ③ 逐个候选做手势 ----------------
p(string.format("开始逐个试: 共 %d 个候选, 每个间隔 %.0f 秒。请盯着屏幕看通知中心是否弹出!",
                #candidates, GAP_MS / 1000))

for i, c in ipairs(candidates) do
    p(string.format("---------- 候选 %d/%d: %s -> senderID=%s", i, #candidates, c.label, c.id))
    setSenderID(c.id)
    p("    当前状态: " .. status())
    mSleep(PRE_MS)
    doGesture()
    p(string.format("    手势已下发 —— 通知中心弹出了吗? 弹出 = 候选 %d 有效!", i))
    if GAP_MS > PRE_MS then mSleep(GAP_MS - PRE_MS) end
end

-- ---------------- ④ 收尾 ----------------
if original and original ~= "0x0" then
    setSenderID(original)
    p("已把 senderID 恢复为测试前的值 " .. original .. "(避免把无效候选留在配置里)")
end
if type(touch) == "table" and touch.channel then pcall(touch.channel, 0) end

p("========== 自检结束 ==========")
for i, c in ipairs(candidates) do
    p(string.format("候选 %d: %s (%s)", i, c.id, c.label))
end
p("若第 N 个候选让通知中心弹出了, 锁定它只需一行:  touch.useSenderIDAt(N)")
p("也可以把本文件的 LOCK_INDEX 改成 N 再跑一次, 脚本会自动锁定该值。")
p("若一次都没弹出, 请把 debug.log + touch.log 发回, 说明问题不在 senderID 而在更底层。")
