APP = "com.tencent.rxcq" -- APP 包名

function main()
    sleep(1000)
    log("=== 触摸注入测试脚本 v2 ===")
    local w, h = getScreenSize()
    log(string.format("屏幕 %.0f x %.0f", w, h))

    -- 关键诊断: senderID 是否就绪
    log("初始触摸状态: " .. touchStatus())
    log("提示: 若显示 senderID=0, 请先在设备上手动触摸一次屏幕, 再重跑本脚本")

    -- 测试点: 本应用灰色设置按钮 (562,1280)
    local tx, ty = 562, 1280

    -- 测试1: 长按 (按下保持2秒再抬起, 观察按钮是否高亮)
    log("=== 测试1: 长按 2 秒 ===")
    log(string.format("touchDown(0, %d, %d)", tx, ty))
    touchDown(0, tx, ty)
    sleep(2000)
    log(string.format("touchUp(0, %d, %d)", tx, ty))
    touchUp(0, tx, ty)
    sleep(1500)
    log("测试1 后触摸状态: " .. touchStatus())

    -- 测试2: 短按
    log("=== 测试2: tap 短按 ===")
    tap(tx, ty)
    sleep(1500)
    local c = getColor(558, 1294)
    log(string.format("tap 后 getColor(558,1294) = 0x%06X (期望 0x007AFF=蓝色设置按钮)", c))
    if c == 0x007AFF then
        log(">>> 设置页面, 点击成功!")
    else
        log(">>> tap 后未检测到页面变化")
    end
    log("测试2 后触摸状态: " .. touchStatus())

    -- 测试3: 再长按 1 秒, 确认状态
    log("=== 测试3: 再长按 1 秒 ===")
    touchDown(0, tx, ty)
    sleep(1000)
    touchUp(0, tx, ty)
    sleep(1000)

    log("最终触摸状态: " .. touchStatus())
    log("=== 测试结束, 请把以上日志发给我 ===")
end

-- 打印日志
function log(txt)
    logStr(txt)
end

-- 系统延时 (毫秒)
function sleep(s)
    mSleep(s)
end

main()
