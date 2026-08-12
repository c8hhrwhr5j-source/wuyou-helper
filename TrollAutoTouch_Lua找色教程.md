# TrollAutoTouch Lua 找色脚本教程

TrollAutoTouch 内置 Lua 5.4 解释器，可运行 `.lua` 脚本实现自动找色、点击、滑动等操作。
本教程按模块列出**所有可用函数**，并给出可直接运行的示例。

---

## 1. 如何运行 Lua 脚本

### 方式一：App 内置按钮
打开 App → 点击 **「运行 Lua」** 按钮。脚本查找顺序：
1. `Documents/demo.lua`（用户可自行编辑，优先）
2. 内置 `demo.lua`（App 自带示例）

点击 **「停止 Lua」** 可中断正在运行的脚本。

### 方式二：脚本放置位置
把脚本放到 App 的 Documents 目录即可被加载：
```
/var/mobile/Documents/TrollAutoTouch/demo.lua   ← 具体路径以 App 沙盒为准
```
> 脚本里所有函数均为**全局函数**，无需 require 任何模块。

---

## 2. 找色函数（核心）

### 2.1 单点找色 `findColor`

```lua
-- 全屏找色，相似度默认 0.9
local x, y = findColor(0xFF0000)              -- 找纯红色
local x, y = findColor(0x2E8B57, 0.85)        -- 指定相似度 0.85

-- 在指定区域找色: findColor(颜色, x, y, w, h, 相似度)
local x, y = findColor(0x00FF00, 100, 200, 300, 400, 0.9)

-- 区域用 table 形式: findColor(颜色, {x=,y=,width=,height=}, 相似度)
local x, y = findColor(0x00FF00, {x=100, y=200, width=300, height=400}, 0.9)
```

**返回值**：找到返回 `x, y`（数字），未找到返回 `nil`。

> 颜色格式：`0xRRGGBB`（红、绿、蓝）。

### 2.2 多点找色 `findColors`

适合找"由多个固定颜色点组成"的目标（比如图标、按钮特征）。

```lua
-- 偏移表：相对主色点的 dx/dy 和对应颜色
local offsets = {
    { dx = 10,  dy = 0,   color = 0x00FF00 },   -- 主色右侧 10px 是绿色
    { dx = 0,   dy = 10,  color = 0x0000FF },   -- 主色下方 10px 是蓝色
}

-- 全屏多点找色: findColors(主色, 偏移表, 相似度)
local x, y = findColors(0xFF0000, offsets, 0.9)

-- 区域多点找色: findColors(主色, 偏移表, x, y, w, h, 相似度, 偏移点相似度)
local x, y = findColors(0xFF0000, offsets, 100, 100, 200, 200, 0.9, 0.85)
```

**返回值**：找到返回 `x, y`（主色点坐标），未找到返回 `nil`。

> 偏移表也支持 `{ {10, 0, 0x00FF00}, {0, 10, 0x0000FF} }` 这种数组形式。

### 2.3 模板找图 `findImage`

在屏幕上查找一张图片（模板匹配），常用于找按钮/图标/物品。

```lua
-- 全屏找图: findImage(图片路径, 相似度)
local x, y = findImage("/path/to/button.png", 0.85)

-- 区域找图: findImage(图片路径, 相似度, x, y, w, h)
local x, y = findImage("/path/to/icon.png", 0.85, 100, 100, 200, 200)

-- 区域找图(省略相似度): findImage(图片路径, x, y, w, h)
local x, y = findImage("/path/to/icon.png", 100, 100, 200, 200)
```

**返回值**：找到返回 `x, y`（图片中心点），未找到返回 `nil`。

> 相似度取值范围 0~1，越大越严格，默认 0.8。

### 2.4 取色 `getColor`

获取屏幕某一点的颜色值（调试用）。

```lua
local c = getColor(100, 100)        -- 返回 0xRRGGBB
logStr(string.format("颜色 = 0x%06X", c))
```

---

## 3. 动作函数

### 3.1 点击 `tap`

```lua
tap(x, y)                            -- 单击
tap(x, y, 0.2)                       -- 按压 0.2 秒(长按)
```

### 3.2 多点触摸（低层）

```lua
touchDown(0, x1, y1)   -- 第 0 根手指按下
touchMove(0, x2, y2)   -- 移动第 0 根手指
touchUp(0, x2, y2)     -- 抬起第 0 根手指

-- 双指操作示例
touchDown(0, 100, 200)
touchDown(1, 300, 400)
touchMove(0, 120, 220)
touchMove(1, 280, 380)
touchUp(0, 120, 220)
touchUp(1, 280, 380)
```

### 3.3 滑动 `swipe`

```lua
-- swipe(x1, y1, x2, y2, 时长毫秒, 采样步数)
swipe(160, 300, 160, 100, 500)      -- 向上滑，耗时 500ms
swipe(100, 200, 200, 200, 200, 10)  -- 向右滑 200ms，10 步
```

### 3.4 多点轨迹 `stroke`

```lua
-- 一笔画轨迹: stroke({x1,y1, x2,y2, x3,y3, ...}, 总时长毫秒)
stroke({100, 200, 150, 250, 200, 200, 250, 150}, 800)
```

---

## 4. 延时与循环

```lua
mSleep(500)          -- 延时 500 毫秒
sleep(1.5)           -- 延时 1.5 秒

-- 经典"找色直到出现"循环
for i = 1, 10 do
    local x, y = findColor(0xFF0000, 0.9)
    if x then
        tap(x, y)
        break
    end
    mSleep(500)      -- 每 500ms 找一次
end
```

---

## 5. 截屏与缓存

```lua
-- 保存当前屏幕截图，返回完整路径
local path = snapshot("/tmp/my_snap.png")

-- 自动命名保存到 Documents
local p2 = snapshot()

-- 缓存屏幕像素: 连续多次 findColor 时提高性能
keepScreen(true)          -- 开始缓存
local a = findColor(0xFF0000)
local b = findColor(0x00FF00)
keepScreen(false)         -- 释放缓存(画面变化后必须释放并重新缓存)
```

---

## 6. 系统信息与设备

```lua
-- 屏幕尺寸
local w, h = getScreenSize()
logStr(string.format("屏幕 %.0f x %.0f", w, h))

-- 设备信息
local info = sys.info()                 -- 返回 table
logStr(info.model or "")
logStr(sys.osVersion())                 -- 系统版本
logStr(sys.model())                     -- 设备型号
local w2, h2 = sys.screenSize()
local ip = sys.getIP()                  -- WiFi IP
local battery = sys.battery()           -- 电量 0~1
```

---

## 7. 应用管理

```lua
-- 前台应用 Bundle ID
local bid = app.frontBid()

-- 检查/打开/关闭应用
local installed = app.isInstalled("com.xxx.game")
app.open("com.xxx.game")
app.close("com.xxx.game")

-- 向当前输入框输入文本
app.inputText("hello")
```

---

## 8. UI 树（appNode）

> 仅能遍历本应用进程的视图树（TrollStore App 以普通 App 身份运行，无法跨进程遍历）。

```lua
-- 获取完整视图树 JSON
local tree = appNode.info()

-- 按文本查找节点
local nodes = appNode.findByText("开始游戏")
if nodes[1] then
    logStr(string.format("找到: %s @ (%.0f, %.0f)",
          nodes[1].class, nodes[1].centerX, nodes[1].centerY))
end

-- 直接点击文本节点
appNode.tapByText("开始游戏")

-- 缓存/释放视图树
appNode.keep()
appNode.unKeep()
```

---

## 9. 日志、JSON、字符串、文件

```lua
-- 日志
logStr("这是一条日志")
print("也支持 print")

-- JSON
local jsonText = json.encode({a = 1, b = {c = 2}})
local obj = json.decode(jsonText)

-- 字符串工具
str.md5("abc")          -- md5 摘要
str.sha1("abc")         -- sha1 摘要
str.split("a,b,c", ",") -- 拆分
str.trim("  hi  ")      -- 去空白
str.random(8)           -- 8 位随机字符串
str.urlEncode("a b")    -- URL 编码
str.urlDecode("%20")    -- URL 解码

-- 文件操作
file.write("/tmp/x.txt", "content")
local content = file.read("/tmp/x.txt")
file.exists("/tmp/x.txt")
file.delete("/tmp/x.txt")
local docDir = file.documentsDir()
```

---

## 10. 剪贴板与按键

```lua
-- 剪贴板
local s = pasteboard.get()
pasteboard.set("new text")

-- 物理按键
key.pressHome()
key.pressLock()
key.pressVolumeUp()
key.pressVolumeDown()
key.inputText("abc")
```

---

## 11. 完整示例：找色点击自动任务

```lua
-- 示例: 找红色"开始"按钮 → 点击 → 等待 → 找绿色"确认"按钮 → 点击
logStr("自动任务开始")

local W, H = getScreenSize()

-- 1. 等待红色按钮出现(最多等 10 秒)
local btn = nil
for i = 1, 20 do
    btn = findColor(0xFF0000, 0.9)
    if btn then break end
    mSleep(500)
end
if not btn then
    logStr("超时: 未找到红色按钮")
    return
end
logStr(string.format("找到红色按钮 @ (%.0f, %.0f)", btn))
tap(btn)

-- 2. 点击后等待 2 秒
mSleep(2000)

-- 3. 区域找绿色确认按钮
local x, y = findColor(0x00FF00, W/2 - 100, H/2, W/2 + 100, H/2 + 100, 0.85)
if x then
    tap(x, y)
    logStr("已点击确认")
else
    logStr("未找到绿色确认按钮")
end

logStr("自动任务结束")
```

---

## 12. 常见问题

| 问题 | 解决 |
|---|---|
| 脚本报 `attempt to call a nil value` | 函数名拼错，或该函数未注册（本教程之外的原版专有函数不可用） |
| `findColor` 找不到 | 降低相似度(如 0.7~0.8)；确认颜色格式是 `0xRRGGBB`；先在屏幕上用"截屏预览"确认 |
| 颜色取不到 | 用 `getColor(x, y)` 确认目标点颜色，再写死到脚本 |
| 相似度与颜色混合 | 注意屏幕渲染有抗锯齿/阴影，纯色目标建议相似度 0.9，图片类目标用 `findImage` |
| 如何停止死循环脚本 | 点击 App 内 **「停止 Lua」** 按钮 |

---

## 附：全局函数速查表

| 函数 | 说明 |
|---|---|
| `findColor(c[, x,y,w,h][, sim])` | 单点找色 → x,y |
| `findColors(c, offsets[, x,y,w,h][, sim][, offSim])` | 多点找色 → x,y |
| `findImage(path[, accuracy][, x,y,w,h])` | 模板找图 → x,y |
| `getColor(x, y)` | 取色 → 0xRRGGBB |
| `tap(x, y[, dur])` | 点击 |
| `touchDown/up/move(i, x, y)` | 多点触摸 |
| `swipe(x1,y1,x2,y2[, ms][, steps])` | 滑动 |
| `stroke({x1,y1,...}, ms)` | 多点轨迹 |
| `snapshot([path])` | 保存截屏 → 路径 |
| `keepScreen(bool)` | 缓存/释放截屏 |
| `getScreenSize()` | 屏幕尺寸 → w,h |
| `mSleep(ms)` / `sleep(sec)` | 延时 |
| `logStr(s)` / `print(...)` | 日志 |
| `toast(s)` | 悬浮提示 |
| `findText(s)` | OCR 找文字 → x,y |

**模块**：`touch.` `screen.` `sys.` `device.` `app.` `appNode.` `json.` `str.` `file.` `pasteboard.` `key.`
