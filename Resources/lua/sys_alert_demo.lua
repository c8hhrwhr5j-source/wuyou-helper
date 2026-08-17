--- sys.alert / sys.alertButtons 用法演示
--- 用法: 在 App 中运行本脚本即可看到效果
--- (需先将本文件复制到 /var/mobile/touch/lua/ 目录)

-- 1. 简单提示: 显示 2 秒后自动消失
sys.alert("2秒后自动消失", 2)

-- 2. 永久显示: 显示时间=0, 带"确定"按钮, 用户点击后关闭
sys.alert("点击确定关闭", 0, "TrollAutoScript")

-- 3. 带按钮提示: 返回用户点击的按钮文本 (阻塞等待)
local choice = sys.alertButtons("游戏提示", {"暂停", "继续", "取消"}, "选择操作")
sys.alert("你选择了: " .. tostring(choice), 2, "选择结果")

-- 4. 带超时的按钮提示: 5 秒未点击自动关闭, 返回 nil
local r = sys.alertButtons("5秒内做出选择", {"打怪", "采药", "回城"}, "超时演示", 5)
if r == nil then
    sys.alert("超时了, 没有选择", 2)
else
    sys.alert("你选择了: " .. r, 2)
end

-- 5. 实战场景: 脚本暂停/继续
local action = sys.alertButtons("脚本即将暂停, 选择操作", {"暂停脚本", "继续运行"}, "脚本控制")
if action == "暂停脚本" then
    sys.alert("脚本已暂停 3 秒", 3)
    sys.msleep(3000)
    sys.alert("脚本继续运行", 2)
end

sys.alert("演示结束", 2, "TrollAutoScript")
