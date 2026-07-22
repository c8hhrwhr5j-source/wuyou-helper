APP = "com.tencent.rxcq"

-- ============================================================
--  工具函数
-- ============================================================

-- 验证取色结果非全黑（非0x000000表示基本有效）
function isValidColor(c)
    return c ~= 0x000000
end

-- 确保目标APP在前台，返回是否成功
function ensureTargetForeground()
    local bid = app.frontBid()
    if bid == APP then return true end
    log("[前台] 检测到非目标APP(" .. tostring(bid) .. ")，切换至热血传奇...")
    screen.keep(true)                 -- 切前台前锁定帧缓冲
    local ok = app.run(APP)
    if not ok then
        log("[前台] 启动热血传奇失败")
        return false
    end
    sleep(3000)
    screen.keep(true)                 -- 切回后重新锁定
    return app.frontBid() == APP
end

-- 安全取色：带重试验证，失败时主动恢复
function safeGetColor(x, y, label)
    local retries = 3
    for i = 1, retries do
        local c = screen.getColor(x, y)
        if isValidColor(c) then return c end
        if i == retries then break end
        log("[取色] " .. label .. " 返回0x000000，重试 " .. i .. "/" .. retries)
        screen.keep(true)
        app.run(APP)
        sleep(1500)
    end
    return 0x000000
end

-- 安全点击：确保目标前台后再点击
function safeTap(x, y)
    if app.frontBid() ~= APP then
        ensureTargetForeground()
    end
    touch.tap(x, y)
end

-- 深度恢复：取色持续失败时执行
function deepRecover(consecutiveErrors)
    local delay = consecutiveErrors * 2000
    if delay > 15000 then delay = 15000 end
    log("[恢复] 连续失败" .. consecutiveErrors .. "次，深度恢复，等待" .. (delay // 1000) .. "秒...")
    screen.keep(true)
    app.kill(APP)
    sleep(2000)
    app.run(APP)
    sleep(4000)
    screen.keep(true)
    log("[恢复] 深度恢复完成")
end

-- ============================================================
--  主循环
-- ============================================================

function main()
    log("========================================")
    log("  热血传奇自动化脚本 - 后台取色点击版")
    log("========================================")
    
    local w, h = screen.resolution()
    log(string.format("分辨率: %d x %d, 帧缓冲就绪: %s", w, h, tostring(screen.isReady())))

    -- 启动时锁定帧缓冲，确保持续可读
    screen.keep(true)
    log("帧缓冲已锁定")

    -- 打开热血传奇
    log("正在启动热血传奇...")
    app.run(APP)
    sleep(4000)
    screen.keep(true)

    local loopCount = 0
    local blackCount = 0          -- 连续取黑计数器
    local lastForegroundCheck = 0

    while true do
        loopCount = loopCount + 1

        -- 每10次循环检查一次前台状态（避免过于频繁）
        if loopCount - lastForegroundCheck >= 10 then
            lastForegroundCheck = loopCount
            local currentBid = app.frontBid()
            if currentBid ~= APP then
                log("[前台] 目标APP丢失(" .. tostring(currentBid) .. ")，重新激活...")
                ensureTargetForeground()
                blackCount = 0
            end
        end

        -- 安全取色：公告栏关闭检测点
        local color1 = safeGetColor(586, 958, "公告点1(586,958)")
        local color2 = safeGetColor(958, 163, "公告点2(958,163)")

        -- 判断取色有效性
        if not isValidColor(color1) and not isValidColor(color2) then
            blackCount = blackCount + 1
            log("[异常] 全黑取色 x" .. blackCount)

            if blackCount >= 5 then
                deepRecover(blackCount)
                blackCount = 0
            else
                screen.keep(true)
                app.run(APP)
                sleep(2500)
            end
        else
            -- 恢复正常，清零计数器
            if blackCount > 0 then
                log("[恢复] 取色恢复正常")
            end
            blackCount = 0

            log(string.format("color1=0x%06X  color2=0x%06X", color1, color2))

            -- 检测公告关闭按钮（红色 0xB53431）
            if color1 == 0xB53431 or color2 == 0xB53431 then
                log("[动作] 检测到公告窗口，点击关闭...")
                safeTap(958, 173)
                sleep(1200)
            end
        end

        log("循环: " .. loopCount .. "  异常计数: " .. blackCount)
        sleep(500)
    end
end

main()
