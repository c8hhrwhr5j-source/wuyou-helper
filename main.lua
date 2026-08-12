
APP = "com.tencent.rxcq" -- APP 包名

function main()
    sleep(1000)
    log("脚本运行开始")
    local w, h = getScreenSize()
    logStr(string.format("屏幕 %.0f x %.0f", w, h))
    while true do
        sleep(1000)
        appsl()
        if getColor(254, 667) == 0x9C6D39 then
            log("找到坚屏公告确定按钮")
            tap(254, 667)  
            sleep(1000)
        else
            local c = getColor(254, 667)
            log("坚屏颜色 "..c)
        end

        if getColor(665, 496) == 0xA56D29 then
            log("找到横屏公告确定按钮")
            tap(665, 496)  
            sleep(1000)
        else
            local c = getColor(665, 496)
            log("横屏颜色 "..c)
        end

    end
end

-- 打印日志
function log(txt)
    logStr(txt)
end

-- 系统延时
function sleep(s)
    mSleep(s)
end

-- 前台应用 Bundle ID
function appsl()
    local bid = app.frontBid()
    if bid ~= APP then
        log("前台应用非热血传奇，切换到热血传奇")
        app.open(APP)
        sleep(2000)
    end
end



main()