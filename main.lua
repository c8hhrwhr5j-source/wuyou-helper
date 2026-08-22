APP = "com.tencent.rxcq" -- APP 包名

AREA={
        ["每日签到"]	       ={1123, 41, 1161, 79, "0xbd2c31,-10,13,0x732429,0,22,0x732421,12,11,0x7b2029,0,11,0xd6d3c6,-7,4,0xefd7c6,8,20,0xce9252,-7,19,0xcea67b,5,6,0xe7cfb5", 0.9},

        ["游戏公告"]	       ={{  668,  492, 0xA57531},{  958,  161, 0xBD2831},{  843,  173, 0x5A5D63},{  573,  514, 0x393431},{  680,  167, 0xEFC794},{  669,  523, 0x8C4518}},
	    ["选区进入游戏"]	   ={{  884,  526, 0xEF7510},{  891,  514, 0xFFBA10},{  855,  534, 0xDEC39C},{  921,  556, 0xC63800},{  857,  517, 0xEF9610},{  938,  539, 0xCEAE8C}},
	    ["选择角色"]	       ={{  700,  671, 0xF79E18},{  599,  677, 0xAD4510},{  632,  679, 0xF7EFCE},{  721,  701, 0xB5A284},{  699,  712, 0xC63400},{  650,  712, 0xDE4108}},
}       

-- 多点RGB找色（范围找）：按 AREA[str] 数组逐点取色，全部点在误差 25 内返回 true
function rgbbj(str)
    local pts = AREA[str]
    if pts == nil then
        logStr("脚本错误，请截图或拍照这个提示给脚本管理，rgbbj错误内容:" .. tostring(str))
        error("rgbbj: 区域不存在: " .. tostring(str))
    end
    keepScreen(true)
    local ok = true
    for i = 1, #pts do
        local p = pts[i]  -- 每个元素是 {x, y, color}
        if not bj(p[1], p[2], p[3], 25) then
            ok = false
            break
        end
    end
    keepScreen(false)
    return ok
end

-- 多点找色（区域模板字符串）：按 AREA[str] = {x1, y1, x2, y2, colorsStr, sim} 解析并区域找色
function findArea(str)
    local t = AREA[str]
    if t == nil then
        logStr("脚本错误，请截图或拍照这个提示给脚本管理，findArea错误内容:" .. tostring(str))
        error("findArea: 区域不存在: " .. tostring(str))
    end
    local x1, y1, x2, y2 = t[1], t[2], t[3], t[4]
    local colorsStr = t[5]
    local sim = t[6] or 0.9

    -- 解析颜色模板字符串: "主色,dx,dy,颜色,dx,dy,颜色,..."（主色在前，之后每 3 项一组偏移坐标+颜色）
    local parts = {}
    for p in string.gmatch(tostring(colorsStr), "[^,]+") do
        parts[#parts + 1] = p
    end
    -- 颜色格式兼容: RRGGBB / #RRGGBB / 0xRRGGBB，可带 "-偏色" 后缀（偏色忽略）
    local function hexColor(s)
        local dash = string.find(s, "-")
        if dash then s = string.sub(s, 1, dash - 1) end
        s = s:gsub("^#", "")
        if s:lower():sub(1, 2) == "0x" then
            return tonumber(s)
        end
        return tonumber("0x" .. s)
    end
    local mainColor = hexColor(parts[1])
    local offsets = {}
    local i = 2
    while i + 2 <= #parts do
        offsets[#offsets + 1] = {
            x = tonumber(parts[i]),
            y = tonumber(parts[i + 1]),
            color = hexColor(parts[i + 2]),
        }
        i = i + 3
    end
    -- 用偏移点数组形式调用 findColors(主色, 偏移数组, x, y, w, h, sim)，兼容旧引擎
    local x, y = findColors(mainColor, offsets, x1, y1, x2 - x1, y2 - y1, sim)
    if x ~= nil then return true end

    -- 失败诊断: 区分"区域/坐标不对(主色未命中)"与"颜色偏差(主色命中但偏移点不匹配)"
    if logStr then
        local c = getColor(math.floor((x1 + x2) / 2), math.floor((y1 + y2) / 2))
        local mx, my = findColor(mainColor, x1, y1, x2 - x1, y2 - y1, sim)
        if mx then
            logStr(string.format("findArea[%s] 失败: 主色命中(%d,%d)但偏移点不匹配 sim=%.2f 主色=0x%06X 区域中心色=0x%06X",
                                 str, mx, my, sim, mainColor, c))
        else
            logStr(string.format("findArea[%s] 失败: 区域(%d,%d,%d,%d)内未找到主色 0x%06X sim=%.2f 中心采样色=0x%06X",
                                 str, x1, y1, x2, y2, mainColor, sim, c))
        end
    end
    return false
end

-- 单点RGB找色（范围）：bj(x, y, color, err)，x/y 为脚本坐标，color 为 0xRRGGBB
function bj(x, y, color, err)
    local c = getColor(x, y)   -- 本项目 API：返回 0xRRGGBB 整数
    local r  = math.modf(c / 65536)
    local g  = math.modf(c / 256) % 256
    local b  = c % 256
    local r1 = math.modf(color / 65536)
    local g1 = math.modf(color / 256) % 256
    local b1 = color % 256
    if math.abs(r - r1) <= err and math.abs(g - g1) <= err and math.abs(b - b1) <= err then
        return true
    end
    return false
end

-- 网页设置（本脚本的 UI 名写死为 "main"，对应内置 www/ui/main 或设备 lua/ui/main）
-- ui.open("main") 行为：
--   * 检测到 UI 文件 → 全屏弹出设置页并阻塞等待：点"开始运行"返回 true（配置已注入
--     settings 表），点"返回"返回 false
--   * 检测不到 UI 文件 → 直接返回 false，不阻塞，脚本按默认配置继续
function main()
    if ui.open("main") then
        log("[设置] 已在手机端完成网页配置")
    else
        log("[设置] 未检测到网页UI或未配置，使用默认值")
    end

    local cfg = {
        delay      = 100,  -- 主循环间隔(毫秒)
        closeNotice= true, -- 关闭游戏公告
        enterArea  = true, -- 选区进入游戏
        chooseRole = true, -- 选择角色
        qiandao    = true, -- 每日签到
    }
    if type(settings) == "table" then
        for k, v in pairs(settings) do
            if cfg[k] ~= nil then cfg[k] = v end
        end
        log("[设置] 已加载网页配置: " .. json.encode(cfg))
    else
        log("[设置] 未使用网页配置，采用默认值")
    end

    sleep(1000)
    log("=== 测试脚本开始 ===")
    local w, h = getScreenSize()
    log(string.format("屏幕 %.0f x %.0f", w, h))
    while true do
        sleep(cfg.delay)
        appsl()
        if cfg.closeNotice and rgbbj("游戏公告") then
            click(948, 162, 970, 187) -- 关闭公告
            sleep(500)
            toast("关闭公告")
        elseif cfg.enterArea and rgbbj("选区进入游戏") then
            click(834, 517, 950, 552) -- 进入游戏
            sleep(500)
            toast("进入游戏")
        elseif cfg.chooseRole and rgbbj("选择角色") then
            click(606,671,728,709) -- 进入游戏
            sleep(500)
            toast("进入游戏")
        elseif findArea("每日签到") then
            click(1131,50,1156,71) -- 关闭每日签到
            sleep(500)
            toast("关闭每日签到")
        end
    end
end

--点击：x,y 为左上角，x1,y1 为右下角（可选），在该矩形范围内随机点击
local _clickSeeded = false
function click(x, y, x1, y1)
    if not _clickSeeded then
        math.randomseed(os.time())   -- 每次运行脚本重置随机序列
        _clickSeeded = true
    end
    if x1 == nil then x1 = x end
    if y1 == nil then y1 = y end
    if x1 < x then x, x1 = x1, x end  -- 兼容传反的情况
    if y1 < y then y, y1 = y1, y end
    local rx = math.random(math.floor(x), math.floor(x1))
    local ry = math.random(math.floor(y), math.floor(y1))
    touchDown(0, rx, ry)
    sleep(20)
    touchUp(0, rx, ry)
    sleep(100)
end

-- 打印日志
function log(txt)
    logStr(txt)
end

-- 系统延时 (毫秒)
function sleep(s)
    mSleep(s)
end

-- 初始化屏幕方向
function init(n)
    screen.init(n)   -- 脚本坐标系 0 = home 在下，1 = home 在右，2 = home 在左
end

-- 应用是否前台
function appsl()
    local bid = app.frontBid()
    if bid ~= APP then
        app.open(APP)
    end
end

init(1)

main()
