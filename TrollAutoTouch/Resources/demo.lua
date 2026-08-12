-- demo.lua — TrollAutoTouch Lua 找色点击示例
-- 通过 [运行 Lua] 按钮执行；把本文件复制到
-- /var/mobile/touch/lua/demo.lua 后即可自行编辑(优先加载)。
-- 其他目录: /var/mobile/touch/log 放本地日志, /var/mobile/touch/res 放资源文件。

-- ===== 基础用法 =====
logStr("TrollAutoTouch Lua 脚本启动!")

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
