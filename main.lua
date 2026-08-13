APP = "com.tencent.rxcq" -- APP 包名

-- ============================================================
-- 触摸注入诊断脚本 v3
-- 重点: 在每个阶段强制触发 ensureInjected 并打印详细状态,
--       便于定位 deploy / 直接注入 (task_for_pid/vm_alloc/thread_create)
--       / opainject fallback 哪一步失败。
-- ============================================================

function main()
    sleep(1000)
    log("=== 触摸注入测试脚本 v3 ===")
    local w, h = getScreenSize()
    log(string.format("屏幕 %.0f x %.0f", w, h))

    -- 关键诊断: senderID 是否就绪
    log("[阶段0] 初始触摸状态: " .. touchStatus())
    log("[阶段0] 提示: 若显示 senderID=0, 请先在设备上手动触摸一次屏幕, 再重跑本脚本")

    -- 测试点: 本应用灰色设置按钮 (562,1280)
    local tx, ty = 562, 1280

    -- === 阶段1: 强制触发注入 (touchDown 立即 touchUp) ===
    -- ensureInjected 在第一次 touchDown 时执行, 走直接远程线程注入,
    -- 失败则回退 opainject。此处单独跑一次, 把注入阶段日志与触摸解耦。
    log("=== 阶段1: 强制触发注入 (touchDown+touchUp @ 测试点) ===")
    log(string.format("touchDown(0, %d, %d)", tx, ty))
    touchDown(0, tx, ty)
    log("[阶段1] touchDown 后状态: " .. touchStatus())
    sleep(50)
    log(string.format("touchUp(0, %d, %d)", tx, ty))
    touchUp(0, tx, ty)
    sleep(500)
    log("[阶段1] touchUp 后状态: " .. touchStatus())

    -- === 阶段2: 长按 2 秒 (观察按钮是否高亮) ===
    log("=== 阶段2: 长按 2 秒 ===")
    log(string.format("touchDown(0, %d, %d)", tx, ty))
    touchDown(0, tx, ty)
    log("[阶段2] touchDown 后状态: " .. touchStatus())
    sleep(2000)
    log(string.format("touchUp(0, %d, %d)", tx, ty))
    touchUp(0, tx, ty)
    sleep(1500)
    log("[阶段2] touchUp 后状态: " .. touchStatus())

    -- === 阶段3: 短按 (检测页面变化) ===
    log("=== 阶段3: tap 短按 ===")
    tap(tx, ty)
    sleep(1500)
    local c = getColor(558, 1294)
    log(string.format("[阶段3] tap 后 getColor(558,1294) = 0x%06X (期望 0x007AFF=蓝色设置按钮)", c))
    if c == 0x007AFF then
        log(">>> 设置页面, 点击成功!")
    else
        log(">>> tap 后未检测到页面变化")
    end
    log("[阶段3] tap 后状态: " .. touchStatus())

    -- === 阶段4: 再长按 1 秒, 确认状态 ===
    log("=== 阶段4: 再长按 1 秒 ===")
    touchDown(0, tx, ty)
    sleep(1000)
    touchUp(0, tx, ty)
    sleep(1000)

    log("[最终] 触摸状态: " .. touchStatus())
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
