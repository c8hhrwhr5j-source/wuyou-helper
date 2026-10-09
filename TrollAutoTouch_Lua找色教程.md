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
  - 14.5 [浮动日志窗口 (logWindow)](#145-浮动日志窗口-logwindow)
  - 14.6 [重启脚本 (restartScript)](#146-重启脚本-restartscript)
  - 14.7 [脚本设置 UI 完整指南（HTML + UIKit 原生 共存）](#147-脚本设置-ui-完整指南html-网页--uikit-原生-共存)
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

### 1.4 脚本运行状态查询 `script.isPaused` / `script.isRunning`

查询 TrollAutoTouch **宿主脚本引擎**自身的运行状态——区分于 `app.isRunning()`（那个查的是“被操作的目标 App 进程是否在跑”，比如游戏进程；这里查的是“本 App 跑的 Lua 脚本本身”）。

```lua
script.isRunning()    -- → boolean  脚本是否在运行
script.isPaused()     -- → boolean  脚本是否被暂停
```

| 函数 | 含义 |
|---|---|
| `script.isRunning()` | 脚本是否正在运行（与 APP 内脚本列表里显示的“运行中”状态一致；不含“已派发但还没开跑”和“已停止但未退出”两个边缘窗口） |
| `script.isPaused()` | 脚本是否被暂停。触发暂停的来源：音量键菜单里的“暂停/继续”、主界面/悬浮球/HUD 上的暂停按钮 |

#### 典型用法：精确等待恢复

`isPaused()` 主要用于**超时控制**——脚本内部可以用它准确判定暂停状态，避免用“两次调用间隔”这种启发式阈值去猜。

例如宝图任务单轮 40\~70 秒，传统 30 秒超时阈值会误判任务为暂停；改用 `script.isPaused()` 即可：

```lua
-- 等到恢复运行（取消暂停），单次上限 15 秒
function waitWhilePaused(deadline)
    while script.isPaused() and sys.mtime() < deadline do
        mSleep(200)
    end
end

-- 等待恢复，带最长 60 秒超时
waitWhilePaused(sys.mtime() + 60000)
if script.isPaused() then
    -- 60 秒还没恢复，说明用户已离开或在决定是否继续
    logStr("暂停超过 60 秒仍未恢复，跳过本轮")
    return
end
```

#### 典型用法：循环体内主动响应暂停

```lua
-- 长循环中：每次切片前检查暂停, 让用户在按暂停后能立即冻结进度
while not done do
    if script.isPaused() then
        -- 暂停中: 不消耗任何业务逻辑, 一直睡到恢复
        while script.isPaused() do
            mSleep(200)
        end
    end
    -- ... 业务逻辑 ...
end
```

#### 实现说明

- 两个函数都是同步直读 `TSLuaBridge.shared` 里的 `isRunning` / `isPaused` 状态位（KVO-free），无锁、无阻塞，可高频调用。
- `isRunning` 仅在脚本**真正开始执行**后置为 YES、**真正退出**后置为 NO；与 UI 上的"运行中"标完全同步。
- 与 `app.isRunning(bid)`（查目标 App 进程）语义独立，**不要混用**。

### 1.5 设备重启后自动恢复服务（SLC 重大位置变化监听）

设备重启 / 被系统杀进程后，TrollAutoTouch **会在后台自动重新拉起**——TAS 服务、8080 远程访问端口、后台保活链全部自动接管，**不需要手动去点 App 图标**。挂机脚本在设备重启后可继续工作。

#### 工作机制

通过 iOS 系统的 **SLC（Significant Location Changes，重大位置变化）** 监听实现，是非越狱 TrollStore 下唯一可用的"重启后自动恢复"通道：

1. App 首次启动时调用 `startMonitoringSignificantLocationChanges` 注册 SLC
2. 该注册由 iOS 系统守护进程持久化记录，**跨进程终止、跨设备重启持久**存在
3. 设备重启后第一次发生**基站切换 / 移动约 500 米**时，系统自动在后台拉起 App 进程
4. App 进程的 `didFinishLaunching` 无条件启动 TAS 服务 + 8080 端口 + 整个保活链

#### 实操效果

| 场景 | 表现 |
|---|---|
| 手动滑掉 App 卡片 / 系统因内存杀进程 | 系统 SLC 通知到达时自动后台拉起，服务自动恢复 |
| 设备重启 | 重启后首次基站切换（开机搜网注册一般就算一次）时自动后台拉起 |
| App 在后台运行中 | 完全无影响，行为照旧 |
| 用户在设置页**手动关闭 TAS 服务** | 同时注销 SLC，不会再有自动拉起（不违背用户意图） |
| 用户**从主屏上划强杀 App** | iOS 安全策略要求必须手动打开一次 App，SLC 才会恢复自启能力 |

#### 局限（如实说明）

- **不是开机秒起**：需要一次触发事件（基站切换 / 移动）。手机重启后会自动搜网注册基站，这通常就触发一次；**设备完全静止可能延迟数十分钟到几小时**。
- **拉起在后台进行**：进程被拉起时处于后台态，脚本**不会自动启动**（脚本运行需用户主动触发），但 TAS 服务 / 8080 端口 / 保活链全部恢复——这正是挂机脚本最需要的能力。
- **SLC 不暴露为 Lua API**：这是宿主 App 的系统级注册，不对脚本开放任何开关。脚本作者无需关心，行为全自动。

#### 实机验证方法

设备重启 → 不点 App 图标 → 等待几分钟 → 在电脑浏览器访问 `http://手机 IP:8080/`，能打开即说明服务已自动恢复。

同时可在 App 内「查看系统日志」找 `touch.log`，搜下面任一行确认（启动被 SLC 拉起时自动写入）：

```
[App] 由定位事件(SLC)系统后台拉起, 服务自动恢复
[定位保活] startUpdatingLocation 已调用, SLC 重启自启监听已注册
```

如果日志里没有这两行而服务却恢复了，可能是上一次 SLC 注册尚未失效 + 服务原本就在运行；这时日志安静是正常现象，不影响结论。

#### 实现说明（了解即可）

- `TSLocationKeepAlive.start` 在每次服务启动时同时调用 `startUpdatingLocation`（持续定位，主保活通道）+ `startMonitoringSignificantLocationChanges`（SLC，重启自启监听）
- `stop` **刻意不注销 SLC**——`appWillTerminate` / `dealloc` 等终止路径会被调用，如果一并注销 SLC，重启自启会失效
- 单独提供 `stopSystemRelaunchWatch` 方法，专供设置页用户**手动关闭 TAS 服务**时调用，避免违背用户意图的自动拉起
- 真正"开机瞬间自启"需要 `LaunchDaemon`（要求 platform 身份，仅越狱可实现），TrollStore 非越狱下不可能

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

对当前屏幕进行 OCR 识别，查找**指定文字**的位置，返回该文字框的**中心坐标**。适合"检测屏幕上有没有某段文字"（按钮文字、角色名、系统提示等）。

#### 调用形式

```lua
findText(text)                        -- 全屏查找指定文字
findText(text, x1, y1, x2, y2)        -- 区域查找（左上角 + 右下角）
```

#### 参数与返回值

| 项 | 类型 | 说明 |
|---|---|---|
| `text` | string | 要查找的文字，可长可短（如 `"开始游戏"`、`"附近"`） |
| `x1, y1, x2, y2` | number | 可选，查找区域左上角 + 右下角，默认全屏 |
| 返回值 | - | 找到 → `x, y`（文字框中心坐标）；未找到 → `nil` |

#### 示例

```lua
-- 全屏找"开始游戏"并点击
local x, y = findText("开始游戏")
if x then
    tap(x, y)                          -- 中心坐标可直接点击
    logStr(string.format("找到文字 @ (%.0f, %.0f)", x, y))
else
    logStr("未找到: 开始游戏")
end

-- 区域找字（只在屏幕上部找）
local x, y = findText("附近", 0, 0, 1334, 400)
if x then tap(x, y) end

-- 循环等待文字出现（最多等 10 秒）
local ok = false
for i = 1, 20 do
    local fx, fy = findText("加载完成")
    if fx then ok = true; break end
    mSleep(500)
end
if ok then logStr("加载完成!") end
```

> `findText` 底层是 `screen.paddleOcr` 的封装：先做一次全屏/区域 OCR，再逐个匹配 `v.string` 是否包含目标文字。返回的是文字框中心坐标，可直接用于 `tap`。

---

### 3.3 屏幕 OCR（Paddle 风格）`screen.paddleOcr`

对屏幕全屏或指定区域做 OCR，返回**所有**识别到的文本块（文字内容 + 位置 + 置信度）。适合"读取屏幕上全部文字"的场景。底层基于 Apple Vision Framework，与原版 PaddleOCR 行为一致。

#### 调用形式

```lua
screen.paddleOcr()                                  -- 全屏识别
screen.paddleOcr(x1, y1, x2, y2)                    -- 区域识别
screen.paddleOcr(x1, y1, x2, y2, "563A24-303030")   -- 区域识别, 只识别指定颜色的文字
```

> ⚠️ **参数是区域左上角 + 右下角（对角点），不是"宽高"！**
> `screen.paddleOcr(126, 2, 281, 35)` = 区域从 `(126,2)` 到 `(281,35)`，即宽 155、高 33。
> 如果你习惯写 `x, y, w, h`（宽高），请自行换算：`x2 = x1 + w, y2 = y1 + h`。

#### 参数

| 参数 | 类型 | 说明 |
|---|---|---|
| `x1, y1` | number | 可选，区域左上角，默认 `0, 0` |
| `x2, y2` | number | 可选，区域右下角，默认屏幕右下角 |
| `color` | string | 可选（第 5 参），按**字体颜色**过滤后再识别，只输出该色系的文字。省略 = 普通 OCR（全部颜色） |

#### 颜色过滤 `color`（可选）

- 格式与找色一致：`"RRGGBB"` / `"#RRGGBB"` / `"0xRRGGBB"` / `"RRGGBB-偏色"`，偏色为 6 位 hex（每通道独立容差，同 `findColor`）。
- 识别前会把截屏里**不在该颜色±容差范围内**的像素涂白丢弃，只把目标色像素当文字喂给 OCR，因此返回结果里不会混入其它颜色的文字。
- 适合"同屏多色文字只要一种色"的场景（如只认黄色任务文字、红色红点数字），也能顺带滤掉水印/灰色置灰按钮的干扰。

```lua
-- 只识别接近 0x563A24 ± 0x303030（每通道 ±0x30=48）的文字
local result = screen.paddleOcr(0, 0, 540, 300, "563A24-303030")
for _, v in ipairs(result) do
    print(v.string, v.x, v.y)
end
```

#### 返回值

返回**数组**，每个元素是一个包含以下字段的 table：

| 字段 | 类型 | 说明 |
|---|---|---|
| `string` | string | 识别到的文本 |
| `x` | number | 文本框左上角横坐标（脚本坐标系） |
| `y` | number | 文本框左上角纵坐标 |
| `w` | number | 文本框宽度 |
| `h` | number | 文本框高度 |
| `confidence` | number | 置信度 [0,1]，越接近 1 越可信 |

#### 怎么打印结果（重要！用 `print`，不要用 `log`）

```lua
local result = screen.paddleOcr()
print("识别结果数量:", type(result) == "table" and #result or 0)
for i, v in ipairs(result) do
    print(string.format("[%d] %q 框(%.0f,%.0f,%.0f,%.0f) 置信度%.3f",
        i, v.string or "", v.x or 0, v.y or 0, v.w or 0, v.h or 0, v.confidence or 0))
end
```

输出示例（横屏 1334×750 脚本坐标系）：

```
识别结果数量:	32
[1] "coffe的味道" 框(128,8,143,24) 置信度1.000
[2] "敌对" 框(339,10,61,24) 置信度1.000
[3] "比奇" 框(1221,10,52,26) 置信度1.000
[11] "附近" 框(120,89,67,26) 置信度1.000
...
```

> ⚠️ **`log()` 只显示第一个参数**，`log("识别结果", result)` 打印不出 `result` 的内容！
> 必须用 `print(...)`（自动连接所有参数）或手动 `tostring` 拼接。这是排查 OCR"识别不到"时最常踩的坑。

#### 常见用法

**1. 全屏 OCR，找出某个文字并点击**

```lua
local result = screen.paddleOcr()
for _, v in ipairs(result) do
    if v.string == "附近" then
        tap(v.x + v.w / 2, v.y + v.h / 2)   -- 点击文字框中心
        break
    end
end
```

**2. 判断区域里是否含有某文字**

```lua
-- 圈住"附近"按钮区域，检测其中是否出现"附近"
local result = screen.paddleOcr(120, 85, 200, 120)
local found = false
for _, v in ipairs(result) do
    if v.string and string.find(v.string, "附近") then
        found = true
        break
    end
end
print("区域含'附近':", found)
```

**3. 只看高置信度结果（过滤误识别）**

```lua
local result = screen.paddleOcr()
for _, v in ipairs(result) do
    if (v.confidence or 0) >= 0.8 then      -- 只信任高置信度
        print(v.string, v.x, v.y)
    end
end
```

**4. 区域 OCR 读取角色名 / 顶部提示**

```lua
-- 横屏脚本坐标系下，识别屏幕顶部角色名
local result = screen.paddleOcr(126, 2, 281, 35)
if result and #result > 0 then
    print("顶部文字:", result[1].string)
end
```

**5. 全屏识别并用 screenDraw 框选可视化**

```lua
local result = screen.paddleOcr()
local tab = {}
for k, v in pairs(result) do
    local drawView = screenDraw.init(
        math.ceil(v.x), math.ceil(v.y),
        math.ceil(v.w), math.ceil(v.h),
        v.string, 0x00ff00, 1.0, 12, 0x00ff00)
    table.insert(tab, drawView)
    drawView:show()
end
sys.msleep(1000 * 10)
```

> 默认识别语言为简体中文、繁体中文、英文。

#### 横屏脚本（调用 `screen.init` 之后）

调用了 `screen.init(1)`（横屏）后，`paddleOcr` 的**区域参数和返回坐标都自动换算为横屏脚本坐标系**，与 `tap` / `findColor` 完全一致，无需手动换算：

```lua
screen.init(1)              -- 横屏, home 在右 (脚本坐标系)
local result = screen.paddleOcr(126, 2, 281, 35)   -- 传入横屏坐标
for _, v in ipairs(result) do
    print(v.string, v.x, v.y)                      -- 返回也是横屏坐标
end
```

---

### 3.4 屏幕 OCR（多语言）`screen.visionOcr`

与 `screen.paddleOcr` 结构完全一致（返回值、遍历、打印方式相同），区别是支持**自定义识别语言**，可识别英语、法语、中文、日语、韩语、俄语等 13 种语言。

#### 调用形式

```lua
screen.visionOcr()                                -- 全屏, 默认 zh-Hans
screen.visionOcr(x1, y1, x2, y2)                  -- 区域, 默认 zh-Hans
screen.visionOcr("en-US", x1, y1, x2, y2)         -- 指定语言 + 区域
screen.visionOcr("ko-KR")                         -- 指定语言, 全屏
```

#### 参数

| 参数 | 类型 | 说明 |
|---|---|---|
| `lang` | string | 可选，识别语言代码，默认 `zh-Hans` |
| `x1, y1` | number | 可选，区域左上角，默认 `0, 0` |
| `x2, y2` | number | 可选，区域右下角，默认屏幕右下角 |

##### 支持的语言代码

| 代码 | 语言 |
|---|---|
| `en-US` | 美式英语 |
| `fr-FR` | 法语 |
| `it-IT` | 意大利语 |
| `de-DE` | 德语 |
| `es-ES` | 西班牙语 |
| `pt-BR` | 葡萄牙语 |
| `zh-Hans` | 简体中文 |
| `zh-Hant` | 繁体中文 |
| `yue-Hans` | 粤语简体 |
| `yue-Hant` | 粤语繁体 |
| `ko-KR` | 韩语 |
| `ja-JP` | 日语 |
| `ru-RU` | 俄语 |
| `uk-UA` | 乌克兰语 |

> 不同 iOS 版本支持的语言可能不同，未支持的语言会被引擎自动忽略。

#### 返回值

返回数组（结构同 `screen.paddleOcr`）：`{string=, x=, y=, w=, h=, confidence=}`。

#### 示例

```lua
-- 全屏识别（默认中文）
local result = screen.visionOcr()
print("识别结果数量:", type(result) == "table" and #result or 0)

-- 区域识别（中文）
local result = screen.visionOcr(100, 100, 200, 200)
for _, v in ipairs(result) do
    print(v.string, v.x, v.y, v.confidence)
end

-- 区域识别（韩文）
local result = screen.visionOcr("ko-KR", 100, 100, 200, 200)

-- 区域识别（英文）
local result = screen.visionOcr("en-US", 100, 100, 200, 200)
```

> 注：`screen.paddleOcr` 与 `screen.visionOcr` 底层均基于 Apple Vision Framework 的 `VNRecognizeTextRequest`，区别在于 `visionOcr` 支持自定义语言，`paddleOcr` 仅用默认中英文。

---

### 3.5 OCR 排错速查（实战经验）

| 现象 | 原因 | 解决 |
|---|---|---|
| 日志显示"识别结果"后一片空白 | `log()` 只显示第一个参数，`result` 根本没被打印 | 改用 `print(...)` 或 `logStr(tostring(...))` 拼接打印 |
| 区域 OCR 识别不到目标文字 | 区域坐标圈错了位置，或区域太小 | 先跑一次**全屏** `screen.paddleOcr()` 打印所有结果，对照目标文字的实际坐标再圈区域 |
| 区域写 `x, y, w, h` 结果却不对 | 本接口是**对角点**语义 `(x1,y1,x2,y2)` | 换算 `x2=x1+w, y2=y1+h` 后再传入 |
| 横屏游戏坐标错乱 / 找不到 | 没调用 `screen.init(1/2)` | 脚本开头调用 `screen.init(1)`（home 右）或 `screen.init(2)`（home 左） |
| 小字 / 艺术字识别不出 | 文字太小（< 10px 高）、带特效、被阴影干扰 | 圈大一点的区域；用 `findColor`/`findText` 兜底；放宽置信度过滤 |
| 识别出一堆乱码 | 游戏 UI 特效 / 背景干扰 | 过滤 `(v.confidence or 0) >= 0.8`；用 `string.find` 精确匹配目标文字 |
| OCR 耗时 2~4 秒 | Vision 引擎本身耗时（全屏约 4 秒，区域约 2 秒） | 优先用**区域** OCR 缩小范围；检测按钮用 `findColor`/`findText` 更快 |
| 找色能找到但 OCR 认不出 | 找色看颜色、OCR 看字形，两者原理不同 | 按钮检测优先找色；需要"读文字内容"才用 OCR |

---

### 3.6 推荐工作流：先全屏扫描定坐标，再圈区域

新手最容易踩的坑是"凭感觉圈区域"。推荐流程：

1. **先全屏跑一次 OCR**，打印所有文字的真实坐标：
   ```lua
   local result = screen.paddleOcr()
   for i, v in ipairs(result) do
       print(i, v.string, v.x, v.y, v.w, v.h, v.confidence)
   end
   ```
2. 从输出里找到目标文字（如 `"附近" 框(120,89,67,26)`），就知道它在脚本坐标系的位置。
3. 把区域圈在该文字周围（留一点边距），如 `screen.paddleOcr(120, 85, 200, 120)`。
4. 把确认好的区域写进正式脚本。

这样圈出来的区域 100% 对准目标，不会再出现"识别不到"。

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
swipe(x1, y1, x2, y2)                -- 默认 duration=300ms，步数按 60Hz 自动计算
swipe(x1, y1, x2, y2, 500)          -- 耗时 500ms
swipe(160, 300, 160, 100, 500)      -- 向上滑 500ms
swipe(100, 200, 200, 200, 200, 10)  -- 向右滑 200ms，10 步采样
```

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `x1, y1, x2, y2` | number | 必填 | 起点 / 终点 |
| `duration` | number | `300` | 时长（毫秒），与 DSL `swipe`、原版 TouchScript 一致 |
| `steps` | number | `自动` | 采样步数；省略时按 `时长(秒)×60` 自动计算（≈60Hz） |
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

> 提示：`超时秒 > 0` 时，弹窗卡片右上角会实时显示倒计时（如"10秒后自动关闭"、"9秒后自动关闭"…），到点自动关闭。`sys.alert` 带超时时同样显示倒计时。

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

### 7.4 设置悬浮球位置 `sys.setFloatBallPoint`

把悬浮球本体中心移动到指定坐标。坐标使用**脚本坐标系**（与 `screen.init` 设置的方向一致，与 `tap`/`findColor` 等同源）——`init(1)` 横屏后传入的就是横屏坐标，`init(0)` 竖屏就是竖屏坐标。若悬浮球当前未显示，会自动显示后再移动。

```lua
sys.setFloatBallPoint(x, y)
```

#### 参数

| 参数 | 类型 | 说明 |
|---|---|---|
| `x` | number | 脚本坐标系横坐标（与 `screen.init` 方向一致，像素单位） |
| `y` | number | 脚本坐标系纵坐标 |

#### 示例

```lua
-- 竖屏脚本: 移到屏幕左上角附近
screen.init(0)
sys.setFloatBallPoint(100, 100)

-- 横屏脚本: 移到横屏坐标 (100, 100)
screen.init(1)
sys.setFloatBallPoint(100, 100)

-- 移到屏幕中部 (与方向自适应)
local w, h = getScreenSize()
sys.setFloatBallPoint(w / 2, h / 2)
```

> 注：
> - 坐标对应**悬浮球本体的中心点**，不是窗口左上角。
> - 移动后**不会触发贴边动画**，悬浮球会停留在指定位置；若后续用户手动拖拽，松手仍会自动贴边。
> - 坐标系与 `tap(x, y)` / `findColor` 完全一致，无需手动换算。

---

## 7.5 时间戳与内存 `sys.mtime` / `sys.availableMemory` / `sys.processUsedMemory` / `sys.usedMemory`

```lua
sys.mtime()               -- → number  毫秒级时间戳 (UTC, 自 1970-01-01 起的毫秒数)
sys.availableMemory()     -- → number  系统可用物理内存 (字节)
sys.processUsedMemory()   -- → number  当前进程使用的物理内存 (字节, resident_size)
sys.usedMemory()          -- → number  系统已用物理内存 (字节)
```

#### 示例

```lua
-- 计时
local t1 = sys.mtime()
-- ... 执行任务 ...
local t2 = sys.mtime()
print(string.format("耗时: %.0f ms", t2 - t1))

-- 监控内存
print(string.format("可用: %.2f MB, 进程占用: %.2f MB",
    sys.availableMemory() / 1048576,
    sys.processUsedMemory() / 1048576))

-- 内存不足时报警
if sys.availableMemory() < 50 * 1024 * 1024 then
    print("⚠️ 内存不足 50MB")
    device.vibrator()
end
```

#### 实现说明

- `mtime` 用 `NSDate.timeIntervalSince1970 * 1000`，毫秒精度。
- 三个内存函数都基于 `mach` API（`host_statistics` + `task_info`）。
- `availableMemory = (free + inactive + speculative) * pageSize`，这是系统级可回收的内存。
- `processUsedMemory` 用 `task_basic_info.resident_size`，表示本进程实际占用的物理内存。
- `usedMemory = (active + wire) * pageSize`，是系统已committed的内存。

---

## 7.6 App 版本号 `sys.version`

```lua
sys.version()    -- → string  App 版本 (CFBundleShortVersionString)
```

#### 示例

```lua
print("当前 App 版本: " .. sys.version())
```

---

## 7.7 播放音频 `sys.palyAudio`

> 注意函数名拼写为 `palyAudio`（保留原版拼写兼容旧脚本）。

异步播放本地音频文件（不阻塞，可重复调用切换音频）。

```lua
sys.palyAudio(path)    -- path: 音频文件本地路径
```

#### 示例

```lua
-- 播放提示音
sys.palyAudio(file.resDir() .. "/alert.mp3")

-- 任务完成播放铃声
sys.palyAudio("/var/mobile/touch/res/done.wav")
```

#### 实现说明

- 使用 `AVAudioPlayer`，内部用静态变量保持 player 引用，避免被释放导致播放中断。
- 支持 `.mp3` / `.wav` / `.m4a` 等系统原生支持的格式。
- 重复调用会停止上一次播放并切换到新音频。
- 失败时返回 `false`（如文件不存在、格式不支持），并输出日志。

---

## 7.8 VPN 连接检测 `sys.isVPNConnected` / `sys.vpnState`

检测设备当前是否连接了 VPN（WireGuard、IKEv2、小火箭、Surge 等均支持）。**同步立即返回，不联网、不阻塞**。

```lua
sys.isVPNConnected()    -- → boolean  是否连接 VPN
sys.vpnState()          -- → table    检测详情
```

### `vpnState` 返回值

| 字段 | 类型 | 说明 |
|---|---|---|
| `connected` | boolean | 是否连接 VPN |
| `method` | string | 命中的判定层，见下表 |
| `interface` | string | 隧道接口名（如 `utun4`），代理模式为空串 |

| `method` 值 | 含义 |
|---|---|
| `path` | **权威判定**：Network.framework 网络路径中存在承载路由的 `utun` 隧道接口（系统级 VPN 均覆盖） |
| `utun` | 兜底：`getifaddrs` 枚举到带可路由地址的 `utun` 接口（分流 VPN） |
| `proxy` | 兜底：系统全局代理已启用（仅代理模式工具，如 HTTP/SOCKS/PAC 代理） |
| `unknown` | 路径监听尚未上报首帧（仅 App 启动后毫秒级窗口，之后不会再出现） |

### 示例

```lua
-- 开跑前强制检查 VPN
if not sys.isVPNConnected() then
    sys.toast("未连接 VPN，请先开启 VPN 再运行脚本")
    return
end

-- 调试: 查看命中哪一层判定
local st = sys.vpnState()
logStr(string.format("VPN=%s method=%s interface=%s",
    tostring(st.connected), st.method, st.interface))

-- 挂机循环中周期性守护: 断线就报警/停脚本
while true do
    if not sys.isVPNConnected() then
        sys.toast("VPN 已断开！")
        sys.palyAudio(file.resDir() .. "/alert.mp3")
        break
    end
    -- ... 正常挂机逻辑 ...
    mSleep(30000)
end
```

### 实现说明

- **三层判定**：① `NWPathMonitor` 常驻监听系统网络路径（App 启动即开启，VPN 连接/断开由系统主动推送刷新缓存）；② `getifaddrs` 枚举带可路由地址的 `utun` 接口（已排除 169.254 链路本地 / `fe80::` / `::1`，空闲 `utun` 不误报）；③ 系统全局代理（含按接口区分的 `__SCOPED__` 配置）。
- 层①是 Apple 官方网络路径状态，**无需任何 entitlement**，TrollStore 环境完整可用，是免越狱下最可靠的方案；②③仅作补充覆盖。
- `sys.isVPNConnected()` 直接读缓存，脚本内可高频调用，无性能开销。

---

## 7.9 HTTP 模块 `http.get` / `http.post` / `http.download`

替代原 `sys.ftpDownload`（FTP 模块已删除）。走标准 HTTPS/HTTP，基于系统 `NSURLSession`，同步阻塞、UTF-8 解码。

### 7.9.1 `http.get` 发送 GET 请求

```lua
状态码, 返回头, 内容 = http.get(地址, [超时时间], [请求头])
```

| 参数 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `地址` | ✅ | — | 完整 URL（不会自动 URL 编码，需自行处理） |
| `超时时间` | ❌ | 60 | 秒。底层 NSURLSession 超时 |
| `请求头` | ❌ | TAS 默认 UA | Lua 表 `{["User-Agent"]="...", ["Cookie"]="..."}`, 可省 |

**返回值**：

| 字段 | 类型 | 说明 |
|---|---|---|
| `状态码` | integer | HTTP 响应码（如 200、404）；网络错误时为 0 |
| `返回头` | table | 响应头键值表，`{Server="nginx", Content-Type="text/html", ...}` |
| `内容` | string | 响应体 UTF-8 字符串（失败时为错误描述） |

**示例**：

```lua
local code, header, body = http.get("https://www.baidu.com", 30, {
    ["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36"
})
if code == 200 then
    print(header)       -- 打印头部信息
    print(body)         -- 打印网页内容
end
```

### 7.9.2 `http.post` 发送 POST 请求

```lua
状态码, 返回头, 内容 = http.post(地址, [超时时间], [请求头], [请求参数])
```

参数同 `http.get`，最后一个 `请求参数` 是 form-urlencoded 字符串（如 `"username=test&password=123"`）。脚本不需要显式设置 `Content-Type`，实现自动加 `application/x-www-form-urlencoded`。

**示例**：

```lua
local code, header, body = http.post("https://www.baidu.com", 30, {
    ["User-Agent"] = "Mozilla/5.0 ..."
}, "username=1237489&password=237348")
if code == 200 then
    print(body)
end
```

### 7.9.3 `http.download` 下载文件

```lua
下载是否成功, 错误信息 = http.download(地址, 保存路径, [超时时间], [回调函数])
```

**返回值**：

| 字段 | 类型 | 说明 |
|---|---|---|
| `下载是否成功` | boolean | 成功返回 `true`；网络错误、写文件失败、超时、URL 无效等均返回 `false` |
| `错误信息` | string | 成功时为空串 `""`；失败时为人类可读的简述（同时 `NSLog` 完整 NSError，便于查看 `[http.download]` 日志） |

| 参数 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `地址` | ✅ | — | 文件 URL |
| `保存路径` | ✅ | — | 本地绝对路径，父目录不存在会自动创建 |
| `超时时间` | ❌ | 60 | 秒 |
| `回调函数` | ❌ | nil | `function(totalLength, currentLength, downloadSpeed) end`，约每 200 ms 触发一次 |

**回调三参均为整数，单位字节**。`downloadSpeed` 是本次回调相对上次的瞬时速率，可直接用于"下载进度条"展示。

**示例**：

```lua
-- 下载视频到相册
local savePath = "/var/mobile/Media/svip/res/55.mp4"
local status = http.download("http://tk.taobao6.vip/EC/video/5.mp4", savePath, 10,
        function(totalLength, currentLength, downloadSpeed)
            print(string.format("文件总大小:%.2fMB 当前已完成:%.2fMB 当前下载速度:%.2fMB/s",
                totalLength/1024/1024, currentLength/1024/1024, downloadSpeed/1024/1024))
        end)
if status then
    local s, e = mobile.saveVideoFileToAlbum(savePath)
    print(s and "保存到相册成功" or "保存到相册失败 error: " .. tostring(e))
end
```

### 实现说明

- **同步阻塞**：`http.get`/`http.post`/`http.download` 都是同步调用，脚本会在该行等待网络完成；100 MB 文件在普通带宽下约几秒到十几秒，挂机脚本一般可接受。
- **进度回调安全**：下载的进度触发与下载任务是分开的。下载在后台 `NSURLSession` 委托线程上推进，已下载字节原子累加；进度回调在 **Lua 调用线程**（200 ms 周期的 `NSTimer`）上触发，**不会跨线程访问 lua_State**。
- **不支持重定向自动跳转**：调用方需自己处理 3xx；若需跟随重定向，请告知，可以扩展。
- **HTTPS / TLS**：走系统证书链，自签名证书需客户端单独信任。
- **Body 编码**：响应体按 UTF-8 解码，失败回退 ISO-8859-1；服务端 GBK 编码的中文响应会乱码（目前未实现按 `Content-Type` charset 切换）。
- **请求体仅 form-urlencoded**：未实现 multipart/form-data、JSON 等 content type 直传；如需 JSON，自己 base64 或原始字符串放在 `请求参数` 字段，并在 `请求头` 中显式覆盖 `Content-Type`。

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

## 8.3 设备唯一标识 `device.udid` / `device.serialNumber`

获取设备 UDID 和序列号。**仅 TrollStore 安装的 App 可用**（依赖 MobileGestalt 私有 API 和 `com.apple.private.MobileGestalt.AllowedProtectedKeys` 权限）；沙盒 App Store 安装会返回 `nil`。

```lua
device.udid()              -- → string / nil
device.serialNumber()      -- → string / nil
```

#### 返回值

| 函数 | 类型 | 说明 |
|---|---|---|
| `device.udid()` | string / nil | 设备 UDID（如 `00008101-001A1B2C3D4E`） |
| `device.serialNumber()` | string / nil | 设备序列号 |

#### 示例

```lua
local udid = device.udid()
if udid then
    print(string.format("当前设备的 UDID: %s", udid))
else
    print("无法获取 UDID（沙盒环境或权限不足）")
end

local sn = device.serialNumber()
if sn then
    print(string.format("当前设备的序列号: %s", sn))
end
```

> 实现说明：通过 `dlopen` 动态加载 `MobileGestalt.framework`，调用 `MGCopyAnswer(@"UniqueDeviceID")` / `MGCopyAnswer(@"SerialNumber")` 读取。本 App 的 entitlements 已声明 `com.apple.private.MobileGestalt.AllowedProtectedKeys=true`，TrollStore 重签后即可访问。

---

## 8.4 辅助触控开关 `device.turnOnAssistiveTouch` / `device.turnOffAssistiveTouch`

启用或停用 iOS 的辅助触控（小白点）。**仅 TrollStore 安装的 App 可用**（需 `com.apple.assistivetouch.daemon` 权限，已在 entitlements 中声明）。

```lua
device.turnOnAssistiveTouch()    -- 启用辅助触控 → boolean
device.turnOffAssistiveTouch()   -- 停用辅助触控 → boolean
```

#### 返回值

| 函数 | 类型 | 说明 |
|---|---|---|
| `device.turnOnAssistiveTouch()` | boolean | `true` = 成功修改 plist + 已发送通知 |
| `device.turnOffAssistiveTouch()` | boolean | 同上 |

#### 示例

```lua
-- 启用辅助触控
if device.turnOnAssistiveTouch() then
    print("辅助触控已启用")
else
    print("启用失败 (权限不足或存储问题)")
end

-- 停用辅助触控
device.turnOffAssistiveTouch()   -- 停用屏幕上的小白点
```

#### 实现说明

本实现完全复刻 TrollAutoScript 2.3.6 的逆向方案，采用**多通道并行写入**策略确保生效：

1. **dlopen Accessibility 框架**（位于 `/System/Library/PrivateFrameworks/Accessibility.framework`），加载 `AXAccessibilityPreferences` 类与 `AXSSetAssistiveTouchEnabled` C 符号
2. **优先 ObjC runtime** 调用 `[AXAccessibilityPreferences setAssistiveTouchEnabled:]`（平滑生效，不杀进程）
3. **C 符号兜底**：`dlsym(RTLD_DEFAULT, "AXSSetAssistiveTouchEnabled")` 直接调用
4. **CFPreferences 写入**（主手段）：用 `CFPreferencesSetValue` 写 `AXAssistiveTouchEnabled` 与 `AssistiveTouchEnabled` 两个 key 到 `com.apple.Accessibility`，立即更新 cfprefsd 内存缓存
5. **磁盘 plist 后备**：同时写 `/var/mobile/Library/Preferences/com.apple.Accessibility.plist`
6. **Darwin 通知**：`notify_post("com.apple.accessibility.cache.axsettings")` 和 `notify_post("com.apple.accessibility.cache")`（双重通知名）
7. **按需杀 assistivetouchd**：仅当 `assistivetouchd` 进程存活时才 `SIGKILL`，强制其重启后从 cfprefsd 重新读取已写入的值（**绝不杀 cfprefsd**，会影响系统其他功能）

> **重要**：
> - entitlements 已声明 `com.apple.security.exception.shared-preference.read-write` 包含 `com.apple.Accessibility`，是 CFPreferencesSetValue 生效的前提
> - 此前老版本实现未生效的原因：用的 key 名是 `AssistiveTouchAssistiveTouchEnabledByiTunes`（错误），正确 key 是 `AXAssistiveTouchEnabled`
> - 老版本用的通知名 `com.apple.accessibility.assistiveTouch.changed` 也是错的，正确通知名是 `com.apple.accessibility.cache.axsettings` 和 `com.apple.accessibility.cache`
> - 关闭小圆点不会"闪烁"：仅当 assistivetouchd 进程存活时才杀，硬件未重开时进程不存活，不会重复杀
> - 此函数会**异步执行**（Lua 调用后立即返回，CFPreferencesSetValue 是同步但 dlopen 框架约 50ms）

---

## 8.5 屏幕锁定查询与解锁 `device.isScreenLocked` / `device.unlockScreen`

查询屏幕是否锁定，以及在无密码设备上唤醒并解锁屏幕。挂机脚本通常搭配使用：检测到锁屏就调用解锁。

```lua
device.isScreenLocked()    -- → boolean
device.unlockScreen()      -- → boolean
```

#### 返回值

| 函数 | 类型 | 说明 |
|---|---|---|
| `device.isScreenLocked()` | boolean | `true` = 屏幕锁定中 |
| `device.unlockScreen()` | boolean | `true` = 复查确认已解锁；`false` = 1.5 秒后仍锁定(解锁失败) |

#### 示例

```lua
-- 检测锁屏并解锁
if device.isScreenLocked() then
    print("屏幕锁定中, 尝试解锁...")
    device.unlockScreen()
    sys.msleep(1000)   -- 等待系统响应
    if device.isScreenLocked() then
        print("解锁失败 (可能有密码?)")
    else
        print("已解锁")
    end
else
    print("屏幕未锁定")
end

-- 挂机脚本定期检查
while true do
    if device.isScreenLocked() then
        device.unlockScreen()
        sys.msleep(2000)
    end
    -- ... 挂机逻辑
    sys.msleep(5000)
end
```

#### 实现说明

- **`isScreenLocked`**：通过 Darwin 通知 `com.apple.springboard.lockstate` 的 `notify_get_state` 查询，SpringBoard 维护此状态值（1=锁定，0=解锁）。
- **`unlockScreen`**（2026-10 按原版 TrollAutoScript 2.3.6 引擎重写，逆向依据见下）：
  1. 先用 SpringBoardServices 的 `SBGetScreenLockStatus(port, &locked, &passcode)` 问一次：拿到"是否锁定"**和**"是否设了密码"
  2. 设了密码 → 直接记日志返回 `false`（第三方 App 不可能代输密码）
  3. 主通路：**HID 连按 3 次 Home**（`IOHIDEventCreateKeyboardEvent(page 0x0C, usage 0x40)` + `IOHIDEventSystemClientDispatchEvent`，
     与触摸注入同一个 client/senderID）。每按一次就复查一次，解锁立即返回 `true`
  4. 三次都没解开 → 兜底：点亮背光 + 老 `GSEvent` Home 键，再复查约 1.6 秒
  5. 全程失败 → 记日志并返回 `false`

> **逆向依据（原版 2.3.6 的 `bin/luaLib`）**：原版 `device.unlockScreen` 是**纯 Lua**写的，源码就嵌在引擎里：
> ```lua
> device.unlockScreen = function ()
>     local isLockStatus, isPasscodeEnabled = device.isScreenLocked()
>     if isPasscodeEnabled then assert(isPasscodeEnabled, "有密码, 无法解锁") return end
>     if (isLockStatus) then
>         key.press("HOMEBUTTON"); key.press("HOMEBUTTON"); key.press("HOMEBUTTON")
>     end
> end
> ```
> 而 `key.press` 走的是 `IOHIDEventCreateKeyboardEvent` + `IOHIDEventSystemClientDispatchEvent`
> （luaLib 导入表里可以查到这两个符号），**不是** `GSEventPost` —— 这就是旧实现"只发 GSEvent、完全没反应"的原因。

> **关于密码**：
> - 设备**没有设置锁屏密码**时，`unlockScreen` 可直接解锁到桌面。
> - 设备**设置了密码**时，直接返回 `false` 并记 `[Device] ⚠ 解锁失败: 设备已设置锁屏密码...`，需要用户在挂机前关闭密码。
> - 返回值是**实际复查结果**（旧版恒返回 `true`，脚本无法区分"解锁成功"和"什么都没发生"）。
> - 失败时 `touch.log` 会记 `[Device] ⚠ 解锁失败: ...`，并带上 `HID按键已下发/通道不可用` 和 `密码=有/无/未知`：
>   - `HID按键=通道不可用` → 说明 HID client 没建起来（和触摸注入同源，看 `touch.status()`）；
>   - `HID按键=已下发` 但仍锁定 → 事件被系统丢弃，或 Home 用法值不适用于该机型，按日志继续排查。
> - 万一该机型按 Home 就是解不开，规避办法：设置 → 显示与亮度 → 自动锁定 → **永不**，挂机时根本不会锁屏。

---

## 8.6 设备基础信息 `device.name` / `device.type`

查询设备名称与类型。

```lua
device.name()    -- → string  设备名
device.type()    -- → string  iPhone / iPad / TV / CarPlay / Mac / Unspecified
```

#### 示例

```lua
print("设备名: " .. device.name())
print("设备类型: " .. device.type())
```

---

## 8.7 屏幕亮度控制 `device.backlightLevel` / `device.setBacklightLevel`

读取或设置屏幕亮度（基于 `UIScreen.mainScreen.brightness`，公开 API）。

```lua
device.backlightLevel()        -- → number  [0, 1] 当前亮度
device.setBacklightLevel(n)    -- n ∈ [0, 1]
```

#### 示例

```lua
-- 调暗屏幕省电
device.setBacklightLevel(0.3)

-- 检测低亮度环境再调亮
if device.backlightLevel() < 0.5 then
    device.setBacklightLevel(1.0)
end
```

---

## 8.8 锁屏与震动 `device.lockScreen` / `device.vibrator`

```lua
device.lockScreen()    -- 锁定屏幕 (等同电源键)
device.vibrator()      -- 系统震动反馈
```

`lockScreen` 复用 `TSKeyboardInjector.pressLock`（优先 `GSEventLockDevice`，备选发送 lock 按键事件）。

#### 示例

```lua
-- 执行完任务后锁屏
device.lockScreen()

-- 任务完成震动提示
device.vibrator()
```

---

## 8.9 系统音量 `device.setVolume`

设置系统音量（通过 `MPVolumeView` 滑块 hack 实现，公开 API 范围内）。

```lua
device.setVolume(n)    -- n ∈ [0, 1]
```

#### 实现说明

- iOS 11+ 苹果禁止纯代码直接修改系统音量，函数会在屏幕外创建一个临时 `MPVolumeView`，找到其内部的 `UISlider` 子视图并设置 value，触发系统音量更新，然后移除视图。
- 函数**异步执行**（派发主线程），调用后 200ms 内生效。

#### 示例

```lua
device.setVolume(0.5)   -- 设置音量为 50%
device.setVolume(0.0)   -- 静音
device.setVolume(1.0)   -- 最大音量
```

---

## 9. 应用管理

```lua
-- 前台应用 Bundle ID
local bid = app.frontBid()
logStr("当前前台: " .. bid)

-- 停在桌面时 bid = "com.apple.springboard", 可直接比较
local APP = "com.xxx.game"
if bid ~= APP then
    app.open(APP)
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
| `app.frontBid()` | string | 当前前台 App bundle id（停在桌面时返回 `com.apple.springboard`，恒有值） |
| `app.isInstalled(bid)` | boolean | 是否安装 |
| `app.isRunning(bid)` | boolean | 是否正在运行(排查 close 无效的第一步) |
| `app.open(bid)` | boolean | 打开 App |
| `app.close(bid)` | boolean | 关闭 App |
| `app.inputText(text)` | boolean | 输入文本 |

> `app.frontBid()` **恒返回字符串, 不会是 nil**, 脚本里可以直接 `if bid ~= APP then`, 不必先判空。
> 引擎依次尝试三条通路: ① FrontBoard 主屏显示布局(主通路 —— 由系统显示服务维护, 本 App 退到后台
> 也读得到前台 App; 悬浮球"后台读前台 App 方向"用的就是它); ② SpringBoardServices 前台查询
> (iOS 15 TrollStore 环境下常被拒, 恒返回 NULL); ③ 本 App 自己就在前台时返回自身 bundle id。
>
> 三条全失败时按**停在桌面**处理, 返回 `com.apple.springboard`(桌面的前台本来就是 SpringBoard),
> 同时脚本日志(debug.log)只记一次 `⚠ app.frontBid() 取不到前台应用, 已按桌面返回 com.apple.springboard (...)`,
> 括号内是各通路逐一失败的原因, 便于定位。即返回值不再区分"桌面"和"取不到",
> 需要区分时看日志或用 `app.isRunning(bid)` 自行判断。

> `app.close(bid)` 传的是 **bundle id**(如 `com.tencent.xin`),不是 App 显示名。
> 关闭失败时 `touch.log` 会写明原因: `未找到运行进程`(= 没在运行或 bundle id 不对)
> 或 `kill 返回 Operation not permitted`(= 本 App 无权给其他进程发信号)。

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

### 11.5 追加文本 `file.addText`

追加文本到文件末尾（文件不存在则创建）。

```lua
file.addText(path, text)    -- → boolean
```

```lua
-- 日志追加
file.addText(file.logDir() .. "/run.log",
             os.date("[%Y-%m-%d %H:%M:%S] 任务完成\n"))
```

### 11.6 文件大小 `file.size`

```lua
file.size(path)    -- → number  字节数, 不存在返回 -1
```

```lua
local sz = file.size("/var/mobile/touch/res/big.png")
print(string.format("文件大小: %.2f KB", sz / 1024))
```

### 11.7 目录列表 `file.list`

列出目录下所有条目（不含路径，不递归）。

```lua
file.list(dirPath)    -- → table {name1, name2, ...} / nil
```

```lua
local files = file.list(file.luaDir())
for i, name in ipairs(files) do
    print(i, name)
end
```

### 11.8 文件 MD5 `file.md5`

```lua
file.md5(path)    -- → string  32 位十六进制小写 / nil
```

```lua
-- 校验文件完整性
local h1 = file.md5(file.resDir() .. "/template.png")
print("MD5: " .. h1)
```

### 11.9 行操作 `file.getLines` / `file.lineCount` / `file.getLineText` / `file.resetLineText` / `file.insertLineText`

按行读写文件（1-based 索引）。

```lua
file.getLines(path)               -- → table {line1, line2, ...} / nil
file.lineCount(path)              -- → number  总行数 (-1 表示失败)
file.getLineText(path, n)        -- → string  第 n 行 / nil
file.resetLineText(path, n, text) -- → boolean  替换第 n 行
file.insertLineText(path, n, text) -- → boolean 在第 n 行前插入
```

```lua
local path = file.scriptDir() .. "/config.txt"

-- 读取所有行
local lines = file.getLines(path)
print("共 " .. #lines .. " 行")

-- 读取第 3 行
local line3 = file.getLineText(path, 3)
print("第 3 行: " .. line3)

-- 替换第 2 行
file.resetLineText(path, 2, "新内容")

-- 在第 1 行前插入
file.insertLineText(path, 1, "插入的首行")

-- 追加到末尾 (n 超过总行数即追加)
file.insertLineText(path, 999, "末尾追加")
```

#### 实现说明

- 行分隔符统一为 `\n`，写入时也会用 `\n` 重新拼接。
- `resetLineText` 当 `n > lineCount` 时不操作返回 `false`。
- `insertLineText` 当 `n > lineCount` 时自动追加到末尾。
- 大文件场景下效率不高（每次都全量读+写），适合配置文件、日志索引等小文件。

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

## 14.5 浮动日志窗口 (logWindow)

在屏幕上开一块**肉眼可见的日志面板**，用来实时看脚本状态。可以对颜色、字体、位置、透明度做配置。

```lua
logWindow.setHideWindowMode(true)          -- 隐藏模式: 面板肉眼可见, 但不会被截进画面

local w, h = getScreenSize()
local offset = 200
local lw = logWindow.init(0, offset, w, h - offset * 2, 0.5, 0x000000, 0x00ff00, 15)

lw:addLog(os.date("[%H:%M:%S] : ") .. "第一条日志")   -- 用默认颜色/尺寸
lw:addLog(os.date("[%H:%M:%S] : ") .. "红色日志", 0xff0000)
lw:addLog("大号字", 0xffff00, 20)

sleep(10000)
lw:release()      -- 释放掉
```

| 函数 | 说明 |
|---|---|
| `logWindow.init(x, y [, 宽, 高, 背景透明度, 背景色, 字体色, 字体尺寸, 单行模式])` | 创建并立即显示一个日志窗口 → 返回**日志窗口对象**（失败返回 `nil`） |
| `日志窗口对象:addLog(文本 [, 文字颜色, 文字尺寸])` | 追加一行日志 |
| `日志窗口对象:release()` | 释放（销毁）这个窗口 |
| `logWindow.setHideWindowMode(true\|false)` | 隐藏模式开关，见下 |
| `logWindow.releaseAll()` | 一次关闭所有日志窗口 |

参数默认值：宽 `500`、高 `35`、背景透明度 `0.5`、背景色 `0x000000`、字体色 `0x00ff00`、字体尺寸 `12`、单行模式 `false`。
颜色一律是 `0xRRGGBB` 整数。

#### 单行模式（第 9 个参数传 `true`）

多行模式（默认）下 `addLog` 会不断**追加**新行并滚动到最新；单行模式下每次 `addLog` **只显示最新一条**文字，
之前的内容被整体替换，不滚动 —— 适合做"状态栏"式的单行提示（如当前任务进度）：

```lua
-- 第 9 个参数 true = 单行模式: 每次 addLog 只显示最新一条
local lw = logWindow.init(100, 100, 500, 35, 0.5, 0x000000, 0x00ff00, 15, true)
lw:addLog("当前任务: 捕捉")     -- 屏幕上只看到这一行
sleep(2000)
lw:addLog("当前任务: 打怪")     -- 上一条被替换, 仍然只有这一行
```

**坐标系（重要）**：第 3、4 个参数是**宽、高**（不是右下角 x2,y2）；x,y,w,h 全部是**脚本坐标系物理像素**，
与 `tap` / `findColor` / `getScreenSize()` 完全同源，并**随 `screen.init(方向)` 自动旋转** ——
`screen.init(1)` 横屏脚本里传入的就是横屏坐标，面板位置与文字方向都跟游戏一致。

```lua
local w, h = getScreenSize()          -- 脚本坐标系下的屏幕像素尺寸
local lw = logWindow.init(0, 0, w, 120, 0.5, 0x000000, 0x00ff00, 14)
```

面板被排到屏幕外会**看不见**：此时 `debug.log` 会记一行
`⚠ logWindow.init 坐标超出屏幕: 传入 (...), 屏幕(脚本坐标系) WxH → 已夹回 (...)`，并自动夹回屏幕内。

#### 隐藏模式 `setHideWindowMode`

- `true`（推荐）：**面板肉眼看得见，但脚本看不见** —— 每次截屏时面板会被临时摘除并提交，
  所以 `findColor` / `findImage` / `getColor` / `snapshot` 拿到的画面里**没有**这块面板，不会砸坏找图找色。
- `false`（默认）：面板会被一起截进画面 —— 如果你要"对着日志窗口自己找色/找图"，就用这个。

#### 实现说明

- 所有日志窗口挂在**同一个**全屏透明 `UIWindow` 上（`UIWindowLevelStatusBar+100`），窗口 `hitTest` 恒返回 `nil`、
  `userInteractionEnabled=NO`，**完全不参与触摸**，不会吞脚本的点击。
- App 退到后台（脚本在别的 App 上跑）时，走与悬浮球同样的 **SBS 系统级托管**
  （`SBSAccessibilityWindowHostingController` + `CAContext`，level 10000、`kCAContextIgnoresHitTest`），
  保证在其它 App / 桌面上依旧肉眼可见。
- 脚本结束（正常结束 / 停止 / 报错）会自动 `releaseAll()`，脚本忘了 `:release()` 也不会留残影。
- 面板内部最多保留最近 400 行，长时间挂机不会把内存吃光。

---

## 14.6 重启脚本 (restartScript)

```lua
restartScript()   -- 脚本将会重新启动, 后面的代码将不会执行
```

- 重新启动**当前正在运行的脚本**：调用后当前执行立即中止（后面的代码不会执行），
  脚本从头重新运行一遍 —— 适合"异常兜底自恢复"（如检测到卡死/掉线后 `restartScript()` 重置全部状态）。
- 重启目标自动识别，**全场景支持**：
  - 单文件 `.lua` → 重新从磁盘读取该文件运行（重启即拿到最新代码）；
  - 普通项目（文件夹）→ 重新扫描入口文件（`main.lua` 优先）运行；
  - 整包加密项目 `.tas` → 重新解密原包运行；
  - 网页远程下发的字符串代码 → 用代码副本原样重跑。
- 注意事项：
  - 重启前请把需要的持久数据先写入磁盘（`file.addText` 等），**全局变量/局部状态会全部丢失**；
  - 与"停止"一样会补发未抬起的触摸、清理日志窗口，不会留"幽灵手指"；
  - 用户按音量键/悬浮球"停止"优先于重启请求（先停就不再重启）；
  - 脚本一进循环就立刻 `restartScript()` 会造成无限重启，请自行避免。

---

## 14.7 脚本设置 UI 完整指南（HTML 网页 + UIKit 原生 共存）

TrollAutoTouch 提供**两套**并存的设置 UI，**脚本作者可显式选择**用哪一套。两套 UI 共用**同一份** settings.json（`/var/mobile/touch/lua/<脚本名>.settings.json`）和**同一个**全局 `settings` 表，行为完全一致。

### 14.7.1 两套 UI 对比

| 维度 | HTML 网页 UI（`index.html`） | UIKit 原生 UI（`schema.lua`） |
|---|---|---|
| 文件路径 | `/var/mobile/touch/lua/ui/<name>/index.html` | `/var/mobile/touch/lua/ui/<name>/schema.lua` |
| 渲染方式 | `WKWebView` + `http://127.0.0.1` 内嵌 HTTP 服务 | `UITableView` + 各 UIKit 控件（UISwitch / 复选框 / UISlider / UIDatePicker / UIColorWell …） |
| **后台渲染** | ❌ App 在后台时 WKWebView 内容无法提交到系统层 → 设置页空白 | ✅ 纯 UIKit 视图，可在游戏等任意前台 App 之上**直接显示**，无需切回本 App |
| 布局自由度 | 完全自由（HTML/CSS/JS） | 受限（受 UIKit 控件形状约束），但风格统一、Apple HIG |
| 上手成本 | 写 HTML/JS | 写一个 Lua 表声明 |
| 扩展能力 | 强（canvas/视频/任意 JS） | 中（受 iOS 控件库限制） |
| 数据保存 | 网页 `ts.save(obj)` 写 settings.json | 自动收集 `currentValue` 写 settings.json |
| 适用场景 | 需要自定义图表/视频/复杂排版 | 普通设置项（开关/数值/选择/颜色/时间） |
| 选择建议 | 复杂 UI、富媒体 | 简单设置、需要在游戏运行时弹出 |

### 14.7.2 入口 API

```lua
-- 自动检测（推荐，0 改动）：优先 schema.lua，缺则回退 index.html
local ran = ui.open("myScript")
if ran then
    -- 用户点了"开始运行"，settings 表已注入，可读 settings.xxx
end

-- 显式指定
ui.open("myScript", "html")     -- 强制使用 HTML
ui.open("myScript", "native")   -- 强制使用 UIKit 原生
ui.open("myScript", "auto")     -- 自动检测（默认行为）

-- 动态 schema（不写文件，直接传 Lua 表）
ui.openForm("myScript", {
    title = "我的脚本设置",
    sections = {
        {title = "基础", rows = {
            {type="switch", key="autoStart", label="自动启动", default=true},
            {type="slider",  key="speed",     label="速度", min=0.5, max=2.0, step=0.1, default=1.0, format="%.1fx"},
        }},
    },
})
```

返回值同 `ui.open`：true = 用户点了"保存运行"，已注入 settings；false = 取消/失败。

### 14.7.3 HTML 网页设置 UI 完整使用方法

#### 初始化

把 `index.html` 放到 `ui/<脚本名>/` 目录（脚本名就是 `ui.open` 的第一个参数去掉 `.lua` 扩展名）。引擎通过内嵌 HTTP 服务（`http://127.0.0.1:<port>/ui/<脚本名>/index.html`）加载它。

```
/var/mobile/touch/lua/
├── myScript.lua
├── myScript.settings.json   ← 自动维护, 不要手改
└── ui/
    └── myScript/
        ├── index.html       ← 网页设置 UI
        ├── style.css
        └── app.js
```

#### 网页端 JavaScript 桥

| API | 调用方式 | 说明 |
|---|---|---|
| `ts.save(obj)` | `ts.save({key1: value1, key2: value2})` | 保存配置到 settings.json，触发关闭并启动脚本 |
| `ts.cancel()` | `ts.cancel()` | 取消配置，关闭设置页，不启动脚本 |
| `ts.get(key)` | `ts.get("keyName")` | 读当前已保存的值（页面加载时建议用） |
| `fetch('/api/ui/settings/<脚本名>')` | GET | 读整个配置表（JSON） |
| `fetch('/api/ui/settings/<脚本名>', {method:'PUT', body: JSON.stringify(obj)})` | PUT | 写整个配置表 |

#### 完整 HTML 示例

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>我的脚本设置</title>
    <style>
        body { font-family: -apple-system, sans-serif; padding: 20px; background: #f5f5f7; }
        .field { background: white; padding: 14px; margin-bottom: 8px; border-radius: 10px; }
        .field label { display: block; font-size: 14px; color: #333; margin-bottom: 6px; }
        .field input, .field select { width: 100%; padding: 8px; font-size: 15px; border: 1px solid #ddd; border-radius: 6px; box-sizing: border-box; }
        .buttons { display: flex; gap: 12px; margin-top: 24px; }
        .btn { flex: 1; padding: 14px; font-size: 16px; border: none; border-radius: 10px; }
        .btn-primary { background: #007aff; color: white; }
        .btn-secondary { background: #e5e5ea; color: #333; }
    </style>
</head>
<body>
    <h2>我的脚本设置</h2>
    <div class="field">
        <label>账号</label>
        <input type="text" id="username" placeholder="请输入账号">
    </div>
    <div class="field">
        <label>密码</label>
        <input type="password" id="password">
    </div>
    <div class="field">
        <label>模式</label>
        <select id="mode">
            <option value="fast">快速</option>
            <option value="safe">安全</option>
        </select>
    </div>
    <div class="field">
        <label>启用自动战斗</label>
        <input type="checkbox" id="autoBattle">
    </div>
    <div class="buttons">
        <button class="btn btn-secondary" onclick="onCancel()">取消</button>
        <button class="btn btn-secondary" onclick="onSave()">保存</button>
        <button class="btn btn-primary" onclick="onSaveAndRun()">保存并运行</button>
    </div>
    <script>
        // 页面加载时填充已保存的值
        fetch('/api/ui/settings/myScript').then(r => r.json()).then(s => {
            if (s.username) document.getElementById('username').value = s.username;
            if (s.password) document.getElementById('password').value = s.password;
            if (s.mode) document.getElementById('mode').value = s.mode;
            if (s.autoBattle) document.getElementById('autoBattle').checked = true;
        });

        function getConfig() {
            return {
                username: document.getElementById('username').value,
                password: document.getElementById('password').value,
                mode: document.getElementById('mode').value,
                autoBattle: document.getElementById('autoBattle').checked,
            };
        }
        function onSave()        { ts.save(getConfig()); }
        function onSaveAndRun()  { ts.save(getConfig()); }
        function onCancel()      { ts.cancel(); }
    </script>
</body>
</html>
```

#### 常见注意事项

1. **保存的设置是字典**：写 `ts.save({a=1, b="x"})` 后，脚本里 `settings.a == 1`，`settings.b == "x"`。所有键会被序列化为 JSON。
2. **TSAPI 接口走 HTTP**：网页与原生通过 `http://127.0.0.1:<port>/api/ui/...` 通信，App 已在 Info.plist 配置 `NSAllowsLocalNetworking=true` 允许本地网络请求。
3. **后台弹出行为**：当 App 在后台（游戏在前台）时，弹窗策略按路径不同：
   - `ui.open(name, "html")` 或 auto 解析到 html：先把 TrollAutoTouch 切回前台（1 秒）让 WKWebView 恢复渲染，关闭后自动切回游戏
   - `ui.open(name, "native")` / `ui.openForm(name, schema)`：**直接走 SBS 系统级层承载**（HUD 模式），不切到 TrollAutoTouch 前台，不打断游戏。HUD 承载失败（SBS 未托管）才回退到切前台
4. **取消 vs 保存**：点网页底部"取消"→ `ts.cancel()` → 引擎收到通知后调用 `[[TSLuaBridge shared] stop]` 停止当前脚本、关闭设置页。点"保存"或"保存并运行"→ `ts.save()` → 写 settings.json、关闭设置页、是否启动脚本由 `ui.open` 的返回值决定。
5. **停止快捷键**：用户随时可以按音量键 / 悬浮球"停止"按钮强制中断设置页（与 HTML 路径同样支持），脚本会收到 `false` 返回值并按默认配置继续。

### 14.7.4 UIKit 原生设置 UI 完整使用方法

#### 初始化（文件方式）

把 `schema.lua` 放到 `ui/<脚本名>/` 目录，返回一个 Lua 表描述表单结构：

```lua
-- /var/mobile/touch/lua/ui/myScript/schema.lua
return {
    title = "我的脚本设置",   -- 可选, 默认用脚本名
    sections = {
        {
            title = "基础",
            footer = "通用设置, 修改后点保存",
            rows = {
                -- 行类型见下表
                {type="switch",   key="autoStart",  label="自动启动",     default=true},
                {type="checkbox", key="pickUp",     label="自动拾取",     default=true},
                {type="checkGroup", key="dungeons", label="要刷的副本",   columns=3,
                 options={"水陆大会","车迟斗法","通天河","乌鸡国","秘境降妖","金兜洞"},
                 default={"水陆大会","乌鸡国"}},
                {type="slider",   key="speed",      label="运行速度",     min=0.5, max=2.0, step=0.1, default=1.0, format="%.1fx", showValue=true},
                {type="stepper",  key="retry",      label="失败重试",     min=0, max=10, default=3},
                {type="segmented",key="mode",       label="模式",         options={"快速","安全","自定义"}, default="快速"},
                {type="select",   key="role",       label="角色",         options={"战士","法师","道士"}, default="战士"},
                {type="text",     key="webhook",    label="通知地址",     placeholder="https://...", keyboard="url"},
                {type="textLong", key="notes",      label="备注",         default=""},
                {type="number",   key="coordX",     label="X 坐标",       min=0, max=4096, default=0, step=1},
                {type="date",     key="scheduleAt", label="定时启动",     mode="datetime"},
                {type="duration", key="cooldown",   label="冷却时间",     min=60, max=3600, default=300, unit="秒"},
                {type="color",    key="targetColor",label="目标颜色",     default="#FF0000"},
                {type="multi",    key="targets",    label="目标列表",     options={"史莱姆","哥布林","狼"}, default={"史莱姆"}},
                {type="action",   key="testColor",  label="测试找色",     onTap=function(s) logStr("测试结果: "..tostring(s.speed)) end},
                {type="info",     text="提示: 启动后可在悬浮球暂停/恢复"},
            },
        },
    },
}
```

#### 行类型 (type) 完整列表

| type | 必填 | 常用可选字段 | 控件 / 写入值类型 |
|---|---|---|---|
| `switch` | key, label | default | `UISwitch` → bool |
| `checkbox` | key, label | default | 单行复选框（右侧色块，选中蓝，点整行切换）→ bool |
| `checkGroup` | key, label, options | default (array), columns (默认 3) | 一行 N 个色块按钮，点名字变色 → array of string |
| `stepper` | key, label, min, max | default, step | `UIStepper` → number |
| `slider` | key, label, min, max | default, step, format, showValue | `UISlider` → number |
| `segmented` | key, label, options | default | `UISegmentedControl` → string |
| `select` | key, label, options | default | 点击进入子表 → string |
| `text` | key, label | default, placeholder, keyboard | `UITextField` → string |
| `textLong` | key, label | default, placeholder | `UITextView` → string |
| `number` | key, label, min, max | default, step, keyboard | `UITextField`+数字键盘 → number |
| `date` | key, label | default (Unix秒), mode (`date`/`time`/`datetime`) | `UIDatePicker` → number(秒) |
| `duration` | key, label | default (秒), min, max, unit | `UIDatePicker.countDownTimer` → number(秒) |
| `color` | key, label | default (#RRGGBB) | `UIColorWell` (iOS 14+) → string |
| `multi` | key, label, options | default (array) | 点击进入子表 → array of string |
| `action` | key, label | onTap (function) | `UIButton` → 触发 Lua 函数 |
| `info` | text | — | 纯文字, 不写 settings |

#### 布尔/多选控件：`switch`、`checkbox`、`checkGroup` 的区别和选型

**iOS 没有原生复选框控件**（这是平台事实：UIKit 只有 `UISwitch` 和列表行的 ✓ 标记）。
引擎的 `checkbox` / `checkGroup` 是自造的：用 `UIButton` + 圆角背景色表达选中状态，
**不打 ✓，纯靠颜色区分**（选中＝蓝色底 + 白字，未选＝浅灰底 + 深色字）。

| 维度 | `switch` | `checkbox` | `checkGroup` |
|---|---|---|---|
| 外观 | iOS 系统设置风格的绿/灰滑动开关 | 右侧 28pt 圆角色块 | 标题下方一行 N 个色块，每个色块上写候选项文字 |
| 值的类型 | bool | bool | **string 数组**（选中项集合） |
| 写 settings.json | `{speedUp=true}` | `{autoRepair=true}` | `{taskSel={"师门任务","宝图任务"}}` |
| 触控范围 | 只能拨右侧开关 | 点色块**或整行文字** | 点任意色块名字 |
| 一行几个 | 1 个开关 | 1 个 | `columns` 控制（默认 3，可选 1~5），自动换行 |
| 语义建议 | 单一"模式/状态"：启动前检查、调试模式 | 单个"清单勾选"项 | **一组清单勾选**（任务列表、权限清单、批量选项） |
| 最低版本 | 所有版本 | App ≥ 1.1.0 | App ≥ 1.2.0 |
| 未给 default 时 | 不写 key（`switch` 无值不落盘） | 默认 false，key 一定写入 | 默认空数组 |

```lua
-- checkGroup: 一组勾选项, 一行 3 个, 点名字变蓝=开启 (任务/权限清单的首选)
{type="checkGroup", key="taskSel",
 label="要做的任务（点名字：蓝色＝开启，灰色＝关闭）",
 options={"师门任务","帮派任务","捉鬼任务","宝图任务","运镖任务","三任务"},
 columns=3,                      -- 一行几个, 默认 3
 default={"师门任务","帮派任务"}}, -- default 必须是数组, 元素 = options 里的字符串

-- checkbox: 单个布尔项 (色块表达, 不打勾)
{type="checkbox", key="autoRepair", label="耐久不足自动修理", default=true},

-- switch: 状态开关仍然用系统开关最符合 iOS 习惯
{type="switch",   key="vpnCheck",   label="启动前检查 VPN", default=false},
```

**行高**：`checkGroup` 的行高 = `34 + 色块行数 × 40`，由引擎按 `options.count / columns`
自动计算（无需手写），色块行数 = `ceil(options数量 / columns)`。

> **版本兼容**：`checkbox` 需 App ≥ 1.1.0，`checkGroup` 需 App ≥ 1.2.0。
> 旧引擎不认识这些类型会把**整行跳过**（表单里该行直接不显示），所以给旧版本用户分发脚本时，
> 建议用 `sys.version()` 探测后降级 —— 引擎自带的 `ui.lua`（梦幻西游脚本）就是这么做的：
> `≥1.2.0` 用 checkGroup，`≥1.1.0` 用一行一个 checkbox，更旧退回 switch：
>
> ```lua
> local function banBenBuDiYu(da, db)
>     local a, b = (sys.version() or ""):match("^(%d+)%.(%d+)")
>     if not a then return false end
>     a, b = tonumber(a), tonumber(b)
>     return a > da or (a == da and b >= db)
> end
> local yongSeKuai = banBenBuDiYu(1, 2)   -- checkGroup
> local yongFuXuan = banBenBuDiYu(1, 1)   -- checkbox
> ```

#### 高级特性

**依赖显示**：`visibleWhen` + `visibleWhenValue`，控制某行是否显示：

```lua
{
    type="text", key="customUrl", label="自定义 URL",
    visibleWhen="mode", visibleWhenValue="自定义",
}
```

`mode` 行的值为 `"自定义"` 时才显示本行。

**校验**：`validator` 字段（`url`/`email`/`number`/`decimal`），保存时校验失败弹"参数有误"提示：

```lua
{type="text", key="webhook", label="Webhook", validator="url", validatorMessage="URL 必须以 http/https 开头"}
```

**Action 回调**：用户点按钮时，引擎把当前所有 row 的 `currentValue` 打包为字典作为唯一参数传给 onTap 函数：

```lua
onTap = function(settings)
    -- settings = {autoStart=true, speed=1.2, ...}
    -- 这里可以即时运行测试/校验/通知, 不影响 settings.json
    sys.toast("当前速度: " .. settings.speed)
end
```

#### 初始化（动态方式）

不想写文件，主脚本里直接用 `ui.openForm`：

```lua
local schema = {
    title = "动态设置",
    sections = {{
        rows = {
            {type="switch", key="debugMode", label="调试模式", default=false},
            {type="slider",  key="speed",     label="速度", min=0.1, max=3.0, default=1.0},
        }
    }},
}
local ran = ui.openForm("myScript", schema)
if ran then
    logStr("用户保存了: 速度=" .. settings.speed)
end
```

#### 强制表单方向（opts.orientation）

`ui.openForm(name, schema, opts)` 和 `ui.open(name, "native", opts)` 的第三参 `opts` 支持 `orientation` 字段，控制 HUD 承载时表单的视觉方向：

| 值 | 效果 | 适用场景 |
|---|---|---|
| `"auto"`（默认） | 跟随脚本坐标系 / 跟随前台 app | 横屏游戏里希望表单也跟着横屏 |
| `"portrait"` | 强制竖屏（即使游戏是横屏也竖屏呈现） | 横屏游戏里点开设置希望看到完整列表 |
| `"landscape"` | 强制横屏（即使游戏是竖屏也横屏呈现） | 竖屏游戏里希望宽表单填屏 |

```lua
-- 横屏游戏中强制竖屏显示表单
local ran = ui.openForm("myScript", schema, { orientation = "portrait" })

-- 或用 ui.open 配合
ui.open("myScript", "native", { orientation = "portrait" })
```

仅 HUD 承载模式生效；TrollAutoTouch 在前台时（极少见，通常是脚本自己切的）此参数被忽略，跟随 app 方向。

#### 底部按钮 + 自动关闭（opts.autoCloseAfter）

底部**只有两个按钮**：

| 按钮 | 背景 | 行为 |
|---|---|---|
| `取消` | 红色（systemRed） | 调 `[[TSLuaBridge shared] stop]` 真正停止脚本，**不写** settings.json，关闭表单返回 false |
| `运行` | 蓝色（systemBlue） | 保存 settings.json + 关闭表单 + 引擎注入 settings 表 + 启动脚本（与历史"保存并运行"完全一致） |

`opts.autoCloseAfter`（数字，秒）开启后表单加载时启动倒计时：

- 倒计时期间底部显示 `N 秒后自动保存并运行 (点取消停止脚本)`
- **归零自动触发"运行"流程**（与点运行按钮完全等价：保存 + 启动）
- 倒计时期间用户可随时点取消（立即停止脚本）或点运行（提前结束倒计时）
- 默认 0 = 不自动关闭，行为与历史一致

```lua
-- 30 秒未操作按当前显示设置自动运行 (梦幻西游脚本兜底配置场景)
ui.openForm("myScript", schema, { autoCloseAfter = 30 })

-- 组合: 强制竖屏 + 30s 自动关闭
ui.openForm("myScript", schema, { orientation = "portrait", autoCloseAfter = 30 })
```

#### 顶部大标题（opts.headerTitle）

`ui.openForm` / `ui.open` 第三参 `opts.headerTitle` 是个字符串，传入后会在导航栏下方、第一个 section 上方渲染一个 banner label：

- 24pt bold 居中（系统 `UIFontWeightBold`）
- 自动 `adjustsFontSizeToFitWidth`，极窄屏（HUD 横屏）会缩到 60% 避免截断
- 背景透明，跟随 table view 滚动
- HUD 旋转时会自适应新宽度

```lua
-- 梦幻西游脚本示例
ui.openForm("myScript", schema, {
    headerTitle = "梦幻西游脚本设置",
})

-- 与其他选项组合
ui.openForm("myScript", schema, {
    headerTitle = "梦幻西游脚本设置",
    orientation = "portrait",
    autoCloseAfter = 30,
})
```

**注意**：`取消` 真的会让 `[[TSLuaBridge shared] stop]` 触发 `_stopRequested=YES`，后续任何 Lua C 调用会抛"脚本已被停止"并立即中断当前脚本。如果你只是想关闭表单而继续用旧配置运行，请改用其他方式（如 sys.alert 二次确认）。

#### 常见注意事项

1. **存储格式与 HTML 版完全相同**：`{key=value, ...}` 写到 `<name>.settings.json`，脚本读 `settings.xxx` 全局表，零额外适配。
2. **后台弹出行为**：当 App 在后台（游戏在前台）时，UIKit 原生 UI **直接**走 SBS 系统级层承载，无需切回本 App、不打断游戏，**这正是 UIKit 路径的最大优势**。
   **HUD 承载局限**：`select` / `multi` 子页（点行进子列表选）、`color` 取色器、校验失败弹窗在 HUD 模式下无法 present（view 挂在 SBS 远程上下文，没有 nav controller 也没有 window hierarchy），会被降级为 NSLog。脚本若主要使用这些类型，请引导用户先切到 TrollAutoTouch 前台再弹设置；只用 `switch / checkbox / checkGroup / segmented / stepper / slider / text / number / date / duration / action / info` 不受影响（梦幻西游脚本的任务区就属于这种情况）。
3. **键盘交互**：iOS 15+ 上 SBS 托管窗口弹键盘基本可用，但偶发不回滚。设置项建议用 segmented / stepper / slider / switch 减少键盘依赖。
4. **依赖显示会触发 reload**：某行值变化导致其他行显隐切换时，表格会 reload，UI 会闪一下 —— 不影响功能，只影响观感。
5. **保存即可运行**：UIKit 原生 UI 的"保存并运行"按钮与 HTML 版的 `ts.save()` 行为完全一致：写 settings.json + 关闭 + 启动脚本 + 注入 `settings` 全局表。
6. **可与 HTML 互迁移**：同一脚本可以同时存在 `index.html` 和 `schema.lua`，注释掉一个即切换；引擎按"auto"模式优先 `schema.lua`。

### 14.7.5 完整调用示例

```lua
-- /var/mobile/touch/lua/myScript.lua (主脚本)
local ran = ui.open("myScript")   -- auto: 优先 schema.lua, 缺则 index.html
if ran then
    logStr("[设置] autoStart=" .. tostring(settings.autoStart))
    logStr("[设置] speed=" .. tostring(settings.speed))
else
    logStr("[设置] 取消或 UI 不存在, 使用默认值")
end

-- 强制 HTML
ui.open("myScript", "html")

-- 强制 UIKit 原生
ui.open("myScript", "native")

-- 动态 schema
ui.openForm("myScript", {
    sections = {{
        rows = {
            {type="switch", key="flag", label="开关", default=true},
        }
    }},
})
```

### 14.7.6 选型建议

| 场景 | 推荐 |
|---|---|
| 简单设置（开关/数值/选择） | UIKit 原生（`schema.lua`） |
| 需要在游戏运行时弹出 | UIKit 原生（不切 app） |
| 自定义布局、图表、动画 | HTML（`index.html`） |
| 多媒体预览、视频 | HTML |
| 一组相关脚本共用同一设置页 | HTML（共享 `ui/<name>/index.html`） |
| 完全不想写 HTML | UIKit 原生（schema 表声明） |
| 已有 HTML 不想改 | HTML（原样保留） |

### 14.7.7 UIKit 原生设置页：全功能完整示例

下面是一个**真实可运行**的完整示例，演示 16 种行类型 + 依赖显示 + 校验 + action 回调 + 多 section + 动态默认值。把它原样写到 `/var/mobile/touch/lua/autoFarm/schema.lua`，主脚本里 `ui.open("autoFarm")` 即可弹出。

#### 文件结构

```
/var/mobile/touch/lua/
├── autoFarm.lua              ← 主脚本
├── autoFarm.settings.json    ← 自动维护 (点保存时写入)
└── ui/
    └── autoFarm/
        └── schema.lua        ← UIKit 原生设置 schema (本示例文件)
```

#### schema.lua 完整内容

```lua
-- ============================================================================
-- /var/mobile/touch/lua/ui/autoFarm/schema.lua
--
-- UIKit 原生设置 UI 完整 schema 演示。
-- 16 种行类型全覆盖: switch/checkbox/checkGroup/stepper/slider/segmented/select/text/textLong/
--                   number/date/duration/color/multi/action/info
-- 高级特性: 依赖显示 (visibleWhen) / 校验 (validator) / action 回调 (onTap)
--
-- 文件名约定: ui/<脚本主名>/schema.lua, 引擎 ui.open("autoFarm") 自动加载。
-- 调试运行后, 引擎把每个 row 的当前值写入:
--   /var/mobile/touch/lua/autoFarm.settings.json
-- 主脚本用全局 settings 表读取, 无需关心存储路径。
-- ============================================================================

-- ── 工具函数 (本地可见, 供 onTap 回调和 options 动态计算使用) ──
local function toBool(v)   return v == true or v == "true" or v == 1 end
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- 模式对应的目标列表 (动态 options, 也可以写死数组)
local function monsterOptions()
    return {"史莱姆", "哥布林", "狼", "蝙蝠", "骷髅兵", "蜘蛛"}
end

-- 难度对应的可执行时间窗 (默认值用动态计算, 体现 schema 默认值可以是表达式)
local function difficultyDefaults(diff)
    if diff == "简单" then return 5
    elseif diff == "困难" then return 30
    else return 15 end
end

return {
    title = "自动挂机 v2.3 设置",

    sections = {

        -- ═══════════════════════════════════════════════════════════════════
        -- 第 1 组: 基础 (所有用户都会改的)
        -- ═══════════════════════════════════════════════════════════════════
        {
            title = "基础",
            footer = "通用选项, 修改后点底部"保存运行"",
            rows = {

                -- switch: 布尔开关
                {type="switch",   key="autoStart",
                 label="启动后立即运行", default=true},

                -- checkbox: 单行复选框 (值同 switch 也是 bool, 点整行可切换,
                --             色块表达选中, 无勾选标记, 需要 App >= 1.1.0)
                {type="checkbox", key="autoRepair",
                 label="耐久不足自动修理", default=true},

                -- checkGroup: 色块组 (一行 columns 个, 点名字变色=选中, 值是 string 数组,
                --             适合"任务/副本/权限清单", 需要 App >= 1.2.0)
                {type="checkGroup", key="enabledDungeons",
                 label="要刷的副本（点名字：蓝色＝开启）",
                 options={"水陆大会", "车迟斗法", "通天河", "乌鸡国", "秘境降妖", "金兜洞"},
                 columns=3,
                 default={"水陆大会", "乌鸡国"}},

                -- stepper: 整数步进 (有 min/max/step, 默认步长 1)
                {type="stepper",  key="retryCount",
                 label="失败重试次数", min=0, max=10, default=3},

                -- slider: 连续值 (format 控制显示格式, showValue 决定右侧是否显示当前值)
                {type="slider",   key="speed",
                 label="运行速度", min=0.5, max=3.0, step=0.1,
                 default=1.0, format="%.1fx", showValue=true},

                -- segmented: 2~5 项分段 (超过 5 项会被截断, 用 select 替代)
                {type="segmented",key="mode",
                 label="战斗模式",
                 options={"刷图", "挂机", "扫荡", "采集"},
                 default="刷图"},

                -- select: 单选列表 (点击进入子表)
                {type="select",   key="role",
                 label="角色",
                 options={"战士", "法师", "道士", "弓箭手"},
                 default="战士"},
            },
        },

        -- ═══════════════════════════════════════════════════════════════════
        -- 第 2 组: 战斗 (本脚本核心逻辑)
        -- ═══════════════════════════════════════════════════════════════════
        {
            title = "战斗",
            footer = "战斗策略相关配置, 找色/坐标会缓存到内存, 改后建议重启脚本",
            rows = {

                -- color: 取色器 (iOS 14+ UIColorWell), 值是 "#RRGGBB" 字符串
                {type="color",    key="targetColor",
                 label="目标颜色 (血条)", default="#FF3344"},

                -- multi: 多选列表 (值是 string 数组)
                {type="multi",    key="targets",
                 label="目标怪物",
                 options=monsterOptions(),   -- 动态 options
                 default={"史莱姆", "哥布林"}},

                -- number: 数字输入 (走 numberPad 键盘, 值是 number)
                {type="number",   key="searchRadius",
                 label="搜索半径 (像素)", min=10, max=500,
                 default=80, step=10, keyboard="number"},

                -- text: 单行文本 (placeholder + keyboard 提示)
                {type="text",     key="webhook",
                 label="通知 Webhook",
                 placeholder="https://oapi.dingtalk.com/robot/send?access_token=...",
                 keyboard="url",
                 validator="url",
                 validatorMessage="Webhook 必须是 http(s):// 开头"},

                -- textLong: 多行文本 (UITextView, 用于粘贴批量内容)
                {type="textLong", key="whitelist",
                 label="白名单账号 (一行一个)",
                 placeholder="账号1\n账号2\n...",
                 default=""},

                -- duration: 时长 (UIDatePicker.countDownTimer, 值是秒)
                {type="duration", key="cooldownSec",
                 label="技能冷却", min=1, max=600, default=10, unit="秒"},

                -- action: 按钮, 触发 onTap 函数 (参数是当前 settings 字典)
                {type="action",   key="testFindColor",
                 label="测试找色 (立即验证 targetColor)",
                 onTap=function(s)
                    -- s.targetColor 是当前选色 (如 "#FF3344")
                    -- 这里可调引擎找色 API 做即时验证, 例如:
                    --   local x, y = findColor({...}, s.targetColor)
                    --   sys.toast(x and ("找到: "..x..","..y) or "未找到")
                    sys.toast("找色测试已执行, 目标颜色=" .. tostring(s.targetColor))
                 end},
            },
        },

        -- ═══════════════════════════════════════════════════════════════════
        -- 第 3 组: 定时 (用 segmented 选择难度, 再联动显示对应时长)
        -- ═══════════════════════════════════════════════════════════════════
        {
            title = "定时",
            footer = "定时启动, 选完难度后再调时间窗",
            rows = {

                -- segmented 难度
                {type="segmented",key="difficulty",
                 label="副本难度",
                 options={"简单", "普通", "困难"},
                 default="普通"},

                -- duration 默认值用 difficulty 计算 (值是数字, 表示秒)
                {type="duration", key="dungeonTimeLimit",
                 label="副本时间限制",
                 min=60, max=3600, default=difficultyDefaults("普通"),
                 unit="秒",
                 visibleWhen="difficulty", visibleWhenValue="困难",
                 placeholder="困难模式建议 30 分钟以上"},

                -- date: 日期+时间 (Unix 秒, mode 控制精度)
                {type="date",     key="scheduleAt",
                 label="下次定时启动", mode="datetime",
                 default=os.time() + 3600},   -- 默认 1 小时后

                -- info: 纯文字, 不写 settings
                {type="info",     text="提示: 定时启动会在 App 后台时通过通知唤醒, "
                                      .."请保持 TrollAutoTouch 通知权限开启"},
            },
        },

        -- ═══════════════════════════════════════════════════════════════════
        -- 第 4 组: 高级 (默认折叠感, 通过依赖显示"调试模式"开启后才出现)
        -- ═══════════════════════════════════════════════════════════════════
        {
            title = "高级",
            footer = "调试用, 默认隐藏, 开启"调试模式"后显示",
            rows = {

                -- 开关决定下面 3 行是否可见
                {type="switch",   key="debugMode",
                 label="调试模式", default=false},

                {type="slider",   key="logLevel",
                 label="日志详细度", min=1, max=5, step=1, default=3,
                 format="Lv %d", showValue=true,
                 visibleWhen="debugMode", visibleWhenValue=true},

                {type="text",     key="logFilter",
                 label="日志关键字过滤",
                 placeholder="留空不过滤",
                 default="",
                 visibleWhen="debugMode", visibleWhenValue=true},

                {type="action",   key="dumpCurrentState",
                 label="导出当前状态到日志",
                 visibleWhen="debugMode", visibleWhenValue=true,
                 onTap=function(s)
                    -- 把当前所有设置导出到日志, 方便用户复现问题
                    logStr("=== autoFarm 当前设置 ===")
                    for k, v in pairs(s) do
                        logStr(string.format("  %s = %s", k,
                                             type(v) == "table" and table.concat(v, ",") or tostring(v)))
                    end
                    logStr("========================")
                    sys.toast("已导出")
                 end},
            },
        },

        -- ═══════════════════════════════════════════════════════════════════
        -- 第 5 组: 关于
        -- ═══════════════════════════════════════════════════════════════════
        {
            title = "关于",
            rows = {
                {type="info", text="自动挂机脚本 v2.3.1 (2026-10-08)"},
                {type="info", text="作者: xxx  QQ群: 123456789"},
                {type="action", key="openHelp",
                 label="查看使用说明",
                 onTap=function(s)
                    sys.toast("文档: https://github.com/xxx/autoFarm/wiki")
                 end},
                {type="action", key="resetAll",
                 label="恢复默认设置",
                 onTap=function(s)
                    -- 注意: action 回调在 settings.json 已保存后才执行,
                    -- 这里的修改不会写回磁盘; 用户需重新点"保存"或"保存运行"才生效。
                    sys.toast("请重新点'保存运行'以应用默认设置")
                 end},
            },
        },
    },
}
```

#### 主脚本 `/var/mobile/touch/lua/autoFarm.lua`

```lua
-- ============================================================================
-- autoFarm.lua - 配合 schema.lua 的主脚本
-- ============================================================================
local ran = ui.open("autoFarm")      -- auto 模式自动选 schema.lua (无需写类型)
if not ran then
    logStr("[设置] 取消或 schema.lua 不存在, 使用硬编码默认值")
end

-- 读取设置 (与 HTML 版完全相同)
logStr("[设置] 模式=" .. tostring(settings.mode)
       .. " 速度=" .. string.format("%.1fx", settings.speed or 1.0)
       .. " 目标=" .. table.concat(settings.targets or {}, ","))

-- checkGroup 的值是字符串数组, 用集合查成员 (数组元素即 options 里的字符串)
local yaoShua = {}
for _, name in ipairs(settings.enabledDungeons or {}) do yaoShua[name] = true end
if yaoShua["水陆大会"] then
    logStr("[设置] 会刷水陆大会")
end

-- 各设置项使用示范
if settings.autoStart then
    sys.toast("启动中...")
end

local cooldown = settings.cooldownSec or 10
logStr("[设置] 技能冷却 = " .. cooldown .. "s")

-- 找色示例
local r, g, b = string.match(settings.targetColor or "#FF3344", "#(%x%x)(%x%x)(%x%x)")
if r then
    logStr("[设置] 目标颜色 RGB = " .. tonumber(r, 16) .. ","
           .. tonumber(g, 16) .. "," .. tonumber(b, 16))
end

-- 难度相关逻辑
if settings.difficulty == "困难" then
    local limit = settings.dungeonTimeLimit or 30 * 60
    logStr("[设置] 困难模式时间限制 = " .. limit .. " 秒")
end

-- 调试模式
if settings.debugMode then
    logStr("[DEBUG] logLevel=" .. tostring(settings.logLevel or 3))
end

-- 进入主循环
while true do
    -- ... 实际挂机逻辑 ...
    mSleep(1000 / (settings.speed or 1.0) / 1000 * 1000)
end
```

#### 行为说明

1. **依赖显示**：`difficulty` 选"困难"才显示 `dungeonTimeLimit`；`debugMode` 开才显示下面 3 行。切换开关会触发表格 reload，被隐藏行不参与保存。
2. **action 回调时机**：用户点按钮 → 引擎把当前所有 row 的 `currentValue` 打包为 dict 传入 `onTap(s)` → 同步在主线程执行（脚本线程此时阻塞在 `ui.open`，未跑 Lua 主循环）→ 函数返回后 UI 继续响应。注意：`onTap` 内的修改**不会**回写到 settings.json，用户需重新点"保存运行"才落盘。
3. **校验**：保存时遍历所有行做 `validator` 校验（`webhook` 的 `url` 类型），失败弹"参数有误"alert，不退出页面。
4. **存储**：点"保存运行" → 引擎收集 `currentValue` → 写 `autoFarm.settings.json` → 注入 `settings` 全局表 → 启动主脚本。
5. **默认值 vs 当前值**：`default` 是 schema 声明的初始值；首次运行 settings.json 不存在时用 `default`。之后每次弹窗都从 settings.json 读上次保存的值填进 cell。
6. **可选行类型**：`stepper` 只能整数；`slider` 浮点；`number` 是键盘输入；`duration` 用倒计时选择器。这四种根据场景选一种。布尔值有 `switch`（系统开关）和 `checkbox`（色块，App ≥ 1.1.0）两种外观，值完全等价可随时互换；一组多选清单用 `checkGroup`（色块组，App ≥ 1.2.0）。
7. **常见坑**：
   - `options` 超过 5 项不要用 `segmented`（自动截断），改用 `select`。
   - `multi` / `checkGroup` 的 `default` 必须是字符串数组 `{"a", "b"}`，不是逗号分隔字符串。
   - `checkbox` / `checkGroup` 需要较新版本引擎，旧引擎会把整行跳过（不报错，只是不显示），跨版本分发脚本时用 `sys.version()` 探测降级。
   - `onTap` 里不要 `mSleep` 太久，会卡住 UI 响应（脚本线程在等 `ui.open` 返回，但主线程弹 action 不会 block）。
   - `visibleWhenValue` 的比较是 `==`（number/bool/string 直比，table 不支持），复杂条件用多个 `visibleWhen` 行实现。

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
| `screen.paddleOcr([x1,y1,x2,y2][, color])` | 屏幕 OCR（默认中英文） → 文本数组；`color` 为可选颜色过滤 `"RRGGBB-偏色"` |
| `screen.visionOcr([lang][,x1,y1,x2,y2])` | 屏幕 OCR（多语言） → 文本数组 |

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
| `sys.setFloatBallPoint(x, y)` | 设置悬浮球位置（物理屏幕坐标，中心点） |
| `restartScript()` | 重新启动当前脚本（调用后后面的代码不会执行） |

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
| `sys.isVPNConnected()` | 是否连接 VPN → boolean |
| `sys.vpnState()` | VPN 检测详情 → table (connected/method/interface) |
| `sys.battery()` | 电量 0~1 |
| `sys.mtime()` | 毫秒级时间戳 → number |
| `sys.availableMemory()` | 系统可用内存 (字节) → number |
| `sys.processUsedMemory()` | 进程内存 (字节) → number |
| `sys.usedMemory()` | 系统已用内存 (字节) → number |
| `sys.version()` | App 版本 → string |
| `sys.palyAudio(path)` | 播放音频文件 → boolean |
| `sys.alert(msg)` | 阻塞弹窗 |
| `sys.toast(msg)` | 屏幕悬浮提示 |
| `sys.setFloatBallPoint(x, y)` | 移动悬浮球 |

### HTTP / 下载

| 函数 | 说明 |
|---|---|
| `http.get(url, [timeout], [headers])` | HTTP GET → code, headers, body |
| `http.post(url, [timeout], [headers], [body])` | HTTP POST (form-urlencoded) → code, headers, body |
| `http.download(url, savePath, [timeout], [progressFn])` | HTTP 下载 → boolean, 进度 (total, cur, speed) |

### 设备与控制

| 函数 | 说明 |
|---|---|
| `device.udid()` | 设备 UDID → string / nil |
| `device.serialNumber()` | 设备序列号 → string / nil |
| `device.turnOnAssistiveTouch()` | 启用辅助触控 → boolean |
| `device.turnOffAssistiveTouch()` | 停用辅助触控 → boolean |
| `device.isScreenLocked()` | 屏幕是否锁定 → boolean |
| `device.unlockScreen()` | 唤醒+解锁屏幕 → boolean |
| `device.name()` | 设备名 → string |
| `device.type()` | 设备类型 → string (iPhone/iPad/...) |
| `device.backlightLevel()` | 屏幕亮度 [0,1] → number |
| `device.setBacklightLevel(n)` | 设置屏幕亮度 |
| `device.lockScreen()` | 锁定屏幕 |
| `device.vibrator()` | 系统震动 |
| `device.setVolume(n)` | 设置系统音量 [0,1] |

### 应用管理

| 函数 | 说明 |
|---|---|
| `app.frontBid()` | 前台 App bundle id → string（桌面时为 `com.apple.springboard`） |
| `app.isInstalled(bid)` | 是否安装 → boolean |
| `app.isRunning(bid)` | 是否正在运行 → boolean |
| `app.open(bid)` | 打开 App → boolean |
| `app.close(bid)` | 关闭 App → boolean |
| `app.inputText(text)` | 输入文本 → boolean |

### 脚本运行状态

| 函数 | 说明 |
|---|---|
| `script.isRunning()` | 宿主脚本引擎是否正在运行脚本 → boolean |
| `script.isPaused()` | 脚本是否被暂停 → boolean（音量键菜单/悬浮球/HUD 上的暂停按钮触发） |

> 与 `app.isRunning(bid)` 语义独立：那个查的是“被操作的目标 App 进程”，这里查的是“本 App 跑的 Lua 脚本本身”。详见 1.4 节。

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
| `file.addText(path, text)` | 追加文本 → boolean |
| `file.size(path)` | 文件大小（字节）→ number / -1 |
| `file.list(path)` | 目录列表 → table / nil |
| `file.md5(path)` | 文件 MD5 → string / nil |
| `file.getLines(path)` | 所有行 → table / nil |
| `file.lineCount(path)` | 总行数 → number |
| `file.getLineText(path, n)` | 第 n 行 → string / nil |
| `file.resetLineText(path, n, text)` | 替换第 n 行 → boolean |
| `file.insertLineText(path, n, text)` | 插入到第 n 行前 → boolean |

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
| `logWindow.init(...)` | 创建浮动日志窗口 → 对象 |
| `logWindow.setHideWindowMode(b)` | 日志窗口隐藏模式 |
| `lw:addLog(text [, color, size])` | 日志窗口追加一行 |
| `lw:release()` | 释放日志窗口 |

### 模块列表

| 模块 | 别名 | 说明 |
|---|---|---|
| `touch` | - | 触摸手势 |
| `screen` | - | 屏幕相关 |
| `sys` | `device` | 系统信息 |
| `app` | - | 应用管理 |
| `appNode` | - | UI 树节点 |
| `http` | - | HTTP / 下载 |
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
