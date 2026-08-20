# TrollAutoTouch Lua 找色脚本教程

TrollAutoTouch 内置 Lua 5.4 解释器，可运行 `.lua` 脚本实现自动找色、点击、滑动等操作。
本教程按模块列出**所有可用函数**，并给出可直接运行的示例。

---

## 1. 如何运行 Lua 脚本

### 方式一：App 内置按钮
打开 App → 点击 **「运行 Lua」** 按钮。脚本查找顺序：
1. `/var/mobile/touch/lua/demo.lua`（用户可自行编辑，优先）
2. 内置 `demo.lua`（App 自带示例）

点击 **「停止 Lua」** 可中断正在运行的脚本。

### 方式二：脚本放置位置（固定简化路径，不依赖沙盒）
```
/var/mobile/touch/lua/demo.lua    ← 脚本
/var/mobile/touch/log/            ← 本地日志
/var/mobile/touch/res/            ← 资源文件（图片等）
```
这三个目录 App 首次启动时自动创建，放好后点 **「运行 Lua」** 即加载 `/var/mobile/touch/lua/demo.lua`。
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

-- 自动命名保存到 /var/mobile/touch/log/snapshot_*.png
local p2 = snapshot()
```

### 屏幕保持: `screen.keep()` / `screen.unkeep()`

`screen.keep()` 会把当前屏幕像素缓存到内存。之后脚本里的
`findColor` / `findColors` / `getColor` / `findImage` **全部直接复用这帧缓存**，
不再重复截屏，找图找色性能极大提升（画面静止的挂机脚本尤其明显）。

```lua
screen.keep()             -- 保持屏幕(缓存当前帧)，之后找色找图不再截屏

local a = findColor(0xFF0000)   -- 读缓存
local b = getColor(100, 200)    -- 读缓存
local x, y = findImage("/tmp/btn.png")  -- 读缓存

screen.unkeep()           -- 取消保持，释放内存中的图像数据，恢复实时截屏
```

⚠️ **重要：缓存期间屏幕内容被"冻结"**。`screen.keep()` 后脚本读到的一直是
开始保持那一刻的画面，如果屏幕内容已变化，必须 `screen.unkeep()`（或重新
`screen.keep()` 刷新缓存），否则会一直按旧画面找色。

```lua
-- 推荐写法: 画面固定时保持，画面变化后刷新
while true do
    screen.keep()                         -- 保持当前画面
    local x, y = findColor(0x00FF00)
    if x then
        tap(x, y)
        screen.unkeep()                   -- 点击后画面可能变化，释放
    end
    mSleep(500)
end
```

> 兼容写法：`keepScreen(true)` / `keepScreen(false)` 与
> `screen.keep()` / `screen.unkeep()` 完全等价，任选一种即可。

---

## 6. 系统信息与设备

```lua
-- 屏幕尺寸(分辨率): 全局 getScreenSize() / sys.screenSize() / screen.getSize() 等效
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

> **注意**：`getScreenSize()` 返回**逻辑分辨率（点）**，如 iPhone 15 Pro Max 为 `430 x 932`，物理像素是 `1290 x 2796`。
> 本引擎的 `tap` / `findColor` / `getColor` / `swipe` 等全部使用**同一套点坐标**，直接用返回值即可，无需换算。
> 如需截图文件的物理像素尺寸，可用 `file.readImage(路径)` 返回 `w, h`（该值为像素）。

### 6.1 屏幕方向 `screen.init`

横屏游戏/应用可用 `screen.init(方向)` 指定**脚本坐标系方向**，让同一套坐标在设备横竖屏切换后仍指向正确位置：

```lua
screen.init(0)   -- 脚本坐标系 = home 在下（竖屏，默认）
screen.init(1)   -- 脚本坐标系 = home 在右
screen.init(2)   -- 脚本坐标系 = home 在左
```

- 方向参数：`0` = home 在下，`1` = home 在右，`2` = home 在左；传入其他值会被忽略并打印提示。
- 设置后，`tap` / `touchDown` / `touchMove` / `touchUp` / `swipe` / `stroke` / `findColor` / `findColors` / `findImage` / `getColor` 的坐标全部按该方向解释，引擎自动旋转到设备**当前实际方向**后再执行。
- 返回值也统一换算回脚本坐标系：`getScreenSize`（横竖屏不同时宽高互换）、`findText`、`appNode` 节点坐标。
- 脚本坐标系与设备实际方向一致时**零额外开销**；不一致时才做 90° 旋转换算。

> 示例：横屏游戏按 `screen.init(1)` 写脚本，即使设备被切到竖屏，触摸和取色依然落在横屏坐标系的正确位置。

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
```

### 9.1 屏幕悬浮提示 `sys.toast` / `toast`

在**任意前台 App 之上**短暂显示一条提示（非阻塞，不影响脚本继续执行），常用于
通知"任务开始 / 完成 / 出错"。

```lua
-- 语法: sys.toast(提示消息, [显示时间毫秒], [是否隐藏])
sys.toast("任务完成")                    -- 默认显示 1000 毫秒
sys.toast("倒计时 3 秒", 3000)           -- 显示 3000 毫秒(3 秒)
sys.toast("正在找色...", 500, true)      -- 弱化模式

-- 全局 toast() 完全等效, 两种写法任选
toast("兼容写法")
```

- **显示时间**（可选，毫秒，默认 `1000`）：到时间自动消失。
- **是否隐藏**（可选，布尔，默认 `false`）：`true` 时改用**屏幕顶部小字弱化样式**，
  尽量不占用屏幕中部的找色/找图区域，适合长时间挂机时的低频提示。
- **非阻塞**：函数调用后立即返回，脚本继续往下执行；提示由系统级 HUD 托管窗口显示，
  即使脚本在后台运行也能看到。
- 注意：HUD 托管窗口显示在系统层，截屏找色仍以屏幕实际像素为准（IOSurface 帧缓冲），
  弱化模式只是把文字移到屏幕最上方，避开绝大多数找色区域。

```lua
-- 实际用法: 找色成功时提示
local x, y = findColor(0xFF0000, 0.9)
if x then
    tap(x, y)
    sys.toast("找到红色按钮并点击", 1500)
else
    sys.toast("未找到按钮", 1000, true)
end
```

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

-- 固定简化路径(同 /var/mobile/touch 下)
file.touchDir()   -- /var/mobile/touch
file.luaDir()     -- /var/mobile/touch/lua   (脚本)
file.logDir()     -- /var/mobile/touch/log   (日志)
file.resDir()     -- /var/mobile/touch/res   (资源文件)
-- 例如读取资源图片:
local w, h = file.readImage(file.resDir() .. "/button.png")
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
| `screen.keep()` / `keepScreen(true)` | 保持屏幕(缓存当前帧)，提升找色找图性能 |
| `screen.unkeep()` / `keepScreen(false)` | 取消保持，释放内存中的图像数据 |
| `getScreenSize()` | 屏幕尺寸 → w,h |
| `mSleep(ms)` / `sleep(sec)` | 延时 |
| `logStr(s)` / `print(...)` | 日志 |
| `sys.toast(msg[, ms][, hidden])` / `toast(...)` | 屏幕悬浮提示（非阻塞，默认 1000ms，可指定显示时长与弱化模式） |
| `findText(s)` | OCR 找文字 → x,y |

**模块**：`touch.` `screen.` `sys.` `device.` `app.` `appNode.` `json.` `str.` `file.` `pasteboard.` `key.`
