# 无忧辅助 Lua 脚本使用文档

---

## 目录

- [快速入门](#快速入门)
- [脚本管理](#脚本管理)
- [屏幕模块 screen](#屏幕模块-screen)
- [触控模块 touch](#触控模块-touch)
- [应用模块 app](#应用模块-app)
- [工具函数](#工具函数)
- [进阶用法](#进阶用法)
- [完整示例](#完整示例)
- [函数速查表](#函数速查表)

---

## 快速入门

无忧辅助内置 Lua 5.4 脚本引擎，支持编写自动化脚本来控制手机。

### 第一个脚本

```lua
log("Hello, 无忧辅助!")
sleep(1000)                          -- 等待 1 秒
local w, h = screen.resolution()     -- 获取屏幕分辨率
log(string.format("屏幕分辨率: %d x %d", w, h))
```

### 操作流程

1. 打开无忧辅助 App → 切换到「**Lua 脚本**」标签页
2. 在编辑器中编写或粘贴 Lua 代码
3. 点击「**运行**」按钮执行脚本
4. 执行日志会实时显示在下方

---

## 脚本管理

### 文件存储路径

所有脚本文件存放在：

```
/var/mobile/Documents/无忧辅助/scripts/
```

用 **Filza** 或 **SSH** 直接把 `.lua` 文件丢进这个目录即可在 App 内加载。

### 加载脚本

- **从脚本目录加载**：点击工具栏 📁 图标，列表中显示所有已保存的脚本，点击即可加载到编辑器
- **从文件选择器打开**：点击「打开」按钮，使用系统文件 App 浏览任意目录选择 `.lua` 文件
- **保存脚本**：编辑器编写完代码后，点击「保存」按钮，输入文件名即可保存到脚本目录

---

## 屏幕模块 screen

### screen.resolution() — 屏幕分辨率

**函数说明**：获取当前屏幕分辨率。

**语法**：

```lua
width, height = screen.resolution()
```

**返回值**：

| 返回值 | 类型   | 说明             |
|--------|--------|------------------|
| width  | number | 屏幕宽度（像素）  |
| height | number | 屏幕高度（像素）  |

**示例**：

```lua
local w, h = screen.resolution()
log(string.format("分辨率: %d x %d", w, h))

-- 判断设备
if w == 640 and h == 1136 then
    log("当前设备为 iPhone 5")
else
    log("请在 iPhone 5 上使用本程序")
end
```

---

### screen.colorBits() — 屏幕颜色位数

**函数说明**：获取当前屏幕色彩位数。

**语法**：

```lua
color = screen.colorBits()
```

**返回值**：

| 返回值 | 类型   | 说明       |
|--------|--------|------------|
| color  | number | 色彩位数    |

**示例**：

```lua
local color = screen.colorBits()
log(string.format("色彩位数: %d", color))
```

---

### screen.keep() — 屏幕保持

**函数说明**：开启/关闭屏幕保持（缓存屏幕数据）。开启后，后续的取色、找色操作不会重新截取屏幕图像，可大幅提升找色速度。

**语法**：

```lua
screen.keep(on)
```

**参数**：

| 参数 | 类型    | 说明                | 必填 |
|------|---------|---------------------|------|
| on   | boolean | true 开启，false 关闭 | 必填 |

**返回值**：无

**示例**：

```lua
screen.keep(true)  -- 开启屏幕保持

if screen.getColor(100, 100) == 0x000000
   or screen.getColor(200, 200) == 0x000000 then
    log("yes")
else
    log("no")
end

screen.keep(false)  -- 关闭屏幕保持
```

**性能对比**：

```lua
-- 不使用屏幕保持 vs 使用屏幕保持
local start = os.clock()
for i = 1, 100 do
    screen.getColor(1, i)
end
log(string.format("不使用屏幕保持: %.6f", os.clock() - start))

start = os.clock()
screen.keep(true)
for i = 1, 100 do
    screen.getColor(1, i)
end
screen.keep(false)
log(string.format("使用屏幕保持:   %.6f", os.clock() - start))
```

**注意事项**：

1. `screen.keep(true)` 开启后，后续的取色、找色不会重新截取屏幕图像，而是使用缓存数据
2. `screen.keep(false)` 关闭后，每次取色、找色都会重新截取屏幕
3. iOS 上使用此函数可显著提升找色速度

---

### screen.rotate() — 屏幕旋转

**函数说明**：旋转屏幕的坐标体系，后续的取色、找色、截图、触控动作都会使用新的坐标体系。

**语法**：

```lua
screen.rotate(deg)
```

**参数**：

| 参数 | 类型   | 说明                                                         |
|------|--------|--------------------------------------------------------------|
| deg  | number | 0=保持原坐标系，90=向右转90度，-90=向左转90度，180=倒立      |

**返回值**：无

**示例**：

```lua
screen.rotate(90)   -- 旋转坐标体系向右90度
touch.down(0, 100, 100)
touch.up(0)
screen.rotate(0)    -- 恢复坐标体系
```

---

### screen.getColor() — 取色

**函数说明**：获取指定像素的颜色（返回十进制 RGB 值）。

**语法**：

```lua
color = screen.getColor(x, y)
```

**参数**：

| 参数 | 类型   | 说明          | 必填 |
|------|--------|---------------|------|
| x    | number | 取色点 X 坐标  | 必填 |
| y    | number | 取色点 Y 坐标  | 必填 |

**返回值**：

| 返回值 | 类型   | 说明                        |
|--------|--------|-----------------------------|
| color  | number | 十进制颜色值（如白色=16777215） |

**示例**：

```lua
local c = screen.getColor(100, 100)
if c == 0x0000ff then           -- 纯蓝色
    touch.down(0, 100, 100)
    touch.up(0)
end

-- 也可以直接写在 if 里
if screen.getColor(100, 100) == 0x0000ff then
    touch.down(0, 100, 100)
    touch.up(0)
end
```

**注意事项**：

1. 返回的是十进制颜色值，与十六进制对比时前面需加 `0x`，如 `0xFFFFFF`
2. 十六进制颜色 `0xAABBCC` 中，`AA`=红(R)，`BB`=绿(G)，`CC`=蓝(B)

---

### screen.getColorRGB() — 取色 RGB

**函数说明**：获取指定像素颜色的 R、G、B 三个分量。

**语法**：

```lua
r, g, b = screen.getColorRGB(x, y)
```

**参数**：

| 参数 | 类型   | 说明          | 必填 |
|------|--------|---------------|------|
| x    | number | 取色点 X 坐标  | 必填 |
| y    | number | 取色点 Y 坐标  | 必填 |

**返回值**：

| 返回值 | 类型   | 说明              |
|--------|--------|-------------------|
| r      | number | 红色分量 (0-255)  |
| g      | number | 绿色分量 (0-255)  |
| b      | number | 蓝色分量 (0-255)  |

**示例**：

```lua
local r, g, b = screen.getColorRGB(100, 100)
if r == 0x00 and g == 0x00 and b == 0xff then   -- 纯蓝色
    touch.down(0, 100, 100)
    touch.up(0)
end
```

---

### screen.findColor() — 找色

**函数说明**：寻找符合指定颜色的坐标。

**语法**：

```lua
x, y = screen.findColor(colors, fuzzy, ltx, lty, rbx, rby, all)
```

**参数**：

| 参数   | 类型          | 说明                                          | 必填       |
|--------|---------------|-----------------------------------------------|------------|
| colors | table         | 颜色数组，`{color1, offx2, offy2, color2, ...}` | 必填       |
| fuzzy  | number        | 精度，范围 1~100，100=完全匹配                 | 可选，默认100 |
| ltx    | number        | 搜索区域左上角 X 坐标                          | 可选，默认0  |
| lty    | number        | 搜索区域左上角 Y 坐标                          | 可选，默认0  |
| rbx    | number        | 搜索区域右下角 X 坐标                          | 可选，默认全屏 |
| rby    | number        | 搜索区域右下角 Y 坐标                          | 可选，默认全屏 |
| all    | boolean       | 是否返回所有符合条件的坐标                     | 可选，默认false |

**返回值（all 为 false，默认）**：

| 返回值 | 类型   | 说明                       |
|--------|--------|----------------------------|
| x      | number | 找到的 X 坐标，未找到=-1    |
| y      | number | 找到的 Y 坐标，未找到=-1    |

**返回值（all 为 true）**：

| 返回值 | 类型  | 说明                                      |
|--------|-------|-------------------------------------------|
| table  | table | 坐标数组 `{{x1, y1}, {x2, y2}, ...}`       |

**示例**：

```lua
-- 全屏找色
local x, y = screen.findColor({0x0000ff})
if x ~= -1 and y ~= -1 then
    touch.down(0, x, y)
    touch.up(0)
end

-- 全屏模糊找色（精确度90%）
x, y = screen.findColor({0x0000ff}, 90)
if x ~= -1 and y ~= -1 then
    touch.down(0, x, y)
    touch.up(0)
end

-- 单点判断颜色是否匹配
x, y = screen.findColor({0x0000ff}, 90, 100, 100, 100, 100)
if x ~= -1 and y ~= -1 then
    log("(100,100) 处颜色匹配")
end

-- 区域模糊找色
x, y = screen.findColor({0x0000ff}, 90, 100, 100, 200, 200)
if x ~= -1 and y ~= -1 then
    touch.down(0, x, y)
    touch.up(0)
end

-- 不断降低精确度
for sim = 100, 50, -1 do
    x, y = screen.findColor({0x0000ff}, sim, 100, 100, 100, 100)
    if x ~= -1 and y ~= -1 then
        touch.down(0, x, y)
        touch.up(0)
        break
    end
end

-- 多点找色
-- 在区域内找满足以下条件的点：
--  1. 颜色为 0x0000ff
--  2. 该点 (x+10, y+20) 处颜色为 0x00ff00
--  3. 该点 (x-10, y-20) 处颜色为 0xff0000
x, y = screen.findColor({0x0000ff, 10, 20, 0x00ff00, -10, -20, 0xff0000}, 90, 10, 10, 200, 200)
if x ~= -1 and y ~= -1 then
    touch.down(0, x, y)
    touch.up(0)
end

-- 返回所有坐标
local t = screen.findColor({0xEB78E6, 1, 0, 0xF09CE9, 2, 4, 0x6C1771}, 80, 100, 100, 500, 500, true)
for _, pt in ipairs(t) do
    log(string.format("找到: (%d, %d)", pt[1], pt[2]))
end
```

**注意事项**：

1. 未找到时返回 (-1, -1)
2. 多点找色：数组内坐标为第一个坐标的**相对值**
3. 精确度设置越低越容易误判，建议 60~90 之间
4. 全屏找色耗费资源，建议缩小搜索区域或使用多点找色

---

### screen.snapshot() — 截图

**函数说明**：截取屏幕并保存为 PNG 文件。

**语法**：

```lua
ok = screen.snapshot(path, x, y, w, h)
```

**参数**：

| 参数 | 类型   | 说明                  | 必填       |
|------|--------|-----------------------|------------|
| path | string | 保存路径               | 必填       |
| x    | number | 截图区域左上角 X 坐标   | 可选，默认0 |
| y    | number | 截图区域左上角 Y 坐标   | 可选，默认0 |
| w    | number | 截图区域宽度            | 可选，默认全屏 |
| h    | number | 截图区域高度            | 可选，默认全屏 |

**返回值**：

| 返回值 | 类型    | 说明               |
|--------|---------|--------------------|
| ok     | boolean | true=成功，false=失败 |

**示例**：

```lua
-- 全屏截图
screen.snapshot("/var/mobile/Documents/screenshot.png")

-- 区域截图
screen.snapshot("/var/mobile/Documents/region.png", 100, 100, 200, 200)

-- 屏幕保持后的二值化截图
screen.keep(true, {0xffffff}, 90)
screen.snapshot("/var/mobile/Documents/binary.png")
screen.keep(false)
```

---

## 触控模块 touch

### touch.down() — 按下

**函数说明**：发送手指按下事件。

**语法**：

```lua
touch.down(fingerID, x, y)
```

**参数**：

| 参数     | 类型   | 说明                         | 必填 |
|----------|--------|------------------------------|------|
| fingerID | number | 手指ID，范围 0~128，用于标识手指 | 必填 |
| x        | number | 按下位置 X 坐标               | 必填 |
| y        | number | 按下位置 Y 坐标               | 必填 |

**返回值**：无

**示例**：

```lua
touch.down(0, 100, 100)   -- ID=0 的手指在 (100,100) 按下
sleep(100)                -- 延时 100ms（建议 > 20ms）
touch.up(0)               -- ID=0 的手指抬起
```

**封装点击函数**：

```lua
function click(x, y)
    touch.down(0, x, y)
    sleep(200)
    touch.up(0)
end

click(100, 100)
```

**封装可控制按下时间的点击函数**：

```lua
function click(x, y, n)
    touch.down(0, x, y)
    sleep(n)
    touch.up(0)
end

click(100, 100, 1000)  -- 按下 1 秒后抬起
```

**注意事项**：`touch.down` 和 `touch.up` 之间要插入一定的延时，建议大于 20ms，否则可能出现点击无效等异常。

---

### touch.move() — 移动

**函数说明**：发送手指移动事件。

**语法**：

```lua
touch.move(fingerID, x, y)
```

**参数**：

| 参数     | 类型   | 说明                       | 必填 |
|----------|--------|----------------------------|------|
| fingerID | number | `touch.down()` 时传入的手指ID | 必填 |
| x        | number | 移动目标 X 坐标              | 必填 |
| y        | number | 移动目标 Y 坐标              | 必填 |

**返回值**：无

**示例**：

```lua
touch.down(0, 100, 100)
sleep(100)
touch.move(0, 200, 100)   -- 移动到 (200, 100)
sleep(100)
touch.up(0)
```

**封装连续移动函数**：

```lua
function clickMove(x1, y1, x2, y2, n)
    local w = math.abs(x2 - x1)
    local h = math.abs(y2 - y1)
    touch.down(0, x1, y1)
    sleep(50)

    local w1 = (x1 < x2) and n or -n
    local h1 = (y1 < y2) and n or -n

    if w >= h then
        for i = 1, w, n do
            x1 = x1 + w1
            if y1 ~= y2 then
                y1 = y1 + math.ceil(h * h1 / w)
            end
            touch.move(0, x1, y1)
            sleep(10)
        end
    else
        for i = 1, h, n do
            y1 = y1 + h1
            if x1 ~= x2 then
                x1 = x1 + math.ceil(w * w1 / h)
            end
            touch.move(0, x1, y1)
            sleep(10)
        end
    end

    sleep(50)
    touch.up(0)
end

clickMove(100, 100, 200, 200, 5)  -- 每次移动5像素
```

---

### touch.up() — 抬起

**函数说明**：发送手指抬起事件。

**语法**：

```lua
touch.up(fingerID)
```

**参数**：

| 参数     | 类型   | 说明                       | 必填 |
|----------|--------|----------------------------|------|
| fingerID | number | `touch.down()` 时传入的手指ID | 必填 |

**返回值**：无

**示例**：

```lua
touch.down(0, 100, 100)
sleep(100)
touch.up(0)
```

---

### touch.tap() — 点击

**函数说明**：发送手指点击事件（相当于 down + sleep + up 的快捷封装）。

**语法**：

```lua
touch.tap(x, y, ms, fingerID)
```

**参数**：

| 参数     | 类型   | 说明                      | 必填       |
|----------|--------|---------------------------|------------|
| x        | number | 点击位置 X 坐标            | 必填       |
| y        | number | 点击位置 Y 坐标            | 必填       |
| ms       | number | 按下延迟（毫秒）           | 可选，默认50 |
| fingerID | number | 手指ID                    | 可选，默认随机0-10 |

**返回值**：无

**示例**：

```lua
-- 默认延迟 50ms
touch.tap(100, 100)

-- 指定延迟 100ms，手指ID=0
touch.tap(100, 100, 100, 0)
```

---

### touch.tapRandom() — 随机点击

**函数说明**：发送手指随机点击事件，在目标坐标附近随机偏移后点击。

**语法**：

```lua
touch.tapRandom(x, y, range, ms, fingerID)
```

**参数**：

| 参数     | 类型   | 说明                         | 必填       |
|----------|--------|------------------------------|------------|
| x        | number | 目标点击 X 坐标               | 必填       |
| y        | number | 目标点击 Y 坐标               | 必填       |
| range    | number | 随机偏移范围（±值）           | 可选，默认5  |
| ms       | number | 按下延迟（毫秒）              | 可选，默认50 |
| fingerID | number | 手指ID                       | 可选，默认随机0-10 |

**返回值**：无

**示例**：

```lua
-- 默认偏移 ±5，延迟 50ms，随机手指ID
touch.tapRandom(100, 100)

-- 偏移 ±10，延迟 100ms，手指ID=1
touch.tapRandom(100, 100, 10, 100, 1)
```

---

### touch.slide() — 滑动

**函数说明**：创建一个滑动对象，支持链式调用。

**语法**：

```lua
slide = touch.slide(fingerID)
```

**参数**：

| 参数     | 类型   | 说明                      | 必填       |
|----------|--------|---------------------------|------------|
| fingerID | number | 手指ID                    | 可选，默认随机0-10 |

**Slide 对象方法**：

| 方法            | 参数              | 说明               |
|-----------------|-------------------|--------------------|
| `slide:step(n)`  | n=步进像素，默认10  | 设置每步移动像素数  |
| `slide:delay(n)` | n=延迟ms，默认5     | 设置每步之间延迟    |
| `slide:on(x, y)`  | 坐标              | 手指按下           |
| `slide:move(x, y)` | 坐标             | 手指移动到         |
| `slide:up()`      | 无                | 手指抬起           |

**返回值**：Slide 对象（支持链式调用）

**示例**：

```lua
-- 基本滑动：从 (100,100) 移动到 (200,100)
touch.slide():on(100, 100):move(200, 100):up()

-- 指定手指ID、步进和延迟
touch.slide(1):step(10):delay(10):on(100, 100):move(200, 100):up()

-- 画一个正方形
touch.slide():step(10):delay(5)
    :on(100, 100)
    :move(200, 100)
    :move(200, 200)
    :move(100, 200)
    :move(100, 100)
    :up()

-- 两指操作实现缩小
local s1 = touch.slide(1):step(1):delay(5):on(100, 100)
local s2 = touch.slide(2):step(1):delay(5):on(500, 100)
for i = 1, 200 do
    s1:move(100 + i, 100)
    s2:move(500 - i, 100)
end
s1:up()
s2:up()

-- 滑动过程中执行其他函数
local slide = touch.slide():step(5):delay(5)
slide:on(100, 100):move(200, 100)
log("滑到一半了")
local x, y = 200, 200
slide:move(x, y):up()
```

---

## 应用模块 app

### app.frontBid() — 前台应用包名

**函数说明**：获取当前正在前台运行的 APP 包名（Bundle ID）。

**语法**：

```lua
bid = app.frontBid()
```

**返回值**：

| 返回值 | 类型   | 说明                   |
|--------|--------|------------------------|
| bid    | string | 当前前台 APP 的包名     |

**示例**：

```lua
local bid = app.frontBid()
log("当前前台应用: " .. bid)

-- 判断是否在特定 App 中
if bid == "com.touchelf.app" then
    log("当前在触摸精灵中")
end
```

---

### app.run() — 启动应用

**函数说明**：打开并运行指定包名的应用。

**语法**：

```lua
ok = app.run(bid)
```

**参数**：

| 参数 | 类型   | 说明           | 必填 |
|------|--------|----------------|------|
| bid  | string | 要启动的应用包名 | 必填 |

**返回值**：

| 返回值 | 类型    | 说明               |
|--------|---------|--------------------|
| ok     | boolean | true=成功，false=失败 |

**示例**：

```lua
app.run("com.touchelf.app")  -- 打开触摸精灵
sleep(2000)                  -- 等待应用启动

-- 打开浏览器
app.run("com.apple.mobilesafari")
```

**注意事项**：

- 应用包名可在手机设置→通用→关于本机→应用列表中查看
- 也可使用 `app.frontBid()` 获取当前应用的包名

---

### app.kill() — 关闭应用

**函数说明**：关闭指定包名的应用。

**语法**：

```lua
ok = app.kill(bid)
```

**参数**：

| 参数 | 类型   | 说明             | 必填 |
|------|--------|------------------|------|
| bid  | string | 要关闭的应用包名   | 必填 |

**返回值**：

| 返回值 | 类型    | 说明               |
|--------|---------|--------------------|
| ok     | boolean | true=成功，false=失败 |

**示例**：

```lua
app.kill("com.touchelf.app")  -- 关闭触摸精灵
```

**多次关闭示例**：某些应用一次可能关不掉，可以用循环确保关闭：

```lua
-- 确保关闭某个应用
function force_kill(app_package)
    while true do
        if app.running(app_package) then
            app.kill(app_package)
            sleep(1000)
        else
            return true
        end
    end
end

force_kill("com.touchelf.app")
```

---

### app.running() — 应用是否运行

**函数说明**：判断指定应用是否正在运行。

**语法**：

```lua
flag = app.running(bid)
```

**参数**：

| 参数 | 类型   | 说明             | 必填 |
|------|--------|------------------|------|
| bid  | string | 要检测的应用包名   | 必填 |

**返回值**：

| 返回值 | 类型    | 说明                        |
|--------|---------|-----------------------------|
| flag   | boolean | true=正在运行，false=未运行   |

**示例**：

```lua
if app.running("com.touchelf.app") then
    log("触摸精灵正在运行")
else
    log("触摸精灵未运行")
end

-- 启动 App 并等待它开始运行
app.run("com.example.app")
local timeout = 5000
local elapsed = 0
while elapsed < timeout do
    if app.running("com.example.app") then
        log("应用已启动")
        break
    end
    sleep(500)
    elapsed = elapsed + 500
end
```

---

### app.bundlePath() — 应用包目录

**函数说明**：获取指定应用的主程序目录路径。

**语法**：

```lua
path = app.bundlePath(bid)
```

**参数**：

| 参数 | 类型   | 说明           | 必填 |
|------|--------|----------------|------|
| bid  | string | 要查询的应用包名 | 必填 |

**返回值**：

| 返回值 | 类型   | 说明                     |
|--------|--------|--------------------------|
| path   | string | 应用 .app 包目录完整路径  |

**示例**：

```lua
local path = app.bundlePath("com.touchelf.app")
if path ~= "" then
    log("触摸精灵路径: " .. path)
else
    log("应用未安装或路径未知")
end
```

---

🎯 **实用场景示例 — 循环检测状态并启动/关闭应用**

```lua
-- 场景：监控并控制应用状态
function main()
    log("===== 应用状态监控开始 =====")

    -- 获取当前前台应用
    local current = app.frontBid()
    log("当前前台: " .. current)

    -- 启动目标应用
    local target = "com.example.game"
    log("启动目标应用: " .. target)
    app.run(target)
    sleep(3000)

    -- 确认是否启动成功
    if not app.running(target) then
        log("❌ 应用启动失败，重试...")
        app.run(target)
        sleep(3000)
    end

    if app.running(target) then
        log("✅ 应用运行中，路径: " .. app.bundlePath(target))
    else
        log("❌ 应用仍未运行")
    end

    -- 执行完任务后关闭
    log("任务完成，关闭应用")
    app.kill(target)
    sleep(1000)

    if not app.running(target) then
        log("✅ 应用已关闭")
    end

    log("===== 监控结束 =====")
end

main()
```

---

## 工具函数

### log(msg) — 输出日志

**函数说明**：向 App 日志窗口输出一条消息。

**语法**：

```lua
log(msg)
```

**参数**：

| 参数 | 类型   | 说明       | 必填 |
|------|--------|------------|------|
| msg  | string | 要输出的消息 | 必填 |

**返回值**：无

**示例**：

```lua
log("脚本开始执行")
log(string.format("坐标: (%d, %d)", 100, 200))

local count = 0
for i = 1, 10 do
    count = count + 1
    log(string.format("进度: %d/10", count))
    sleep(500)
end

log("脚本执行完成")
```

---

### sleep(ms) — 延时等待

**函数说明**：暂停脚本执行指定毫秒数。

**语法**：

```lua
sleep(ms)
```

**参数**：

| 参数 | 类型   | 说明         | 必填 |
|------|--------|--------------|------|
| ms   | number | 等待的毫秒数  | 必填 |

**返回值**：无

**示例**：

```lua
sleep(1000)   -- 等待 1 秒
sleep(500)    -- 等待 0.5 秒
sleep(50)     -- 等待 50 毫秒

-- 循环中延时
for i = 1, 5 do
    touch.tap(100, 200)
    sleep(1000)
end
```

---

### stop_script() — 停止脚本

**函数说明**：设置停止标志，中断脚本执行。

**语法**：

```lua
stop_script()
```

**参数**：无

**返回值**：无

**示例**：

```lua
local r, g, b = screen.getColorRGB(100, 100)
if r == 255 and g == 0 and b == 0 then
    log("检测到红色，停止脚本")
    stop_script()
end
```

---

## 进阶用法

### 循环找色并点击

```lua
-- 持续检测某个按钮出现后点击，最多等 10 秒
local timeout = 10000
local elapsed = 0
local interval = 500

while elapsed < timeout do
    local x, y = screen.findColor({0x007AFF}, 90, 100, 500, 300, 700)
    if x ~= -1 and y ~= -1 then
        log(string.format("找到目标: (%d, %d)", x, y))
        touch.tap(x, y)
        break
    end
    sleep(interval)
    elapsed = elapsed + interval
end

if elapsed >= timeout then
    log("超时：未找到目标")
end
```

### 取色对比判断

```lua
-- 判断某个位置是否出现特定颜色
local function isColorMatch(x, y, r, g, b)
    local rx, ry = screen.findColor({r*65536 + g*256 + b}, 95, x, y, x, y)
    return rx ~= -1 and ry ~= -1
end

if isColorMatch(100, 200, 255, 255, 255) then
    log("检测到白色")
    touch.tap(100, 200)
else
    log("未检测到目标颜色")
end
```

### 多点顺序点击

```lua
-- 模拟登录流程
local function login()
    touch.tap(200, 400)
    sleep(300)
    touch.tap(200, 500)
    sleep(300)
    touch.tap(200, 650)
    sleep(2000)

    local x, y = screen.findColor({0x00FF00}, 70, 0, 0, 600, 800)
    if x ~= -1 then
        log("登录成功")
    else
        log("登录可能失败")
    end
end

login()
```

### 滑动翻页 + 条件检测

```lua
-- 向下滑动直到找到目标或滑到末尾
local function scrollUntilFound(targetColor, maxScrolls)
    local w, h = screen.resolution()
    local sx, sy1, sy2 = w / 2, h * 0.7, h * 0.3

    for i = 1, maxScrolls do
        local x, y = screen.findColor({targetColor}, 85)
        if x ~= -1 then
            log(string.format("第 %d 页找到目标: (%d, %d)", i, x, y))
            return x, y
        end

        log(string.format("第 %d 页未找到，向下滑动...", i))
        touch.slide():on(sx, sy1):move(sx, sy2):up()
        sleep(1000)
    end

    log("已滑动到底，未找到目标")
    return -1, -1
end

local x, y = scrollUntilFound(0xFF0000, 10)  -- 最多翻 10 页找红色
if x ~= -1 then
    touch.tap(x, y)
end
```

### 多指同时操作

```lua
-- 两指缩放
local w, h = screen.resolution()
local cx, cy = w / 2, h / 2

local s1 = touch.slide(1):step(2):delay(3):on(cx - 100, cy)
local s2 = touch.slide(2):step(2):delay(3):on(cx + 100, cy)

-- 两个手指同时向外移动
for i = 1, 100 do
    s1:move(cx - 100 - i, cy)
    s2:move(cx + 100 + i, cy)
end

s1:up()
s2:up()
```

### 屏幕保持加速取色

```lua
screen.keep(true)  -- 缓存屏幕

local start = os.clock()
for i = 1, 100 do
    screen.getColor(1, i)
end
log(string.format("屏幕保持模式: %.6f 秒", os.clock() - start))

screen.keep(false)  -- 释放缓存
```

---

## 完整示例

### 示例 1：屏幕信息采集

```lua
log("===== 屏幕信息采集 =====")

local w, h = screen.resolution()
log(string.format("分辨率: %d x %d", w, h))
log(string.format("色彩位数: %d", screen.colorBits()))

-- 四个角和中心点颜色
local corners = {
    {"左上角", 0, 0},
    {"右上角", w - 1, 0},
    {"左下角", 0, h - 1},
    {"右下角", w - 1, h - 1},
    {"中心点", w / 2, h / 2},
}

for _, p in ipairs(corners) do
    local r, g, b = screen.getColorRGB(p[2], p[3])
    log(string.format("%s (%d,%d): R=%d G=%d B=%d", p[1], p[2], p[3], r, g, b))
end

log("===== 采集完成 =====")
```

### 示例 2：自动连点器

```lua
-- 在指定位置连点 50 次，每次间隔 100ms
local x, y = 300, 500
local count = 50
local interval = 100

log(string.format("开始连点: (%d, %d) x%d 次", x, y, count))

for i = 1, count do
    touch.tap(x, y)
    log(string.format("%d/%d", i, count))
    sleep(interval)
end

log("连点完成!")
```

### 示例 3：颜色触发自动化

```lua
-- 监控屏幕上的红绿灯状态并做出反应
local function monitorLight()
    local checkX, checkY = 400, 300

    for round = 1, 100 do
        local r, g, b = screen.getColorRGB(checkX, checkY)

        if r > 200 and g < 50 and b < 50 then
            log(string.format("[第%d轮] 检测到红色 → 不操作", round))
        elseif r < 50 and g > 200 and b < 50 then
            log(string.format("[第%d轮] 检测到绿色 → 点击!", round))
            touch.tap(400, 500)
            break
        elseif r < 50 and g < 50 and b > 200 then
            log(string.format("[第%d轮] 检测到蓝色 → 等待", round))
        else
            log(string.format("[第%d轮] 颜色 R=%d G=%d B=%d", round, r, g, b))
        end

        sleep(500)
    end
end

monitorLight()
```

### 示例 4：循环滑动浏览

```lua
-- 模拟浏览商品列表
local function browse()
    local w, h = screen.resolution()
    local swipeX = w / 2

    for page = 1, 5 do
        log(string.format("===== 第 %d 页 =====", page))

        -- 在当前页找商品
        local x, y = screen.findColor({0xFF8000}, 80, 100, 200, w - 100, h - 100)
        if x ~= -1 then
            log(string.format("找到商品: (%d, %d)，点击进入", x, y))
            touch.tap(x, y)
            sleep(2000)
            touch.tap(60, 100)   -- 点击返回按钮
            sleep(1000)
        else
            log("本页未找到目标商品")
        end

        -- 下滑到下一页
        touch.slide():on(swipeX, h * 0.7):move(swipeX, h * 0.3):up()
        sleep(1500)
    end

    log("浏览完成")
end

browse()
```

### 示例 5：两指缩放操作

```lua
local w, h = screen.resolution()
local cx, cy = w / 2, h / 2

-- 缩小（两指向内）
local s1 = touch.slide(1):step(2):delay(3):on(cx - 150, cy)
local s2 = touch.slide(2):step(2):delay(3):on(cx + 150, cy)
for i = 1, 100 do
    s1:move(cx - 150 + i, cy)
    s2:move(cx + 150 - i, cy)
end
s1:up()
s2:up()

sleep(1000)

-- 放大（两指向外）
s1 = touch.slide(1):step(2):delay(3):on(cx - 50, cy)
s2 = touch.slide(2):step(2):delay(3):on(cx + 50, cy)
for i = 1, 100 do
    s1:move(cx - 50 - i, cy)
    s2:move(cx + 50 + i, cy)
end
s1:up()
s2:up()
```

---

## 函数速查表

### screen 模块

| 函数 | 语法 | 说明 |
|------|------|------|
| `screen.resolution()` | `w, h = screen.resolution()` | 获取屏幕分辨率 |
| `screen.colorBits()` | `bits = screen.colorBits()` | 获取色彩位数 |
| `screen.keep()` | `screen.keep(on)` | 开启/关闭屏幕保持 |
| `screen.rotate()` | `screen.rotate(deg)` | 旋转坐标体系 |
| `screen.getColor()` | `color = screen.getColor(x, y)` | 取色（返回十进制颜色值） |
| `screen.getColorRGB()` | `r, g, b = screen.getColorRGB(x, y)` | 取色（返回 R,G,B） |
| `screen.findColor()` | `x, y = screen.findColor(colors, fuzzy, ...)` | 找色 |
| `screen.snapshot()` | `ok = screen.snapshot(path, x, y, w, h)` | 截图保存 |

### touch 模块

| 函数 | 语法 | 说明 |
|------|------|------|
| `touch.down()` | `touch.down(id, x, y)` | 手指按下 |
| `touch.move()` | `touch.move(id, x, y)` | 手指移动 |
| `touch.up()` | `touch.up(id)` | 手指抬起 |
| `touch.tap()` | `touch.tap(x, y, ms, id)` | 快捷点击 |
| `touch.tapRandom()` | `touch.tapRandom(x, y, r, ms, id)` | 随机偏移点击 |
| `touch.slide()` | `slide = touch.slide(id)` | 创建滑动对象 |

### app 模块

| 函数 | 语法 | 说明 |
|------|------|------|
| `app.frontBid()` | `bid = app.frontBid()` | 获取前台应用包名 |
| `app.run()` | `ok = app.run(bid)` | 启动指定应用 |
| `app.kill()` | `ok = app.kill(bid)` | 关闭指定应用 |
| `app.running()` | `flag = app.running(bid)` | 检测应用是否运行 |
| `app.bundlePath()` | `path = app.bundlePath(bid)` | 获取应用包目录路径 |

### 工具函数

| 函数 | 语法 | 说明 |
|------|------|------|
| `log()` | `log(msg)` | 输出日志 |
| `sleep()` | `sleep(ms)` | 延时等待（毫秒） |
| `stop_script()` | `stop_script()` | 停止脚本 |

---

## 注意事项

1. **坐标系统**：以物理像素为单位，坐标原点为屏幕左上角（HOME 键在下时）
2. **颜色值**：`screen.getColor()` 返回十进制，对比时加 `0x` 前缀，如 `0xFFFFFF`
3. **找色精度**：`fuzzy` 范围 1~100，100 为完全匹配，建议 60~90 之间
4. **触控延时**：`touch.down` 和 `touch.up` 之间建议插入 > 20ms 延时
5. **脚本停止**：运行中的脚本可随时通过界面「停止」按钮中断
6. **权限要求**：屏幕取色和触控模拟需要 App 以 TrollStore 安装，普通签名安装不可用
7. **性能优化**：使用 `screen.keep(true)` 缓存屏幕数据可大幅提升连续取色/找色速度
