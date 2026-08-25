-- demo.lua — QQ音乐 Lua 示例脚本
-- 运行方式:
--   1) [运行 Lua] 按钮: 直接运行 (无网页配置时 settings 为空表)
--   2) [脚本UI] → demo: 网页中配置参数, 点"开始运行"后由原生运行本脚本,
--      用户配置以全局 settings 表注入 (对应 /var/mobile/touch/lua/demo.settings.json)
-- 把本文件复制到 /var/mobile/touch/lua/demo.lua 即可自行编辑(优先加载)。

-- ===== 网页设置 UI 配置读取演示 =====
-- settings 表由原生注入, 字段与 www/ui/demo/index.html 中的 data-key 对应
logStr("===== 网页设置 UI 配置 =====")
logStr("卡密:    " .. (settings.kami     or "(未设置)"))
logStr("角色:    " .. (settings.roleName or "(未设置)"))
logStr("运行方式: " .. (settings.runMode  or "restart"))
logStr("挂机地图: " .. (settings.map      or "wuye"))
logStr("自动买药: " .. tostring(settings.autoBuy))
logStr("买药数量: " .. tostring(settings.buyCount or 100))
logStr("战斗模式: " .. (settings.battleMode or "auto"))
logStr("技能顺序: " .. (settings.skillOrder or "4,3,2,1"))
logStr("低血回城: " .. tostring(settings.lowHp or 30) .. "%")
logStr("重连间隔: " .. tostring(settings.reconnectSec or 30) .. "s")
logStr("详细日志: " .. tostring(settings.verboseLog))
logStr("============================")

-- ===== 基础用法 =====
logStr("QQ音乐 Lua 脚本启动!")

-- 屏幕尺寸
local w, h = getScreenSize()
logStr(string.format("屏幕尺寸: %.0f x %.0f", w, h))

-- 全屏找红色 (0xFF0000)，相似度 0.9
local x, y = findColor(0xFF0000)
if x then
    logStr(string.format("找到红色像素 at (%.0f, %.0f)", x, y))
    tap(x, y)               -- 点击该点
    mSleep(500)             -- 延时 500ms
else
    logStr("全屏未找到红色")
end

-- 在指定区域找色: findColor(颜色, x, y, w, h, 相似度)
local x2, y2 = findColor(0x00FF00, 100, 200, 300, 400, 0.85)
if x2 then
    logStr(string.format("区域内找到绿色 at (%.0f, %.0f)", x2, y2))
end

-- 取某点颜色
local c = getColor(100, 100)
logStr(string.format("点(100,100)颜色 = 0x%06X", c))

-- 多点找色: findColors(主色, 偏移表, 相似度)
local offsets = {
    { dx = 10,  dy = 0,  color = 0x00FF00 },
    { dx = 0,   dy = 10, color = 0x0000FF },
}
local mx, my = findColors(0xFF0000, offsets, 0.9)
if mx then
    logStr(string.format("多点找色命中 at (%.0f, %.0f)", mx, my))
end

-- ===== 常用动作 =====
-- tap(x, y)            单击
-- swipe(x1,y1,x2,y2, 毫秒)  滑动
-- mSleep(毫秒)         延时

-- 滑动示例 (从 (160, 300) 滑到 (160, 100)，耗时 500ms)
-- swipe(160, 300, 160, 100, 500)

logStr("脚本执行完毕")
