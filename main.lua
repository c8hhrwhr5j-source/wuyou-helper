APP = "com.tencent.rxcq"

function main()
    log("主程序运行开始！")
    
    sleep(2000)
    color1 = screen.getColor(604, 749)
    log("color1=0x"..string.format("%06X", color1))

    color2 = screen.getColor(607, 725)
    log("color2=0x"..string.format("%06X", color2))
    log("本应用内初始取色完成！")
    
    sleep(2000)
    --screen.rotate(-90)   -- 旋转坐标体系向左90度
    local w, h = screen.resolution()     -- 获取屏幕分辨率
    log(string.format("屏幕分辨率: %d x %d", w, h))
    local wait = 0
    while true do
        sleep(500)
        Appsl()
        if screen.getColor(586, 958) == 0xB53431 or screen.getColor(958, 163) == 0xB53431 then
            log("关闭公告窗口！")
            touch.tap(958, 173)   -- 点击关闭
            sleep(1000)
        else
            color1 = screen.getColor(586, 958)
            log("color1=0x"..string.format("%06X", color1))

            color2 = screen.getColor(958, 163)
            log("color2=0x"..string.format("%06X", color2))
        end
        wait = wait + 1
        log("当前循环次数："..wait)
    end
end

function Appsl()
    local bid = app.frontBid()
    -- 判断是否在特定 App 中
    if bid ~= APP then
        log("当前前台应用不是热血传奇，执行打开热血传奇APP！")
        app.run(APP)  -- 打开热血传奇
        sleep(2000)   -- 等待应用启动
    end
end
main()