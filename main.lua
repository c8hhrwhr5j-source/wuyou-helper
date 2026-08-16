APP = "com.tencent.rxcq" -- APP 包名

function main()
    sleep(1000)
    log("=== 测试脚本开始 ===")
    local w, h = getScreenSize()
    log(string.format("屏幕 %.0f x %.0f", w, h))
    while true do
        sleep(1000)

        if getColor(563, 1280) == 0xA2A2A2 then
            click(563, 1280)
            sleep(1000)
            log("找到坚屏灰色设置按钮点击")
        end

        if getColor(1280, 187) == 0xA2A2A2 then
            click(1280, 187)
            sleep(1000)
            log("找到横屏灰色设置按钮点击")
        end

        if getColor(585, 959) == 0xB53029 then
            click(585, 959)
            sleep(1000)
            log("找到坚屏公告关闭按钮点击")
        end

        if getColor(959, 165) == 0xB53029 then
            click(959, 165)
            sleep(1000)
            log("找到横屏公告关闭按钮点击1")
        end
    end
end

--点击
function click(x, y)
    touchDown(0, x, y)
    sleep(20)
    touchUp(0, x, y)
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

init(1)

main()
