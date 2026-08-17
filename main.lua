APP = "com.tencent.rxcq" -- APP 包名

AREA={
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

function main()
    sleep(1000)
    log("=== 测试脚本开始 ===")
    local w, h = getScreenSize()
    log(string.format("屏幕 %.0f x %.0f", w, h))
    while true do
        sleep(100)
        appsl()
        if rgbbj("游戏公告") then
            click(948, 162, 970, 187) -- 关闭公告
            sleep(1000)
        elseif rgbbj("选区进入游戏") then
            click(834, 517, 950, 552) -- 进入游戏
            sleep(1000)
        elseif rgbbj("选择角色") then
            click(606,671,728,709) -- 进入游戏
            sleep(1000)
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
