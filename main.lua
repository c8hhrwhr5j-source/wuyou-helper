APP = "com.tencent.rxcq"

-- ============================================================
--  工具函数
-- ============================================================

-- 检查并切换前台
function ensureForeground()
    local bid = app.frontBid()
    if bid == APP then return true end
    log("[前台] " .. tostring(bid) .. " -> 切换至热血传奇...")
    app.run(APP)
    sleep(3000)
    -- 后天切换后强制重连 IOMFB
    screen.refresh()
    sleep(500)
    local ret = app.frontBid() == APP
    if ret then
        local w,h=screen.resolution()
        log("[取色-切换后]\n"..screen.testPixel(w/2,h/2))
    end
    return ret
end

-- 健康检查：取色能力是否存活
function checkAlive()
    if not screen.alive() then
        log("[健康] 取色失效，重连 IOMFB...")
        screen.refresh()
        sleep(500)
        local ok = screen.alive()
        if not ok then
            local w,h=screen.resolution()
            log("[取色-失效检测]\n"..screen.testPixel(w/2,h/2))
        end
        return ok
    end
    return true
end

-- ============================================================
--  主循环
-- ============================================================

function main()
    log("=== 热血传奇自动化(后台取色版) ===")
    log(string.format("分辨率: %d x %d", screen.resolution()))
    log("[诊断] " .. screen.diagnose())   -- roothelper / IOMFB 状态
    local w,h=screen.resolution();log("[取色对比]\n"..screen.testPixel(w/2,h/2)) -- 屏幕中心像素测试
    local rr,gg,bb=screen.getColorRGB(w/2,h/2);log(string.format("  最终取色: R=%d G=%d B=%d (getColorRGB组合结果)",rr,gg,bb))

    screen.keep(true)

    -- 打开游戏
    app.run(APP)
    sleep(4000)
    screen.refresh()   -- 确保 IOMFB 连接有效

    local loop = 0
    while true do
        loop = loop + 1

        -- 每10轮做一次前台+健康校验
        if loop % 10 == 1 then
            checkAlive()
            ensureForeground()
        end

        -- 取色
        local color1 = screen.getColor(586, 958)
        local color2 = screen.getColor(958, 163)

        -- 异常全黑（原生层已自动重连，若仍全黑说明真黑）
        if color1 == 0x000000 and color2 == 0x000000 then
            log("[异常] 全黑取色，强制恢复...")
            screen.refresh()
            ensureForeground()
            sleep(2000)
        else
            log(string.format("color1=0x%06X  color2=0x%06X", color1, color2))

            -- 检测关闭按钮 (0xB53431)
            if color1 == 0xB53431 or color2 == 0xB53431 then
                log("[动作] 关闭公告窗口...")
                touch.tap(958, 173)
                sleep(1200)
            end
        end

        log(string.format("循环: %d", loop))
        sleep(500)
    end
end

main()
