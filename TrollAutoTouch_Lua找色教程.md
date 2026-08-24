# TrollAutoTouch Lua 脚本完整教程

TrollAutoTouch 内置 **Lua 5.4** 解释器，支持运行 `.lua` 脚本实现自动找色、点击、滑动、OCR 文字识别、UI 自动化等操作。

本教程按模块列出**所有可用函数**，并给出可直接运行的示例。

---

## 目录

- [1. 脚本运行机制](#1-脚本运行机制)
- [2. 找色函数（核心）](#2-找色函数核心)
- [3. 找图与 OCR](#3-找图与-ocr)
- [4. 截屏与屏幕缓存](#4-截屏与屏幕缓存)
- [5. 触摸与手势](#5-触摸与手势)
- [6. 延时与日志](#6-延时与日志)
- [7. 系统弹窗与悬浮提示](#7-系统弹窗与悬浮提示)
- [8. 屏幕方向与坐标系](#8-屏幕方向与坐标系)
- [9. 应用管理](#9-应用管理)
- [10. UI 树节点 (appNode)](#10-ui-树节点-appnode)
- [11. 文件与目录](#11-文件与目录)
- [12. 字符串与 JSON](#12-字符串与-json)
- [13. 剪贴板与按键](#13-剪贴板与按键)
- [14. 网页设置 UI (ui.open)](#14-网页设置-ui-uiopen)
- [15. 全局变量与运行环境](#15-全局变量与运行环境)
- [16. 完整示例](#16-完整示例)
- [17. 全局函数速查表](#17-全局函数速查表)

---

## 1. 脚本运行机制

### 1.1 脚本目录结构

App 首次启动会自动创建以下目录（TrollStore 沙盒外，稳定可写）：

```
/var/mobile/touch/
├── lua/            ← Lua 脚本目录 (.lua / .tas / 项目文件夹)
├── log/            ← 日志目录 (debug.log, snapshot_*.png)
└── res/            ← 资源目录 (图片等)
```

### 1.2 三种运行方式

#### 方式一：单文件脚本

将 `.lua` 文件放到 `/var/mobile/touch/lua/` 下，App 配置页会列出所有脚本。点击脚本即可运行。

`.tas` 是加密后的 Lua 脚本（由 App 内置加密功能生成），运行时自动解密。

#### 方式二：文件夹项目（多文件 + 资源）

**新增功能**：可以将多个 `.lua` 文件和资源文件打包到一个文件夹中作为项目运行。

```
/var/mobile/touch/lua/
├── my_project/              ← 项目文件夹 (会显示在配置页)
│   ├── main.lua              ← 入口文件（自动识别）
│   ├── utils.lua             ← 被 require('utils') 加载
│   ├── config.lua            ← 被 require('config') 加载
│   └── images/
│       └── button.png        ← 资源文件
├── standalone.lua            ← 单文件脚本
└── ...
```

**入口文件查找顺序**：
1. `main.lua`
2. `init.lua`
3. `index.lua`
4. `app.lua`
5. 第一个 `.lua` 文件（按字母排序）

**项目运行时注入的全局变量**：

| 变量 | 说明 |
|---|---|
| `_SCRIPT_PATH_` | 入口文件完整路径 |
| `_SCRIPT_DIR_` | 项目目录完整路径 |
| `_PROJECT_DIR_` | 项目目录完整路径（同 `_SCRIPT_DIR_`） |

**项目运行时自动配置**：
- Lua `package.path` 包含项目目录，支持 `require('module')` 加载模块
- `file.scriptDir()` 返回项目目录

#### 方式三：音量键快速运行

App 常驻音量键监听（需在设置中开启 TAS 服务）：
- **空闲时按音量键** → 弹出"运行选中脚本/项目？"对话框
- **脚本运行中按音量键** → 弹出"暂停/继续 · 停止 · 取消"控制菜单

选中状态在配置页点击脚本/项目即设置（持久化保存）。

### 1.3 脚本停止机制

- 脚本调用 `mSleep(ms)` / `sleep(sec)` 时检查停止标志
- 每 5000 条 Lua 指令检查一次停止钩子（死循环也能被中断）
- 点击 App 内"停止"按钮 / 悬浮窗停止按钮 / 音量键菜单中的"停止"

---

## 2. 找色函数（核心）

### 2.1 单点找色 `findColor`

在屏幕上查找指定颜色的点。

#### 调用形式

```lua
findColor(color)                              -- 全屏找色，sim=0.9
findColor(color, sim)                         -- 全屏找色，指定相似度
findColor(color, x, y, w, h)                  -- 区域找色，sim=0.9
findColor(color, x, y, w, h, sim)             -- 区域找色，指定相似度
findColor(color, rect, sim)                   -- 区域找色（table 形式）
```

#### 参数

| 参数 | 类型 | 说明 |
|---|---|---|
| `color` | number | 颜色值 `0xRRGGBB` |
| `sim` | number | 相似度 0~1，默认 `0.9` |
| `x, y, w, h` | number | 区域左上角坐标和宽高 |
| `rect` | table | `{x=, y=, width=, height=}` |

#### 返回值

- 找到：返回 `x, y`（两个数字）
- 未找到：返回 `nil`

#### 示例

```lua
-- 全屏找纯红色
local x, y = findColor(0xFF0000)
if x then tap(x, y) end

-- 指定相似度 0.85
local x, y = findColor(0x2E8B57, 0.85)

-- 区域找色: findColor(颜色, x, y, w, h, 相似度)
local x, y = findColor(0x00FF00, 100, 200, 300, 400, 0.9)

-- 区域用 table 形式
local x, y = findColor(0x00FF00, {x=100, y=200, width=300, height=400}, 0.9)
```

> 颜色格式：`0xRRGGBB`（红、绿、蓝，6位 hex）。

### 2.2 多点找色 `findColors`（偏移表形式）

适合查找"由多个固定颜色点组成"的目标（如按钮、图标特征）。

#### 调用形式

```lua
findColors(mainColor, offsets, sim)
findColors(mainColor, offsets, x, y, w, h, sim, offSim)
findColors(mainColor, offsets, rect, sim)
```

#### 参数

| 参数 | 类型 | 说明 |
|---|---|---|
| `mainColor` | number | 主色 `0xRRGGBB` |
| `offsets` | table | 偏移点数组（见下） |
| `sim` | number | 主色相似度，默认 `0.9` |
| `offSim` | number | 偏移点相似度，默认等于 `sim` |
| `x, y, w, h` | number | 区域左上角和宽高 |

#### 偏移点表格式

支持两种写法：

```lua
-- 写法一: 字段名
local offsets = {
    { dx = 10,  dy = 0,   color = 0x00FF00 },   -- 主色右侧 10px 是绿色
    { dx = 0,   dy = 10,  color = 0x0000FF },   -- 主色下方 10px 是蓝色
}

-- 写法二: 数组形式
local offsets = {
    { 10, 0,   0x00FF00 },
    { 0,  10,  0x0000FF },
}
```

#### 返回值

- 找到：返回主色点坐标 `x, y`
- 未找到：返回 `nil`

#### 示例

```lua
local offsets = {
    { dx = 10, dy = 0,  color = 0x00FF00 },
    { dx = 0,  dy = 10, color = 0x0000FF },
}

-- 全屏多点找色
local x, y = findColors(0xFF0000, offsets, 0.9)

-- 区域多点找色
local x, y = findColors(0xFF0000, offsets, 100, 100, 200, 200, 0.9, 0.85)

-- 区域用 table 形式
local x, y = findColors(0xFF0000, offsets, {x=100, y=100, width=200, height=200}, 0.9)

if x then
    tap(x, y)
end
```

### 2.3 多点找色 `findColors`（颜色模板字符串形式）

AutoGo `images.FindMultiColors` 风格，用一行字符串同时描述"区域 + 主色 + 所有偏移点"。

#### 调用形式

```lua
findColors(x1, y1, x2, y2, colorsStr, sim)
```

#### 参数

| 参数 | 类型 | 说明 |
|---|---|---|
| `x1, y1` | number | 区域左上角坐标 |
| `x2, y2` | number | 区域右下角坐标；传 `0` 表示使用屏幕最大宽高 |
| `colorsStr` | string | 颜色模板字符串 |
| `sim` | number | 相似度 0.1~1.0，默认 `0.9` |

#### 颜色模板字符串格式

```
主色, 偏移x, 偏移y, 颜色, 偏移x, 偏移y, 颜色, ...
```

- 第 **1** 个元素是**主色**（基准点），6 位 hex 颜色，如 `4a9a10`
- 之后每 **3 个元素一组** = 一个偏移点，顺序是 `偏移x, 偏移y, 颜色`
- 偏移是相对主色点的坐标差，可为负数
- 颜色可带 `-偏色` 后缀（如 `ffccff-151515`），偏色会被忽略，统一由 `sim` 控制

#### 示例

```lua
-- 在区域 (378,547)-(402,569) 内找"主色4a9a10 + 5个偏移点"，相似度 0.9
local x, y = findColors(378, 547, 402, 569,
    "4a9a10,1,-1,429a10,2,-1,4a9e10,3,-1,4a9a10,4,-1,4aa608,5,-1,429a10", 0.9)
if x then
    tap(x, y)
end

-- 区域右下角传 0 = 使用屏幕最大宽高
local x2, y2 = findColors(100, 200, 0, 0, "bd2c31,-10,13,732429,0,22,732421", 0.9)
```

> 字符串解析示例：`"4a9a10,1,-1,429a10,2,-1,4a9e10"` 解析为：
> - 主色 `4a9a10`
> - 偏移点 `(1,-1)` 颜色 `429a10`
> - 偏移点 `(2,-1)` 颜色 `4a9e10`

### 2.4 取色 `getColor`

获取屏幕某一点的颜色值（调试用）。

```lua
local c = getColor(100, 100)        -- 返回 0xRRGGBB
logStr(string.format("颜色 = 0x%06X", c))
```

> 截屏失败时返回 `0`。

### 2.5 取色 RGB 分量 `screen.getColorRGB`

获取屏幕某一点的 R、G、B 三个分量，省去脚本里的位运算。

```lua
-- screen.getColorRGB(横坐标, 纵坐标) → r, g, b
local r, g, b = screen.getColorRGB(100, 100)
logStr(string.format("R=%d G=%d B=%d", r, g, b))

-- 判断是否为纯白色
if r == 255 and g == 255 and b == 255 then
    logStr("颜色值匹配: 纯白")
end

-- 判断是否接近红色 (R 分量高, G/B 分量低)
if r > 200 and g < 60 and b < 60 then
    logStr("接近纯红色")
end
```

| 参数 | 类型 | 说明 |
|---|---|---|
| `x` | number | 屏幕横坐标 |
| `y` | number | 屏幕纵坐标 |

#### 返回值

返回三个 0~255 的整数：

| 返回值 | 类型 | 范围 | 说明 |
|---|---|---|---|
| `r` | number | 0~255 | 红色分量 |
| `g` | number | 0~255 | 绿色分量 |
| `b` | number | 0~255 | 蓝色分量 |

> 截屏失败时返回 `0, 0, 0`。
>
> 与 `getColor(x, y)` 等价，只是省去了脚本里的位运算。两种写法互换：
> ```lua
> -- getColor 写法
> local c = getColor(100, 100)
> local r = (c >> 16) & 0xFF
> local g = (c >> 8) & 0xFF
> local b = c & 0xFF
>
> -- 等价的 getColorRGB 写法 (更简洁)
> local r, g, b = screen.getColorRGB(100, 100)
> ```

---

## 3. 找图与 OCR

### 3.1 模板找图 `findImage`

在屏幕上查找一张图片（模板匹配），常用于找按钮/图标/物品。

#### 调用形式

```lua
findImage(path)                            -- 全屏找图，accuracy=0.8
findImage(path, accuracy)                  -- 全屏找图，指定相似度
findImage(path, accuracy, x, y, w, h)      -- 区域找图
findImage(path, x, y, w, h)                -- 区域找图（省略 accuracy）
```

#### 参数

| 参数 | 类型 | 说明 |
|---|---|---|
| `path` | string | 图片文件完整路径 |
| `accuracy` | number | 相似度 0~1，默认 `0.8` |
| `x, y, w, h` | number | 区域左上角和宽高 |

#### 返回值

- 找到：返回图片中心点坐标 `x, y`
- 未找到：返回 `nil`

#### 示例

```lua
-- 全屏找图
local x, y = findImage("/var/mobile/touch/res/button.png", 0.85)

-- 区域找图
local x, y = findImage("/var/mobile/touch/res/icon.png", 0.85, 100, 100, 200, 200)

-- 区域找图（省略相似度，用默认 0.8）
local x, y = findImage("/var/mobile/touch/res/icon.png", 100, 100, 200, 200)

if x then
    tap(x, y)
end
```

### 3.2 OCR 找文字 `findText`

对当前屏幕进行 OCR 识别，查找指定文字的位置。

```lua
local x, y = findText("开始游戏")
if x then
    tap(x, y)
    logStr(string.format("找到文字 @ (%.0f, %.0f)", x, y))
end
```

#### 返回值

- 找到：返回文字中心坐标 `x, y`
- 未找到：返回 `nil`

> OCR 引擎需要设备支持，部分老旧设备可能识别率较低。

---

## 4. 截屏与屏幕缓存

### 4.1 保存截屏 `snapshot`

```lua
-- 保存到指定路径，返回完整路径
local path = snapshot("/var/mobile/touch/log/my_snap.png")

-- 自动命名保存到 /var/mobile/touch/log/snapshot_yyyyMMdd_HHmmss.png
local p2 = snapshot()
```

#### 返回值

- 成功：返回保存的完整路径
- 失败：返回 `nil`

### 4.2 屏幕保持 `screen.keep()` / `screen.unkeep()`

`screen.keep()` 把当前屏幕像素缓存到内存。之后脚本里的
`findColor` / `findColors` / `getColor` / `findImage` **全部直接复用这帧缓存**，
不再重复截屏，找图找色性能极大提升（画面静止的挂机脚本尤其明显）。

#### 三种等价写法

```lua
-- 写法一: screen 模块
screen.keep()         -- 保持屏幕
screen.unkeep()        -- 取消保持

-- 写法二: 全局 keep/unkeep
keep()
unkeep()

-- 写法三: 兼容写法 (布尔参数)
keepScreen(true)      -- 等价于 screen.keep()
keepScreen(false)    -- 等价于 screen.unkeep()
```

#### 使用示例

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

> ⚠️ **重要**：缓存期间屏幕内容被"冻结"。`screen.keep()` 后脚本读到的一直是开始保持那一刻的画面，如果屏幕内容已变化，必须 `screen.unkeep()`（或重新 `screen.keep()` 刷新缓存），否则会一直按旧画面找色。

---

## 5. 触摸与手势

### 5.1 点击 `tap`

```lua
tap(x, y)                            -- 单击（默认 50ms）
tap(x, y, 200)                       -- 按压 200 毫秒（长按）
tap(x, y, 200, 1.0, 5)               -- 完整参数: 时长ms, 压力(0~1), 触摸半径
```

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `x, y` | number | 必填 | 点击坐标 |
| `durationMs` | number | `50` | 按压时长（毫秒） |
| `pressure` | number | `1.0` | 压力值 0~1 |
| `radius` | number | `0` | 触摸半径 |

### 5.2 多点触摸（低层）

```lua
touchDown(index, x, y)               -- 第 index 根手指按下
touchMove(index, x, y)               -- 移动第 index 根手指
touchUp(index, x, y)                 -- 抬起第 index 根手指

-- 或用模块形式
touch.down(0, x, y)
touch.move(0, x, y)
touch.up(0, x, y)
```

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `index` | number | 必填 | 手指索引（0~9） |
| `x, y` | number | 必填 | 坐标 |
| `pressure` | number | `1.0` | 压力值（仅 down/move） |
| `radius` | number | `0` | 触摸半径（仅 down/move） |

#### 双指操作示例

```lua
touchDown(0, 100, 200)
touchDown(1, 300, 400)
touchMove(0, 120, 220)
touchMove(1, 280, 380)
touchUp(0, 120, 220)
touchUp(1, 280, 380)
```

### 5.3 滑动 `swipe`

```lua
swipe(x1, y1, x2, y2)                -- 默认 duration=0.3s, steps=20
swipe(x1, y1, x2, y2, 500)          -- 耗时 500ms
swipe(160, 300, 160, 100, 500)      -- 向上滑 500ms
swipe(100, 200, 200, 200, 200, 10)  -- 向右滑 200ms，10 步采样
```

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `x1, y1, x2, y2` | number | 必填 | 起点 / 终点 |
| `duration` | number | `0.3` | 时长（秒） |
| `steps` | number | `20` | 采样步数 |
| `pressure` | number | `1.0` | 压力值 |
| `radius` | number | `0` | 触摸半径 |

### 5.4 多点轨迹 `stroke`

```lua
-- stroke({x1,y1, x2,y2, x3,y3, ...}, duration)
stroke({100, 200, 150, 250, 200, 200, 250, 150}, 0.8)   -- 0.8 秒画完
```

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `points` | table | 必填 | 坐标点表，偶数长度 |
| `duration` | number | `0.3` | 总时长（秒） |

> 最多支持 256 个点。

### 5.5 触摸状态 `touchStatus`

返回当前触摸状态的描述字符串。

```lua
local status = touchStatus()
logStr(status)    -- 例如: "touches: 2, [0]=(100,200) down, [1]=(300,400) down"
```

---

## 6. 延时与日志

### 6.1 延时

```lua
mSleep(500)          -- 延时 500 毫秒
sleep(1.5)           -- 延时 1.5 秒
```

> `mSleep` / `sleep` 期间会响应停止标志，可被用户中断。参数必须为正数。

### 6.2 日志输出

```lua
logStr("这是一条日志")          -- 写入 debug.log 并显示在日志面板
print("也支持 print")           -- 与 logStr 等价
```

日志文件位于 `/var/mobile/touch/log/debug.log`。

---

## 7. 系统弹窗与悬浮提示

### 7.1 阻塞弹窗 `sys.alert`

显示一个阻塞式提示框，等待用户操作。

```lua
-- sys.alert(消息, [显示时间秒], [标题])
sys.alert("任务完成")                        -- 永久显示，带"确定"按钮
sys.alert("3 秒后消失", 3)                   -- 显示 3 秒后自动消失
sys.alert("错误", 0, "错误提示")              -- 永久显示，自定义标题
```

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `msg` | string | 必填 | 提示内容 |
| `timeout` | number | `0` | 显示时间（秒）；`0` = 永久显示带按钮，`>0` = 自动消失 |
| `title` | string | `"提示"` | 标题 |

### 7.2 带按钮的弹窗 `sys.alertButtons`

显示带多个按钮的提示框，阻塞等待用户点击。

```lua
-- sys.alertButtons(消息, {按钮1, 按钮2, ...}, [标题], [超时秒])
local clicked = sys.alertButtons("选择操作", {"确定", "取消", "重试"})
logStr("用户点击了: " .. clicked)

-- 带超时
local result = sys.alertButtons("继续?", {"是", "否"}, "确认", 10)
if result == nil then
    logStr("超时未点击")
end
```

#### 返回值

- 用户点击：返回按钮文本（string）
- 超时未点击：返回 `nil`

### 7.3 屏幕悬浮提示 `sys.toast` / `toast`

在**任意前台 App 之上**短暂显示一条提示（非阻塞，不影响脚本继续执行）。

```lua
-- sys.toast(消息, [显示时间毫秒], [是否隐藏])
sys.toast("任务完成")                    -- 默认显示 1000 毫秒
sys.toast("倒计时 3 秒", 3000)           -- 显示 3000 毫秒
sys.toast("正在找色...", 500, true)      -- 弱化模式（屏幕顶部小字）

-- 全局 toast() 完全等效
toast("兼容写法")
```

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `msg` | string | 必填 | 提示内容 |
| `ms` | number | `1000` | 显示时间（毫秒） |
| `hidden` | boolean | `false` | `true` = 弱化模式（顶部小字） |

> 非阻塞：函数调用后立即返回，脚本继续往下执行；提示由系统级 HUD 托管窗口显示，即使脚本在后台运行也能看到。

---

## 8. 屏幕方向与坐标系

### 8.1 屏幕尺寸 `getScreenSize`

```lua
local w, h = getScreenSize()
logStr(string.format("屏幕 %.0f x %.0f", w, h))
```

> 返回**逻辑分辨率（点）**，如 iPhone 15 Pro Max 为 `430 x 932`。本引擎所有坐标都使用同一套点坐标，无需换算。

### 8.2 屏幕方向初始化 `screen.init`

横屏游戏/应用可用 `screen.init(方向)` 指定**脚本坐标系方向**，让同一套坐标在设备横竖屏切换后仍指向正确位置。

```lua
screen.init(0)   -- 脚本坐标系 = home 在下（竖屏，默认）
screen.init(1)   -- 脚本坐标系 = home 在右
screen.init(2)   -- 脚本坐标系 = home 在左
```

| 参数 | 说明 |
|---|---|
| `0` | home 在下（竖屏） |
| `1` | home 在右 |
| `2` | home 在左 |

- 设置后，`tap` / `touchDown` / `touchMove` / `touchUp` / `swipe` / `stroke` / `findColor` / `findColors` / `findImage` / `getColor` 的坐标全部按该方向解释
- 引擎自动旋转到设备**当前实际方向**后再执行
- 返回值也统一换算回脚本坐标系：`getScreenSize`、`findText`、`appNode` 节点坐标

> 示例：横屏游戏按 `screen.init(1)` 写脚本，即使设备被切到竖屏，触摸和取色依然落在横屏坐标系的正确位置。

---

## 9. 应用管理

```lua
-- 前台应用 Bundle ID
local bid = app.frontBid()
if bid then
    logStr("当前前台: " .. bid)
end

-- 检查应用是否安装
local installed = app.isInstalled("com.xxx.game")
logStr("已安装: " .. tostring(installed))

-- 打开应用
app.open("com.xxx.game")

-- 关闭应用
app.close("com.xxx.game")

-- 向当前输入框输入文本
app.inputText("hello")
```

| 函数 | 返回值 | 说明 |
|---|---|---|
| `app.frontBid()` | string / nil | 当前前台 App bundle id |
| `app.isInstalled(bid)` | boolean | 是否安装 |
| `app.open(bid)` | boolean | 打开 App |
| `app.close(bid)` | boolean | 关闭 App |
| `app.inputText(text)` | boolean | 输入文本 |

---

## 10. UI 树节点 (appNode)

> ⚠️ 仅能遍历**本应用进程**的视图树（TrollStore App 以普通 App 身份运行，无法跨进程遍历其他 App 的 UI）。

### 10.1 获取完整视图树

```lua
-- 返回完整视图树 JSON 字符串
local tree = appNode.info()
logStr(tree)
```

### 10.2 按文本查找节点

```lua
-- 返回匹配节点列表
local nodes = appNode.findByText("开始游戏")
if nodes[1] then
    logStr(string.format("找到: %s @ (%.0f, %.0f)",
          nodes[1].class, nodes[1].centerX, nodes[1].centerY))
end
```

#### 节点字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `class` | string | 视图类名（如 `UIButton`） |
| `text` | string | 文本内容 |
| `centerX, centerY` | number | 中心坐标 |
| `frame` | table | `{x, y, width, height}` |

### 10.3 直接点击文本节点

```lua
-- 点击第一个匹配文本的节点
appNode.tapByText("确定")
```

### 10.4 缓存视图树

```lua
-- 缓存当前视图树（避免每次调用都重新遍历）
appNode.keep()

-- 多次调用都使用缓存
local n1 = appNode.findByText("按钮1")
local n2 = appNode.findByText("按钮2")

-- 释放缓存
appNode.unKeep()
```

---

## 11. 文件与目录

### 11.1 文件读写

```lua
-- 写文件
file.write("/var/mobile/touch/log/test.txt", "hello world")

-- 读文件
local content = file.read("/var/mobile/touch/log/test.txt")
logStr(content)

-- 文件是否存在
if file.exists("/var/mobile/touch/log/test.txt") then
    logStr("文件存在")
end

-- 删除文件
file.delete("/var/mobile/touch/log/test.txt")
```

### 11.2 目录路径

```lua
file.documentsDir()   -- App Documents 目录
file.touchDir()        -- /var/mobile/touch
file.luaDir()          -- /var/mobile/touch/lua    (脚本)
file.logDir()          -- /var/mobile/touch/log    (日志)
file.resDir()          -- /var/mobile/touch/res    (资源)
file.scriptDir()       -- 当前脚本/项目所在目录（新增）
```

### 11.3 读取图片尺寸

```lua
-- 读取图片的像素尺寸
local w, h = file.readImage(file.resDir() .. "/button.png")
logStr(string.format("图片尺寸: %d x %d", w, h))
```

> `file.readImage` 返回**物理像素**尺寸，与 `getScreenSize` 返回的**逻辑分辨率（点）**不同。

### 11.4 项目目录使用示例

```lua
-- 在项目中加载资源文件
local imgPath = file.scriptDir() .. "/images/button.png"
local x, y = findImage(imgPath, 0.85)

-- 在项目中加载配置文件
local configPath = file.scriptDir() .. "/config.json"
local configText = file.read(configPath)
local config = json.decode(configText)
```

---

## 12. 字符串与 JSON

### 12.1 字符串工具

```lua
str.md5("abc")              -- MD5 摘要
str.sha1("abc")             -- SHA1 摘要
str.split("a,b,c", ",")     -- 拆分 → {"a", "b", "c"}
str.trim("  hi  ")          -- 去空白 → "hi"
str.random(8)               -- 8 位随机字符串
str.urlEncode("a b c")      -- URL 编码 → "a%20b%20c"
str.urlDecode("%20")        -- URL 解码 → " "
```

### 12.2 JSON 编解码

```lua
-- 编码
local jsonText = json.encode({a = 1, b = {c = 2, d = "hello"}})
logStr(jsonText)    -- {"a":1,"b":{"c":2,"d":"hello"}}

-- 解码
local obj = json.decode(jsonText)
logStr(obj.b.d)      -- hello
```

---

## 13. 剪贴板与按键

### 13.1 剪贴板

```lua
-- 读取剪贴板
local s = pasteboard.get()
logStr("剪贴板内容: " .. s)

-- 写入剪贴板
pasteboard.set("新的内容")
```

### 13.2 物理按键

```lua
key.pressHome()             -- Home 键
key.pressLock()             -- 锁屏键
key.pressVolumeUp()         -- 音量+
key.pressVolumeDown()       -- 音量-
key.inputText("abc")        -- 模拟键盘输入文本
```

---

## 14. 网页设置 UI (ui.open)

打开一个内置 WebView 网页，让用户在网页上配置脚本参数，配置内容会注入为 Lua 全局 `settings` 表。

```lua
-- ui.open(HTML 内容)
ui.open([[
<html>
<body>
<h2>脚本设置</h2>
<input type="text" id="username" placeholder="用户名">
<button onclick="ts.save({username: username.value})">保存</button>
</body>
</html>
]])

-- 配置内容会注入为全局 settings 表
logStr(settings.username)
```

> 网页通过 JavaScript 调用 `ts.save(obj)` 保存配置，保存后脚本可通过 `settings` 全局表读取。

---

## 15. 全局变量与运行环境

### 15.1 内置全局变量

| 变量 | 说明 |
|---|---|
| `_SCRIPT_PATH_` | 当前脚本/入口文件的完整路径 |
| `_SCRIPT_DIR_` | 项目目录完整路径（仅项目运行时存在） |
| `_PROJECT_DIR_` | 项目目录完整路径（同 `_SCRIPT_DIR_`） |
| `settings` | 网页 UI 配置表（由 `_injectSettingsTable` 注入） |

### 15.2 项目运行时支持 `require()`

项目运行时（`runProject:`）会自动配置 Lua `package.path` 包含项目目录：

```
项目目录/?.lua;项目目录/?/init.lua
```

这样脚本中可以直接 `require('module')` 加载项目中的其他 Lua 文件。

```lua
-- main.lua
local utils = require('utils')        -- 加载 utils.lua
local config = require('config')      -- 加载 config.lua

function main()
    utils.doSomething(config.target)
end

main()
```

### 15.3 脚本配置文件 `<script>.settings.json`

运行脚本时，引擎会按以下顺序查找配置文件并注入为 `settings` 表：
1. 设备目录下的同名 `.settings.json`
2. 脚本同目录下的同名 `.settings.json`

例如运行 `main.lua` 时会查找 `main.settings.json`。

---

## 16. 完整示例

### 16.1 单文件：找色点击自动任务

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

### 16.2 单文件：多点找色挂机循环

```lua
-- 用多点找色精确定位目标，配合 screen.keep 提升性能
local offsets = {
    { dx = 10, dy = 0,  color = 0x00FF00 },
    { dx = 0,  dy = 10, color = 0x0000FF },
}

while true do
    screen.keep()    -- 缓存当前画面
    local x, y = findColors(0xFF0000, offsets, 0.9)
    screen.unkeep()  -- 释放缓存
    
    if x then
        tap(x, y)
        sys.toast("已点击目标", 500, true)
    end
    mSleep(1000)     -- 每秒检查一次
end
```

### 16.3 项目结构：多文件协作

项目目录 `/var/mobile/touch/lua/my_game_bot/`：

```
my_game_bot/
├── main.lua              ← 入口
├── utils.lua             ← 工具函数
├── config.lua            ← 配置
└── images/
    ├── start_btn.png
    └── confirm_btn.png
```

**main.lua**：

```lua
local utils = require('utils')
local config = require('config')

local SCRIPT_DIR = _SCRIPT_DIR_

function main()
    logStr("启动游戏脚本")
    
    -- 用项目中的图片找按钮
    local x, y = findImage(SCRIPT_DIR .. "/images/start_btn.png", 0.85)
    if x then
        tap(x, y)
        mSleep(2000)
    end
    
    -- 多点找色确认
    local cx, cy = utils.findConfirmBtn(config.color, config.offsets)
    if cx then
        tap(cx, cy)
        sys.toast("任务完成", 2000)
    end
end

main()
```

**utils.lua**：

```lua
local M = {}

function M.findConfirmBtn(mainColor, offsets)
    return findColors(mainColor, offsets, 0.9)
end

function M.waitColor(color, timeoutMs)
    timeoutMs = timeoutMs or 10000
    local start = os.clock()
    while (os.clock() - start) * 1000 < timeoutMs do
        local x, y = findColor(color, 0.9)
        if x then return x, y end
        mSleep(500)
    end
    return nil
end

return M
```

**config.lua**：

```lua
return {
    color = 0xFF0000,
    offsets = {
        { dx = 10, dy = 0, color = 0x00FF00 },
        { dx = 0, dy = 10, color = 0x0000FF },
    },
}
```

### 16.4 颜色模板字符串解析（兼容旧引擎）

如果使用旧版引擎不支持 `findColors(x1,y1,x2,y2,colorsStr,sim)` 形式，可用 Lua 自行解析：

```lua
-- AREA[名称] = {x1, y1, x2, y2, 颜色模板字符串, 相似度}
AREA = {
    button1 = {378, 547, 402, 569, "4a9a10,1,-1,429a10,2,-1,4a9e10", 0.9},
}

function findArea(str)
    local t = AREA[str]
    if t == nil then
        logStr("findArea: 区域不存在: " .. tostring(str))
        return false
    end
    local x1, y1, x2, y2 = t[1], t[2], t[3], t[4]
    local colorsStr = t[5]
    local sim = t[6] or 0.9

    -- 按逗号拆分
    local parts = {}
    for p in string.gmatch(tostring(colorsStr), "[^,]+") do
        parts[#parts + 1] = p
    end
    
    -- "RRGGBB-偏色" → 0xRRGGBB
    local function hexColor(s)
        local dash = string.find(s, "-")
        if dash then s = string.sub(s, 1, dash - 1) end
        return tonumber("0x" .. s)
    end
    
    local mainColor = hexColor(parts[1])
    local offsets = {}
    local i = 2
    while i + 2 <= #parts do
        offsets[#offsets + 1] = {
            dx = tonumber(parts[i]),
            dy = tonumber(parts[i + 1]),
            color = hexColor(parts[i + 2]),
        }
        i = i + 3
    end
    
    local x, y = findColors(mainColor, offsets, x1, y1, x2 - x1, y2 - y1, sim)
    return x ~= nil
end

if findArea("button1") then
    logStr("找到按钮 1")
end
```

---

## 17. 全局函数速查表

### 找色找图

| 函数 | 说明 |
|---|---|
| `findColor(color[, sim])` | 全屏单点找色 → x,y / nil |
| `findColor(color, x,y,w,h[, sim])` | 区域单点找色 |
| `findColor(color, rect[, sim])` | 区域单点找色（table） |
| `findColors(mainColor, offsets[, sim])` | 全屏多点找色（偏移表） → x,y / nil |
| `findColors(mainColor, offsets, x,y,w,h[, sim][, offSim])` | 区域多点找色 |
| `findColors(mainColor, offsets, rect[, sim])` | 区域多点找色（table） |
| `findColors(x1,y1,x2,y2, colorsStr[, sim])` | 多点找色（颜色模板字符串） → x,y / nil |
| `findImage(path[, accuracy])` | 全屏找图 → x,y / nil |
| `findImage(path, accuracy, x,y,w,h)` | 区域找图 |
| `findImage(path, x,y,w,h)` | 区域找图（省略 accuracy） |
| `getColor(x, y)` | 取色 → 0xRRGGBB |
| `screen.getColorRGB(x, y)` | 取色 RGB 分量 → r, g, b（0~255） |
| `findText(text)` | OCR 找文字 → x,y / nil |

### 截屏与缓存

| 函数 | 说明 |
|---|---|
| `snapshot([path])` | 保存截屏 → 路径 / nil |
| `screen.keep()` / `keep()` / `keepScreen(true)` | 保持屏幕（缓存当前帧） |
| `screen.unkeep()` / `unkeep()` / `keepScreen(false)` | 取消保持 |

### 触摸与手势

| 函数 | 说明 |
|---|---|
| `tap(x, y[, dur][, pressure][, radius])` | 点击 |
| `touchDown(i, x, y[, pressure][, radius])` | 手指按下 |
| `touchMove(i, x, y[, pressure][, radius])` | 手指移动 |
| `touchUp(i, x, y)` | 手指抬起 |
| `swipe(x1,y1,x2,y2[, dur][, steps][, pressure][, radius])` | 滑动 |
| `stroke({x1,y1,...}[, dur])` | 多点轨迹 |
| `touchStatus()` | 触摸状态描述 |

### 延时与日志

| 函数 | 说明 |
|---|---|
| `mSleep(ms)` | 延时毫秒 |
| `sleep(sec)` | 延时秒 |
| `logStr(s)` / `print(...)` | 日志输出 |
| `toast(msg[, ms][, hidden])` / `sys.toast(...)` | 屏幕悬浮提示（非阻塞） |
| `sys.alert(msg[, timeout][, title])` | 阻塞弹窗 |
| `sys.alertButtons(msg, {btns}[, title][, timeout])` | 带按钮弹窗 → 按钮文本 / nil |

### 屏幕与方向

| 函数 | 说明 |
|---|---|
| `getScreenSize()` / `screen.getSize()` / `sys.screenSize()` | 屏幕尺寸 → w,h |
| `screen.init(dir)` | 设置脚本坐标系方向（0/1/2） |

### 系统信息

| 函数 | 说明 |
|---|---|
| `sys.info()` | 设备信息 → table |
| `sys.osVersion()` | 系统版本 |
| `sys.model()` | 设备型号 |
| `sys.getIP()` | WiFi IP |
| `sys.battery()` | 电量 0~1 |

### 应用管理

| 函数 | 说明 |
|---|---|
| `app.frontBid()` | 前台 App bundle id → string / nil |
| `app.isInstalled(bid)` | 是否安装 → boolean |
| `app.open(bid)` | 打开 App → boolean |
| `app.close(bid)` | 关闭 App → boolean |
| `app.inputText(text)` | 输入文本 → boolean |

### UI 树节点

| 函数 | 说明 |
|---|---|
| `appNode.info()` | 完整视图树 JSON → string |
| `appNode.findByText(text)` | 按文本查找节点 → 节点列表 |
| `appNode.tapByText(text)` | 点击文本节点 |
| `appNode.keep()` | 缓存视图树 |
| `appNode.unKeep()` | 释放视图树缓存 |

### 文件与目录

| 函数 | 说明 |
|---|---|
| `file.read(path)` | 读文件 → string / nil |
| `file.write(path, content)` | 写文件 → boolean |
| `file.exists(path)` | 是否存在 → boolean |
| `file.delete(path)` | 删除 → boolean |
| `file.documentsDir()` | App Documents 目录 |
| `file.touchDir()` | `/var/mobile/touch` |
| `file.luaDir()` | `/var/mobile/touch/lua` |
| `file.logDir()` | `/var/mobile/touch/log` |
| `file.resDir()` | `/var/mobile/touch/res` |
| `file.scriptDir()` | 当前脚本/项目目录 |
| `file.readImage(path)` | 图片尺寸 → w,h（像素） |

### 字符串与 JSON

| 函数 | 说明 |
|---|---|
| `str.md5(s)` | MD5 |
| `str.sha1(s)` | SHA1 |
| `str.split(s, sep)` | 拆分 → table |
| `str.trim(s)` | 去空白 |
| `str.random(n)` | 随机字符串 |
| `str.urlEncode(s)` | URL 编码 |
| `str.urlDecode(s)` | URL 解码 |
| `json.encode(obj)` | 编码 JSON → string |
| `json.decode(s)` | 解码 JSON → table |

### 剪贴板与按键

| 函数 | 说明 |
|---|---|
| `pasteboard.get()` | 读剪贴板 → string |
| `pasteboard.set(s)` | 写剪贴板 |
| `key.pressHome()` | Home 键 |
| `key.pressLock()` | 锁屏 |
| `key.pressVolumeUp()` | 音量+ |
| `key.pressVolumeDown()` | 音量- |
| `key.inputText(s)` | 模拟键盘输入 |

### UI 设置

| 函数 | 说明 |
|---|---|
| `ui.open(html)` | 打开网页设置 UI |

### 模块列表

| 模块 | 别名 | 说明 |
|---|---|---|
| `touch` | - | 触摸手势 |
| `screen` | - | 屏幕相关 |
| `sys` | `device` | 系统信息 |
| `app` | - | 应用管理 |
| `appNode` | - | UI 树节点 |
| `json` | - | JSON 编解码 |
| `str` | - | 字符串工具 |
| `file` | - | 文件操作 |
| `pasteboard` | - | 剪贴板 |
| `key` | - | 物理按键 |
| `ui` | - | 网页 UI |

---

## 附：常见问题

| 问题 | 解决 |
|---|---|
| `attempt to call a nil value` | 函数名拼错，或该函数未注册 |
| `findColor` 找不到 | 降低相似度（如 0.7~0.8）；确认颜色格式是 `0xRRGGBB` |
| 颜色取不到 | 用 `getColor(x, y)` 确认目标点颜色，再写死到脚本 |
| 相似度与颜色混合 | 纯色目标建议 `0.9`；图片类目标用 `findImage` |
| 脚本卡死 | 点击 App 内"停止"按钮；脚本应避免 `while true do end` 无延时循环 |
| 项目 `require` 失败 | 确认项目以文件夹形式运行（不是单文件）；模块文件后缀必须是 `.lua` |
| 横屏坐标错乱 | 在脚本开头调用 `screen.init(1)` 或 `screen.init(2)` |
| `screen.keep()` 后找不到目标 | 缓存的是旧画面，画面变化后需 `screen.unkeep()` 释放再重新 keep |
