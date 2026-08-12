
function main()
    sleep(1000)
    log("脚本运行开始")
    local w, h = getScreenSize()
    logStr(string.format("屏幕 %.0f x %.0f", w, h))
    while true do
        sleep(500)
        if getColor(254, 667) == "0x9C6D39" then
            log("找到坚屏公告确定按钮")
            tap(254, 667)  
            sleep(1000)
        end

        if getColor(665, 496) == "0xA56D29" then
            log("找到横屏公告确定按钮")
            tap(665, 496)  
            sleep(1000)
        end
        
        log("脚本循环中...")
    end
end

function log(txt)
    logStr(txt)
end

function sleep(s)
    mSleep(s)
end





main()