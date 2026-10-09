--[==[ ui详细使用.lua —— 分组版
  每类控件一个 section; 分组用自带 title (系统灰色小节头), 不需要 info 行。
  行内 default 控制首次打开的默认值 (settings.json 保存过的值优先):
    switch → true/false    segmented/select → 数字索引 1/2/3 (或选项字符串)
    number/slider → 数字   text → 字符串
    checkGroup/multi → {true,true,false,...} 按位置勾选 (或 {"选项名",...})
]==]

if not ui.run{
    title = "ui详细使用",          -- 顶部大标题横幅 (导航栏下方 24pt bold 居中)
    build = function()
        return {
            sections = {
                {title = "开关设置", rows = {
                    {type = "switch", key = "autoStart", label = "启动后自动开始",
                     default = true},                                       -- 默认开
                }},
                {title = "滑块设置", rows = {
                    {type = "segmented", key = "mode", label = "运行模式",
                     options = {"快速", "安全", "自定义"}, default = 2},     -- 默认第 2 项"安全"
                }},
                {title = "下拉框设置", rows = {
                    {type = "select", key = "role", label = "角色",
                     options = {"战士", "法师", "道士"}},                    -- 未写 default → 默认第 1 项"战士"
                }},
                {title = "数字设置", rows = {
                    {type = "number", key = "retry", label = "失败重试",
                     min = 0, max = 10, keyboard = "number", default = 3},   -- 默认 3 (不写则是 min)
                }},
                {title = "滑动条设置", rows = {
                    {type = "slider", key = "speed", label = "运行速度",
                     min = 0.5, max = 2, step = 0.1, format = "%.1fx"},      -- 默认 0.5 (由 min 决定)
                }},
                {title = "时间设置", rows = {
                    {type = "switch", key = "useAlarm", label = "定时休息",
                     default = false},                                       -- 默认"否": 不启用
                    {type = "date",   key = "alarmAt",  label = "启动时间", mode = "time",
                     visibleWhen = "useAlarm", visibleWhenValue = true},    -- 开"是"才显示; 关闭时值保留不丢
                    {type = "date",   key = "restEnd",  label = "结束时间", mode = "time",
                     visibleWhen = "useAlarm", visibleWhenValue = true},    -- 同一个总开关控制
                }},
                {title = "文本框设置", rows = {
                    {type = "text", key = "notes", label = "一行显示内容",
                     default = "你好！",                -- 默认值: 打开就填好在框里
                     placeholder = "请输入要喊话的内容"},      -- (placeholder 只是提示)
                }},
                {title = "文本框设置", rows = {
                    {type = "textLong", key = "notes", label = "大框显示",
                     default = "你好！",                -- 默认值: 打开就填好在框里
                     placeholder = "请输入要喊话的内容"},      -- (placeholder 只是提示)
                }},
                {title = "多选框设置", rows = {
                    {type = "checkGroup", key = "taskSel", label = "要执行的任务", columns = 3,
                     options = {"师门", "帮派", "捉鬼", "宝图", "运镖", "三任务"},
                     default = {true, true, false, false, false, false}},    -- 默认勾中前两项
                }},
            },
        }
    end,
} then
    return  -- 点『取消』: 引擎已停止脚本, 不要再调用引擎接口
end

-- 点『运行』后: 把每个配置值输出到日志
for _, k in ipairs(ui.keys()) do
    local v = ui.get(k)
    if type(v) == "table" then
        v = #v > 0 and table.concat(v, "、") or "(空)"
    end
    logStr(string.format("  %-12s = %s", k, tostring(v)))
end
