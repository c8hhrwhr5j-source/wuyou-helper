# TrollAutoTouch 脚本文档

> TrollAutoTouch 是基于 TrollStore 的 iOS 自动化脚本引擎，支持 **DSL 行式脚本** 和 **Lua 脚本** 两种编程方式。
>
> 本文档涵盖了所有已实现功能的完整 API 参考，以及原版 TrollAutoScript 模块的兼容性说明。
>
> **实现进度：DSL 命令 70+ 条全实现 | Lua 模块 13 个 | 原版兼容 6/22 模块已覆盖**

---

## 目录

- [一、快速开始](#一快速开始)
- [二、DSL 行式脚本引擎（✅ 全部已实现）](#二dsl-行式脚本引擎-全部已实现)
  - [2.1 触控操作](#21-触控操作)
  - [2.2 颜色识别](#22-颜色识别)
  - [2.3 图像识别](#23-图像识别)
  - [2.4 录制与回放](#24-录制与回放)
  - [2.5 UI 节点操作](#25-ui-节点操作)
  - [2.6 设备与屏幕](#26-设备与屏幕)
  - [2.7 OCR 文字识别](#27-ocr-文字识别)
  - [2.8 Web 远程控制](#28-web-远程控制)
  - [2.9 Shell 命令执行](#29-shell-命令执行)
  - [2.10 文件操作](#210-文件操作)
  - [2.11 网络操作](#211-网络操作)
  - [2.12 系统信息](#212-系统信息)
  - [2.13 文本输入](#213-文本输入)
  - [2.14 流程控制](#214-流程控制)
  - [2.15 应用管理](#215-应用管理)
  - [2.16 文件操作扩展](#216-文件操作扩展)
  - [2.17 剪贴板](#217-剪贴板)
  - [2.18 Plist 操作](#218-plist-操作)
  - [2.19 按键控制](#219-按键控制)
  - [2.20 加密与哈希](#220-加密与哈希)
  - [2.21 字符串工具](#221-字符串工具)
- [三、Lua 桥接模块（✅ 大部分已实现）](#三lua-桥接模块-大部分已实现)
  - [3.1 touch 模块](#31-touch-模块)
  - [3.2 screen 模块](#32-screen-模块)
  - [3.3 sys 模块](#33-sys-模块)
  - [3.4 device 模块](#34-device-模块)
  - [3.5 json 模块](#35-json-模块)
  - [3.6 appNode 模块](#36-appnode-模块)
  - [3.7 app 模块](#37-app-模块)
  - [3.8 pasteboard 模块](#38-pasteboard-模块)
  - [3.9 plist 模块](#39-plist-模块)
  - [3.10 file 模块](#310-file-模块)
  - [3.11 key 模块](#311-key-模块)
  - [3.12 str 模块](#312-str-模块)
  - [3.13 全局兼容函数](#313-全局兼容函数)
- [四、原版 TrollAutoScript 模块参考](#四原版-trollautoscript-模块参考)
  - [4.1 图片对象模块](#41-图片对象模块)
  - [4.2 屏幕模块](#42-屏幕模块)
  - [4.3 应用模块（✅ 已实现，见 DSL 2.15 / Lua 3.7）](#43-应用模块-已实现见-dsl-215--lua-37)
  - [4.4 扩展 string 库（✅ 见 DSL 2.20-2.21 / Lua 3.12 str）](#44-扩展-string-库-见-dsl-220-221--lua-312-str)
  - [4.5 文件操作模块（✅ 见 DSL 2.10+2.16 / Lua 3.10 file）](#45-文件操作模块-见-dsl-210216--lua-310-file)
  - [4.7 按键模块（✅ 见 DSL 2.19 / Lua 3.11 key）](#47-按键模块-见-dsl-219--lua-311-key)
  - [4.10 剪贴板模块（✅ 见 DSL 2.17 / Lua 3.8 pasteboard）](#410-剪贴板模块-见-dsl-217--lua-38-pasteboard)
  - [4.17 JSON 模块（✅ decode 已实现）](#417-json-模块-decode-已实现)
  - [4.20 plist 模块（✅ 见 DSL 2.18 / Lua 3.9 plist）](#420-plist-模块-见-dsl-218--lua-39-plist)
  - [4.6 日志视图模块](#46-日志视图模块)
  - [4.8 触摸模块（原版）](#48-触摸模块原版)
  - [4.9 清理模块](#49-清理模块)
  - [4.11 系统模块](#411-系统模块)
  - [4.12 线程模块](#412-线程模块)
  - [4.13 节点模块](#413-节点模块)
  - [4.14 设备模块](#414-设备模块)
  - [4.15 CoreML 模块](#415-coreml-模块)
  - [4.16 HTTP 模块](#416-http-模块)
  - [4.18 mobile 模块](#418-mobile-模块)
  - [4.19 paddle 目标检测模块](#419-paddle-目标检测模块)
  - [4.21 VPN 模块](#421-vpn-模块)
  - [4.22 webView 模块](#422-webview-模块)

---

## 一、快速开始

### 安装

1. 通过 **TrollStore** 安装 TrollAutoTouch.ipa
2. 打开应用，脚本文件存放在 `/var/mobile/Media/svip/` 目录下
3. 将 `.tas`（DSL）或 `.lua`（Lua）脚本文件放入该目录即可在应用中执行

### 脚本类型

| 类型 | 文件后缀 | 说明 | 状态 |
|------|----------|------|------|
| DSL 行式脚本 | `.tas` | 每行一条命令，简洁直观 | ✅ 已实现 |
| Lua 脚本 | `.lua` | 完整 Lua 5.4 语法，功能强大 | ✅ 已实现（需集成 Lua 5.4 源码） |

### 注意事项

- DSL 脚本中，带空格或特殊字符的参数需用引号包裹，例如 `tap "720 360"`
- Lua 脚本中，`touch.tap(x, y)` 的坐标单位为逻辑像素（point），非物理像素
- 默认单位：坐标为像素值，延时为毫秒
- 颜色值使用十六进制表示，如 `0xff0000`（红色）

---

## 二、DSL 行式脚本引擎（✅ 全部已实现）

DSL 脚本以 `.tas` 为扩展名，每行一条命令，格式为 `命令 参数1 参数2 ...`。所有命令均由 `TSScriptEngine` 解析执行。

### 2.1 触控操作

#### tap / touch — 点击

```
tap x y [延时]
touch x y [延时]
```

- `x, y`：整数，点击坐标
- `延时`：整数，可选，按下到释放的间隔（毫秒），默认 50ms

示例：
```
tap 200 300
tap 200 300 100
touch 500 700
```

#### swipe — 滑动

```
swipe x1 y1 x2 y2 [持续时间] [步数]
```

- `x1, y1`：起始坐标
- `x2, y2`：结束坐标
- `持续时间`：整数，可选，滑动总时长（毫秒），默认 300
- `步数`：整数，可选，滑动分段步数，自动计算

示例：
```
swipe 100 500 100 200
swipe 100 500 300 200 500
```

#### longtap / holdtap — 长按

```
longtap x y [持续时间]
holdtap x y [持续时间]
```

- `持续时间`：整数，可选，长按毫秒数，默认 1000

示例：
```
longtap 300 400
longtap 300 400 2000
```

#### hold / touchdown — 按下（不释放）

```
hold x y [触摸ID]
touchdown x y [触摸ID]
```

- `触摸ID`：整数，可选，多点触控标识，默认 0

示例：
```
hold 300 400
hold 500 400 1
```

#### release / touchup — 释放

```
release x y [触摸ID]
touchup x y [触摸ID]
```

示例：
```
release 300 400
release 500 400 1
```

#### move / touchmove — 移动（已按下状态下）

```
move x y [触摸ID]
touchmove x y [触摸ID]
```

示例：
```
move 350 400
move 550 400 1
```

#### stroke / touchstroke — 路径绘制（多点滑动）

```
stroke x1 y1 x2 y2 ... [持续时间]
touchstroke x1 y1 x2 y2 ... [持续时间]
```

- 参数成对出现，至少 2 对坐标
- `持续时间`：整数，可选，总时长（毫秒），默认 500

示例：
```
stroke 100 100 200 200 300 150 400 200
stroke 100 100 200 200 300 150 500 800
```

---

### 2.2 颜色识别

#### findcolor / findcs — 单点找色

```
findcolor 颜色值 [x y w h] [相似度]
findcs 颜色值 [x y w h] [相似度]
```

- `颜色值`：十六进制整数，如 `0xff0000`
- `x y w h`：可选，查找区域（x, y, 宽度, 高度），默认全屏
- `相似度`：浮点数，可选，0.0~1.0，默认 0.9

返回找到的坐标 (x, y)，未找到则返回 (-1, -1)。

示例：
```
findcolor 0xff0000
findcolor 0x00ff00 0 0 400 800 0.95
```

#### findmcs — 多点找色

```
findmcs 主颜色 [x y w h] dx1 dy1 颜色1 dx2 dy2 颜色2 ... [主相似度] [偏移相似度]
```

- `主颜色`：主查找点的颜色值
- `dx1 dy1 颜色1`：第 1 个偏移点的相对坐标和颜色
- 可指定多个偏移点
- `主相似度`：可选，默认 0.9
- `偏移相似度`：可选，默认同主相似度

示例：
```
findmcs 0xff0000 0 0 400 800 10 5 0xffffff 20 -5 0x000000 0.9 0.85
```

#### getcolor — 取色

```
getcolor x y
```

返回该坐标点的颜色值（整数）。

示例：
```
getcolor 100 200
```

#### keep / keepscreen — 缓存当前屏幕

```
keep
keepscreen
```

将当前屏幕截图缓存到内存，后续找色/找图操作在缓存上进行，避免重复截屏。

#### unkeep / unkeepscreen — 释放屏幕缓存

```
unkeep
unkeepscreen
```

释放屏幕截图缓存。

---

### 2.3 图像识别

#### screenshot / snapshot — 截屏

```
screenshot [路径]
snapshot [路径]
```

- `路径`：可选，保存截图到文件，不提供则仅返回图像数据

返回截图的图像数据。

示例：
```
screenshot /var/mobile/Media/screenshot.png
```

#### findimg / findimage — 找图

```
findimg 模板路径 [相似度] [x y w h]
findimage 模板路径 [相似度] [x y w h]
```

- `模板路径`：图片文件路径（支持 PNG/JPG）
- `相似度`：浮点数，可选，0.0~1.0，默认 0.9
- `x y w h`：可选，查找区域

返回找到的坐标 (x, y)，未找到则返回 (-1, -1)。

示例：
```
findimg /var/mobile/Media/btn.png
findimg /var/mobile/Media/btn.png 0.85 0 0 400 800
```

---

### 2.4 录制与回放

#### record / startrecord — 开始录制

```
record [文件路径]
startrecord [文件路径]
```

启动触控录制，后续触摸操作将被记录。

示例：
```
record /var/mobile/Media/recording.json
```

#### stoprecord — 停止录制

```
stoprecord
```

停止触控录制并保存记录文件。

#### playrecord / replay — 回放

```
playrecord 文件路径 [速度倍率]
replay 文件路径 [速度倍率]
```

- `速度倍率`：浮点数，可选，默认 1.0

示例：
```
playrecord /var/mobile/Media/recording.json
playrecord /var/mobile/Media/recording.json 2.0
```

#### stopreplay — 停止回放

```
stopreplay
```

---

### 2.5 UI 节点操作

#### apptree — 获取 UI 树

```
apptree
```

获取前台应用的完整视图层级树，以 JSON 格式返回。每个节点包含 class、frame（x,y,width,height）、text/label、alpha、hidden 等属性。

#### findnode — 查找节点

```
findnode 匹配条件
```

在 UI 树中查找满足条件的节点。匹配条件支持：
- 类名匹配：`className:UIButton`
- 文本匹配：`text:登录`
- 标签匹配：`label:Login`
- 坐标范围：`frame:x,y,w,h`

返回匹配节点的信息列表。

示例：
```
findnode text:登录
findnode className:UIButton
```

#### tapnode — 点击节点

```
tapnode 节点地址
```

直接点击指定内存地址的 UI 节点。

示例：
```
tapnode 0x1234567890
```

---

### 2.6 设备与屏幕

#### deviceinfo — 设备信息

```
deviceinfo
```

以 JSON 格式返回设备名称、型号、系统版本等信息。

#### screensize — 屏幕尺寸

```
screensize
```

返回屏幕尺寸（宽度 高度），单位为逻辑像素。

---

### 2.7 OCR 文字识别

基于 Apple Vision Framework 实现，无需额外模型文件。

#### ocr — OCR 文字识别

```
ocr [语言] [x y w h]
```

- `语言`：可选，ISO 语言代码，默认 `zh-Hans`（简体中文）
  - `en-US`：美式英语
  - `zh-Hans`：简体中文
  - `zh-Hant`：繁体中文
  - `ja-JP`：日语
  - `ko-KR`：韩语
  - 更多语言参考 Apple Vision 文档
- `x y w h`：可选，识别区域，默认全屏

返回包含文字和坐标的识别结果数组。

示例：
```
ocr
ocr zh-Hans
ocr en-US 0 0 400 800
```

#### findtext — 查找文字

```
findtext 文字 [语言] [x y w h]
```

全屏（或指定区域）搜索指定文字，返回其位置坐标。

示例：
```
findtext 登录
findtext Login en-US 0 0 400 800
```

#### taptext — 点击文字

```
taptext 文字 [语言] [x y w h]
```

自动查找指定文字并点击其位置。

示例：
```
taptext 登录
taptext 确认 zh-Hans 0 0 400 600
```

#### ocrtext — 区域 OCR

```
ocrtext x y w h [语言]
```

对指定区域进行 OCR 识别，返回该区域内的所有文字。

示例：
```
ocrtext 0 0 400 600
ocrtext 100 200 300 100 en-US
```

---

### 2.8 Web 远程控制

#### server / webserver — 启动 Web 服务器

```
server [端口]
webserver [端口]
```

- `端口`：整数，可选，默认 8080

启动内嵌 HTTP/WebSocket 服务器，可通过浏览器远程查看屏幕和控制设备。功能包括：
- MJPEG 屏幕实时流
- 触摸事件远程中继
- Web 控制面板

浏览器访问 `http://设备IP:端口` 即可使用。

示例：
```
server
server 8888
```

#### serverstop — 停止 Web 服务器

```
serverstop
```

停止正在运行的 Web 远程控制服务器。

---

### 2.9 Shell 命令执行

#### exec / shell — 执行 Shell 命令

```
exec shell命令
shell shell命令
```

在设备上执行 Shell 命令并返回输出结果。

示例：
```
exec ls /var/mobile/Media
exec whoami
shell id
```

---

### 2.10 文件操作

#### filedir / filelist — 列出目录

```
filedir 目录路径
filelist 目录路径
```

返回目录中的文件和子目录列表。

示例：
```
filedir /var/mobile/Media
filelist /var/mobile/Media/svip
```

#### fileread / fget — 读取文件

```
fileread 文件路径
fget 文件路径
```

以文本形式读取并返回文件全部内容。

示例：
```
fileread /var/mobile/Media/data.txt
```

#### filewrite / fput — 写入文件

```
filewrite 文件路径 文本内容
fput 文件路径 文本内容
```

覆盖写入文本内容到文件。

示例：
```
filewrite /var/mobile/Media/data.txt "hello world"
```

#### filedelete / frm — 删除文件

```
filedelete 文件路径
frm 文件路径
```

删除指定文件。

示例：
```
filedelete /var/mobile/Media/temp.txt
```

#### filecopy / fcp — 复制文件

```
filecopy 源路径 目标路径
fcp 源路径 目标路径
```

复制文件到目标位置。

示例：
```
filecopy /var/mobile/Media/a.txt /var/mobile/Media/b.txt
```

---

### 2.11 网络操作

#### ip / myip — 获取本机 IP

```
ip
myip
```

返回设备当前的 WiFi IP 地址。

#### httpget — HTTP GET 请求

```
httpget URL
```

发送 GET 请求并返回响应体文本。

示例：
```
httpget https://httpbin.org/get
```

#### httppost — HTTP POST 请求

```
httppost URL 请求体
```

发送 POST 请求并返回响应体文本。

示例：
```
httppost https://httpbin.org/post "key=value"
```

---

### 2.12 系统信息

#### disk / diskinfo — 磁盘信息

```
disk
diskinfo
```

以 JSON 格式返回磁盘总容量、已用容量、可用容量等信息。

#### memory / meminfo — 内存信息

```
memory
meminfo
```

以 JSON 格式返回系统总内存、已用内存、可用内存等信息。

#### cpu / cpuinfo — CPU 信息

```
cpu
cpuinfo
```

以 JSON 格式返回 CPU 使用率等信息。

#### uptime — 系统运行时间

```
uptime
```

返回系统自启动以来的运行时间。

---

### 2.13 文本输入

#### inputtext / sendtext — 输入文本

```
inputtext 文本内容
sendtext 文本内容
```

向当前焦点控件模拟键盘输入文本。

示例：
```
inputtext HelloWorld
sendtext "你好世界"
```

---

### 2.14 流程控制

#### sleep — 延时

```
sleep 毫秒数
```

暂停脚本执行指定毫秒数。

示例：
```
sleep 1000
sleep 500
```

#### loop — 开始循环

```
loop [循环次数]
```

- `循环次数`：整数，可选，不提供则无限循环

开始一个循环块。

示例：
```
loop
loop 10
```

#### endloop — 结束循环

```
endloop
```

标记循环块结束。

DSL 循环示例：
```
loop 3
tap 100 200
sleep 500
tap 300 400
sleep 500
endloop
```

#### log / print — 日志输出

```
log 内容
print 内容
```

输出日志到控制台和日志文件。

示例：
```
log 脚本开始执行
print "当前步骤：%d" 1
```

#### run / call — 运行子脚本

```
run 脚本路径
call 脚本路径
```

调用并执行另一个 DSL 或 Lua 脚本。

示例：
```
run /var/mobile/Media/svip/sub.tas
call /var/mobile/Media/svip/helper.lua
```

### 2.15 应用管理

基于 `TSAppManager` 模块（SpringBoardServices / LSApplicationWorkspace 私有框架），实现应用安装、卸载、启动、终止等操作。

#### frontbid / frontapp — 获取前台应用

```
frontbid
frontapp
```

返回当前前台应用的 Bundle ID 和进程 PID。

示例：
```
frontbid
frontapp
```

#### applist / apps — 列出已安装应用

```
applist [过滤关键词]
apps [过滤关键词]
```

列出设备上所有用户安装的应用（自动过滤系统应用），可选按名称/BundleID筛选。

示例：
```
applist
apps 微信
applist com.tencent
```

#### appinfo — 应用详细信息

```
appinfo bundleId
```

获取指定应用的名称、版本、安装路径、数据路径、运行状态等信息。

示例：
```
appinfo com.tencent.xin
```

#### openapp / launchapp — 启动应用

```
openapp bundleId
launchapp bundleId
```

启动指定 Bundle ID 的应用。

示例：
```
openapp com.tencent.xin
launchapp com.apple.Preferences
```

#### closeapp / killapp — 关闭应用

```
closeapp bundleId
killapp bundleId
```

终止指定应用的进程（先发 SIGTERM，500ms 后仍未退出则 SIGKILL）。

示例：
```
closeapp com.tencent.xin
```

#### uninstall / rmapp — 卸载应用

```
uninstall bundleId
rmapp bundleId
```

卸载指定 Bundle ID 的应用。

示例：
```
uninstall com.example.test
```

#### instapp / installipa — 安装 IPA

```
instapp IPA路径
installipa IPA路径
```

安装指定路径的 IPA 文件。

示例：
```
instapp /var/mobile/Media/app.ipa
```

#### openurl — 打开 URL

```
openurl "URL"
```

在前台应用中打开指定的 URL（http/https/scheme 等）。

示例：
```
openurl https://www.apple.com
openurl "weixin://"
```

### 2.16 文件操作扩展

在基础文件操作之上，提供条件检查、目录创建和文件追加能力。

#### fexists — 检查文件/目录是否存在

```
fexists path
```

返回 YES/NO，不存在时会标记为失败。

示例：
```
fexists /var/mobile/Media/svip/config.lua
```

#### fsize — 获取文件大小

```
fsize path
```

返回文件字节数及 KB 换算。

示例：
```
fsize /var/mobile/Media/svip/capture.png
```

#### fmkdir — 创建目录

```
fmkdir path
```

递归创建目录（含中间目录）。

示例：
```
fmkdir /var/mobile/Media/svip/logs
```

#### fappend — 追加文本到文件

```
fappend path "text"
```

在文件末尾追加一行文本，用于写日志等场景。

示例：
```
fappend /var/mobile/Media/svip/log.txt "任务完成"
```

#### fisdir — 判断是否为目录

```
fisdir path
```

返回 YES — 是目录 / NO — 不是目录。

---

### 2.17 剪贴板

基于 `UIPasteboard` 系统 API。

#### clipboard / pbwrite — 写入剪贴板

```
clipboard "文本内容"
pbwrite "文本内容"
```

示例：
```
clipboard "已复制"
```

#### clipboardread / pbread — 读取剪贴板

```
clipboardread
pbread
```

读取并输出剪贴板中的文本内容。

#### clipboardclear / pbclear — 清空剪贴板

```
clipboardclear
pbclear
```

---

### 2.18 Plist 操作

基于 `NSDictionary` 的 Plist 读写能力。

#### plistread — 读取 Plist 文件

```
plistread path
```

读取并逐键输出 Plist 内容。

示例：
```
plistread /var/mobile/Library/Preferences/com.apple.Preferences.plist
```

#### plistwrite — 写入 Plist 键值

```
plistwrite path key value
```

向 Plist 文件写入/修改一个键。value 会自动解析为数字（如果可能）或保持字符串。

示例：
```
plistwrite /var/mobile/Media/svip/test.plist mykey myvalue
```

---

### 2.19 按键控制

基于 `TSKeyboardInjector`（GSEvent 私有 API 动态加载），模拟硬件按键。

#### key — 硬件按键

```
key home|lock|volumeup|volumedown|home2x
```

| 动作 | 效果 |
|------|------|
| `home` | 按 Home 键 |
| `lock` | 锁屏（电源键） |
| `volumeup` / `volup` | 音量+ |
| `volumedown` / `voldown` | 音量- |
| `home2x` | 双击 Home（打开多任务） |

示例：
```
key home
key lock
key volumeup
key home2x
```

> 注：锁屏键优先使用 `GSEventLockDevice` API，不可用时回退到 HID 按键事件。

---

### 2.20 加密与哈希

基于 `CommonCrypto` 框架。

#### md5 — 计算 MD5

```
md5 "string"
md5 @filepath
```

计算字符串或文件的 MD5 值（小写十六进制）。

示例：
```
md5 "hello"
md5 @/var/mobile/Media/svip/capture.png
```

#### sha256 — 计算 SHA256

```
sha256 "string"
sha256 @filepath
```

计算字符串或文件的 SHA256 值（小写十六进制）。

#### base64encode / b64enc — Base64 编码

```
base64encode "text"
b64enc "text"
```

#### base64decode / b64dec — Base64 解码

```
base64decode "base64string"
b64dec "base64string"
```

---

### 2.21 字符串工具

#### trim — 去除首尾空白

```
trim "  hello world  "
```

去除开头和结尾的空白字符（空格、换行、制表符）。

#### split — 分割字符串

```
split "a,b,c" ,
```

按分隔符分割字符串并逐行输出。

#### random — 随机数

```
random min max
```

生成 min~max 范围内的随机整数。

示例：
```
random 1 100
```

---

## 三、Lua 桥接模块（✅ 大部分已实现）

Lua 桥接模块通过 `TSLuaBridge` 将原生功能暴露给 Lua 脚本。需要在工程中集成 Lua 5.4 源码并激活桥接代码（默认以 Stub 形式编译）。

### 3.1 touch 模块

#### touch.tap(x, y [, duration])

点击屏幕坐标。

```lua
touch.tap(200, 300)           -- 默认 50ms 点击
touch.tap(200, 300, 100)      -- 100ms 点击
```

#### touch.down([index,] x, y)

在指定坐标按下手指。

```lua
touch.down(0, 300, 400)       -- 手指 0 在 (300,400) 按下
touch.down(300, 400)          -- 默认 index=0
```

#### touch.move([index,] x, y)

已按下状态下移动手指。

```lua
touch.move(0, 350, 400)
```

#### touch.up([index,] x, y)

在指定坐标释放手指。

```lua
touch.up(0, 350, 400)
```

#### touch.swipe(x1, y1, x2, y2 [, duration, steps])

从 (x1,y1) 滑动到 (x2,y2)。

```lua
touch.swipe(100, 500, 100, 200)           -- 默认 300ms
touch.swipe(100, 500, 300, 200, 500)      -- 500ms
```

#### touch.stroke(x1, y1, x2, y2, ...)

多点触控轨迹，参数成对出现。

```lua
touch.stroke(100, 100, 200, 200, 300, 150)
```

---

### 3.2 screen 模块

#### screen.capture()

截取全屏，返回包含 pixels、width、height 的 table。

```lua
local img = screen.capture()
print(img.width, img.height)
```

#### screen.getColor(x, y)

获取指定坐标的颜色值（整数）。

```lua
local color = screen.getColor(100, 200)
if color == 0xffffff then
    print("白色")
end
```

#### screen.findColor(color, x, y, w, h [, sim])

在指定区域查找颜色。

```lua
local x, y = screen.findColor(0xff0000, 0, 0, 400, 800, 0.9)
if x then
    touch.tap(x, y)
end
```

#### screen.findColors(mainColor, x, y, w, h, offsets, [, sim, offSim])

多点找色。`offsets` 为偏移点数组：

```lua
local x, y = screen.findColors(0xff0000, 0, 0, 400, 800, {
    {x=10, y=5, color=0xffffff},
    {x=20, y=-5, color=0x000000}
}, 0.9, 0.85)
```

---

### 3.3 sys 模块

#### sys.msleep(ms)

毫秒级延时。

```lua
sys.msleep(500)    -- 延时 500 毫秒
```

#### sys.sleep(seconds)

秒级延时。

```lua
sys.sleep(1)       -- 延时 1 秒
```

#### sys.toast(message)

显示 Toast 提示。

```lua
sys.toast("操作完成")
```

#### sys.info()

返回设备信息 table。

```lua
local info = sys.info()
print(info.name, info.systemVersion, info.width, info.height)
```

#### sys.getScreenSize()

返回屏幕宽高。

```lua
local w, h = sys.getScreenSize()
```

#### sys.getBattery()

返回电量和充电状态。

```lua
local level, state = sys.getBattery()
```

#### sys.getIP()

返回当前 WiFi IP 地址。

```lua
local ip = sys.getIP()
print(ip)
```

---

### 3.4 device 模块

#### device.info()

返回设备信息 table。

```lua
local info = device.info()
print(info.name, info.model, info.systemVersion, info.udid)
```

---

### 3.5 json 模块

#### json.encode(table)

简单 Lua table 转 JSON 字符串。

```lua
local jsonStr = json.encode({key="value", num=123})
```

#### json.decode(jsonString)

将 JSON 字符串解析为 Lua table（基于 NSJSONSerialization）。

```lua
local obj = json.decode('{"name":"test","version":2,"items":[1,2,3]}')
print(obj.name, obj.items[1])
```

---

### 3.6 appNode 模块

#### appNode.info()

遍历前台应用视图树，返回包含完整节点信息的嵌套 table。

```lua
local tree = appNode.info()
-- tree.subviews[1].class, .text, .x, .y, .width, .height, .alpha, .isHidden 等
```

---

### 3.7 app 模块

提供应用管理功能：前台应用检测、安装/卸载、进程管理、URL 打开。

#### app.frontBid()

获取前台应用的 Bundle ID 和 PID，返回两个值。

```lua
local bid, pid = app.frontBid()
print("前台应用:", bid, "PID:", pid)
```

#### app.isInstalled(bundleId)

检查指定应用是否已安装。

```lua
if app.isInstalled("com.tencent.xin") then
    app.open("com.tencent.xin")
end
```

#### app.isRunning(bundleId)

检查指定应用是否正在运行。

```lua
if app.isRunning("com.tencent.xin") then
    print("微信正在运行")
end
```

#### app.info(bundleId)

返回应用信息 table：`bundleId`, `name`, `version`, `bundlePath`, `dataPath`, `pid`。

```lua
local info = app.info("com.tencent.xin")
print(info.name, info.version, info.dataPath)
```

#### app.open(bundleId)

启动指定应用。

```lua
app.open("com.tencent.xin")
app.open("com.apple.Preferences")
```

#### app.close(bundleId)

强制终止指定应用的进程。

```lua
app.close("com.tencent.xin")
```

#### app.uninstall(bundleId)

卸载指定应用。

```lua
app.uninstall("com.example.test")
```

#### app.install(ipaPath)

安装指定路径的 IPA 文件。

```lua
app.install("/var/mobile/Media/MyApp.ipa")
```

#### app.openUrl(urlString)

在前台应用中打开 URL。

```lua
app.openUrl("https://www.apple.com")
app.openUrl("weixin://")
```

#### app.inputText(text)

向当前焦点控件输入文本。

```lua
app.inputText("Hello World")
```

---

### 3.8 pasteboard 模块

剪贴板操作。

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `pasteboard.read()` | — | string | 读取剪贴板文本 |
| `pasteboard.write(text)` | string | bool | 写入文本到剪贴板 |
| `pasteboard.clear()` | — | bool | 清空剪贴板 |
| `pasteboard.has()` | — | bool | 是否有文本内容 |

```lua
pasteboard.write("Hello Clipboard")
local text = pasteboard.read()
print(text)
pasteboard.clear()
```

---

### 3.9 plist 模块

Property List 文件的读写。

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `plist.read(path)` | string | table/nil | 读取 plist 文件为 Lua table |
| `plist.write(path, data)` | string, table | bool | 将 table 写入 plist 文件 |

```lua
local info = plist.read("/var/mobile/Library/Preferences/com.apple.Preferences.plist")
print(info.DeviceName)

plist.write("/var/mobile/Media/svip/settings.plist", {
    key1 = "value1",
    score = 100,
    enabled = true
})
```

---

### 3.10 file 模块

文件系统操作。

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `file.exists(path)` | string | bool | 文件/目录是否存在 |
| `file.size(path)` | string | int | 文件大小（字节） |
| `file.isDir(path)` | string | bool | 是否为目录 |
| `file.reads(path)` | string | string | 读取文本文件 |
| `file.writes(path, content)` | string, string | bool | 写入文本文件 |
| `file.mkdir(path)` | string | bool | 创建目录 |
| `file.delete(path)` | string | bool | 删除文件/目录 |
| `file.list(path)` | string | table | 列出目录内容 |

```lua
if file.exists("/var/mobile/Media/svip/config.json") then
    local s = file.reads("/var/mobile/Media/svip/config.json")
    print("配置:", s)
end

file.mkdir("/var/mobile/Media/svip/backup")
for _, name in ipairs(file.list("/var/mobile/Media/svip")) do
    print(name)
end
```

---

### 3.11 key 模块

硬件按键模拟。

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `key.press(action)` | "home"/"lock"/"volumeup"/"volumedown"/"home2x" | bool | 模拟按键按下 |
| `key.sendText(text)` | string | bool | 注入键盘文本 |

```lua
key.press("home")
key.press("lock")
key.sendText("Hello from Lua!")
```

---

### 3.12 str 模块

字符串工具与加密哈希。

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `str.md5(s)` | string | string | MD5 哈希（小写十六进制） |
| `str.sha256(s)` | string | string | SHA256 哈希 |
| `str.base64Encode(s)` | string | string | Base64 编码 |
| `str.base64Decode(s)` | string | string | Base64 解码 |
| `str.trim(s)` | string | string | 去除首尾空白 |
| `str.split(s, sep)` | string, string | table | 按分隔符分割 |
| `str.random(lo, hi)` | int, int | int | 生成随机整数 |

```lua
print(str.md5("hello"))
print(str.sha256("hello"))
print(str.base64Encode("hello world"))
print(str.trim("  hello  "))

local parts = str.split("a,b,c", ",")
for i, v in ipairs(parts) do print(v) end

print(str.random(1, 100))
```

---

### 3.13 全局兼容函数

为兼容原版 TrollAutoScript 脚本，以下函数注册为全局 Lua 函数：

| 函数 | 等价调用 | 说明 |
|------|----------|------|
| `tap(x, y)` | `touch.tap(x, y)` | 点击 |
| `swipe(x1, y1, x2, y2)` | `touch.swipe(x1, y1, x2, y2)` | 滑动 |
| `findColor(c, x, y, w, h)` | `screen.findColor(c, x, y, w, h)` | 找色 |
| `getColor(x, y)` | `screen.getColor(x, y)` | 取色 |
| `mSleep(ms)` | `sys.msleep(ms)` | 毫秒延时 |
| `toast(msg)` | `sys.toast(msg)` | 提示 |
| `snapshot()` | `screen.capture()` | 截屏 |

---

## 四、原版 TrollAutoScript 模块参考（6/22 模块已覆盖）

以下模块是原版 TrollAutoScript 的功能，TrollAutoTouch 尚未实现。部分功能可通过 DSL 命令或 Lua 标准库替代。

### 4.1 图片对象模块

原版提供完整的图片对象操作链：`screen.image()` 返回图片对象，支持链式调用。

| 函数 | 说明 | 替代方案 |
|------|------|----------|
| `img:saveToJpegFile(path, quality)` | 保存为 JPG | `screenshot path` (DSL) |
| `img:saveToPngFile(path)` | 保存为 PNG | `screenshot path` (DSL) |
| `img:saveToAlbum()` | 保存到相册 | ❌ 无直接替代 |
| `img:turnRight()` | 右旋转 90 度 | ❌ |
| `img:turnLeft()` | 左旋转 90 度 | ❌ |
| `img:findColors(offsets)` | 图片多点找色 | `findmcs` (DSL) |
| `img:isColors(offsets)` | 图片多点比色 | ❌ |
| `img:findImage(tpl, sim)` | 图中找图 | `findimg` (DSL) |
| `img:size()` | 图片尺寸 | ❌ |
| `img:jpegData()` | JPEG 数据 | ❌ |
| `img:pngData()` | PNG 数据 | ❌ |
| `img:getColor(x, y)` | 图片取色 | `getcolor` (DSL) |
| `img:getColorRGB(x, y)` | 图片取 RGB | ❌ |
| `img:visionOcr(lang, rect)` | Vision OCR | `ocr` (DSL) |
| `img:binarization(colors)` | 二值化 | ❌ |
| `img:cvFindImage(tpl, sim)` | OpenCV 找图 | `findimg` (DSL) |
| `img:cvBinarization(thresh)` | OpenCV 二值化 | ❌ |
| `img:paddleOcr(lang, rect)` | Paddle OCR | `ocr` (DSL, 基于 Vision) |

### 4.2 屏幕模块

| 函数 | 说明 | 替代方案 |
|------|------|----------|
| `screen.visionOcr(lang, rect)` | 屏幕 Vision OCR | `ocr` (DSL) |
| `screen.paddleOcr(lang, rect)` | 屏幕 Paddle OCR | `ocr` (DSL) |
| `screen.cvFindImage(tpl, sim, rect)` | OpenCV 屏幕找图 | `findimg` (DSL) |
| `screen.findColors(main, rect, offsets)` | 屏幕多点找色 | `findmcs` (DSL) |
| `screen.findImage(tpl, sim, rect)` | 屏幕找图 | `findimg` (DSL) |
| `screen.getColor(x, y)` | 屏幕取色 | `getcolor` (DSL) |
| `screen.getColorRGB(x, y)` | 屏幕取 RGB | ❌ |
| `screen.init(orientation)` | 初始化屏幕方向 (0=home在下 1=home在右 2=home在左) | ✅ `screen.init()` |
| `screen.keep()` | 保持屏幕 | `keep` (DSL) |
| `screen.unkeep()` | 取消保持 | `unkeep` (DSL) |
| `screen.loadImageData(data)` | 从数据加载图片 | ❌ |
| `screen.loadImageFile(path)` | 从文件加载图片 | ❌ |
| `screen.size()` | 屏幕尺寸 | `screensize` (DSL) |
| `TomatoOCR` | TomatoOCR 引擎 | `ocr` (DSL, 基于 Vision) |

### 4.3 应用模块

> ✅ 已在 TrollAutoTouch 中实现。DSL 命令参见 [2.15 应用管理](#215-应用管理)，Lua API 参见 [3.7 app 模块](#37-app-模块)。

| 函数 | 状态 | 说明 |
|------|------|------|
| `app.frontBid()` | ✅ `app.frontBid()` | 前台应用 Bundle ID |
| `app.frontPid()` | ✅ `app.frontBid()` (返回两个值) | 前台应用 PID |
| `app.openApp(bundleId)` | ✅ `app.open(bundleId)` | 启动应用 |
| `app.close(bundleId)` | ✅ `app.close(bundleId)` | 退出应用 |
| `app.isInstalled(bundleId)` | ✅ | 是否已安装 |
| `app.isRuning(bundleId)` | ✅ `app.isRunning(bundleId)` | 是否正在运行 |
| `app.uninstall(bundleId)` | ✅ | 卸载应用 |
| `app.installIpa(path)` | ✅ `app.install(path)` | 安装 IPA |
| `app.openUrl(url)` | ✅ | 前台打开 URL |
| `app.inputText(text)` | ✅ | 输入文本 |
| `app.info(bundleId)` | ✅ | 应用信息 (name/version/path/pid) |
| `app.groupInfo(bundleId)` | ❌ | 应用分组信息 |
| `app.iconData(bundleId)` | ❌ | 应用图标数据 |
| `app.installPath(bundleId)` | ✅ (见 `app.info()`) | 应用安装路径 |
| `app.localizedName(bundleId)` | ✅ (见 `app.info()`) | 应用本地化名称 |
| `app.dataPath(bundleId)` | ✅ (见 `app.info()`) | 应用沙盒路径 |
| `app.version(bundleId)` | ✅ (见 `app.info()`) | 应用版本 |

> 注意：Lua 模块名称为 `app` 而非原版的 `app`，API 命名略有差异（如原版 `app.installIpa` → `app.install`）。DSL 中可通过 `applist`/`appinfo`/`openapp`/`closeapp` 等命令使用全部功能。

### 4.4 扩展 string 库

> ✅ 核心功能已通过 DSL 和 Lua `str.*` 模块实现。参见 [2.20 加密与哈希](#220-加密与哈希)、[2.21 字符串工具](#221-字符串工具)、[3.12 str 模块](#312-str-模块)。

| 函数 | 说明 |
|------|------|
| `string.fromHex(str)` | 十六进制转字符串 |
| `string.split(str, sep)` | 分割文本 |
| `string.atrim(str)` | 删除全部空字符 |
| `string.rtrim(str)` | 删除尾空字符 |
| `string.trim(str)` | 删除首尾空字符 |
| `string.ltrim(str)` | 删除首空字符 |
| `string.toHex(str)` | 字符串转十六进制 |
| `string.md5(str)` | MD5 哈希 |
| `string.sha1(str)` | SHA1 哈希 |
| `string.sha256(str)` | SHA256 哈希 |
| `string.sha512(str)` | SHA512 哈希 |
| `string.isUpper(str)` | 是否大写字母 |
| `string.isLetter(str)` | 是否字母 |
| `string.isLower(str)` | 是否小写字母 |
| `string.isNumber(str)` | 是否数字 |
| `string.isInteger(str)` | 是否整数 |
| `string.isChinese(str)` | 是否汉字 |
| `string.isEmail(str)` | 是否邮箱 |
| `string.isLink(str)` | 是否 URL |
| `string.toPinYin(str)` | 汉字转拼音 |
| `string.stripUtf8Bom(str)` | 清除 UTF-8 BOM |
| `string.random(chars, count)` | 随机字符串 |
| `string.chars(str)` | 逐字分割 |
| `string.fromGbk(str)` | GBK 转 UTF-8 |
| `string.aes128Encrypt(str, key)` | AES-128 加密 |
| `string.ase128Decrypt(str, key)` | AES-128 解密 |
| `string.base64Encode(str)` | Base64 编码 |
| `string.base64Decode(str)` | Base64 解码 |
| `string.fromUnicode(str)` | Unicode 转 UTF-8 |

### 4.5 文件操作模块（Lua API）

> ✅ 已实现。参见 [2.10 文件操作](#210-文件操作)、[2.16 文件操作扩展](#216-文件操作扩展)、[3.10 file 模块](#310-file-模块)。

原版通过 `file.*` 命名空间提供丰富文件操作，TrollAutoTouch 已通过 DSL 命令和 Lua `file.*` 模块实现大部分功能。

| 函数 | 说明 |
|------|------|
| `file.writes(path, text)` | 写入文本 |
| `file.reads(path)` | 读取全部内容 |
| `file.addText(path, text)` | 追加文本 |
| `file.existe(path)` | 是否存在 |
| `file.size(path)` | 文件大小 |
| `file.list(path)` | 遍历文件夹 |
| `file.getLineText(path, n)` | 获取第 n 行 |
| `file.resetLineText(path, n, text)` | 替换第 n 行 |
| `file.insertLineText(path, n, text)` | 在第 n 行插入 |
| `file.lineCount(path)` | 总行数 |
| `file.getLines(path)` | 获取所有行 |
| `file.md5(path)` | 文件 MD5 |

### 4.6 日志视图模块

原版提供可悬浮显示的日志窗口。

| 函数 | 说明 |
|------|------|
| `logWindow.init()` | 创建日志窗口 |
| `:addLog(text)` | 添加日志条目 |
| `:release()` | 释放窗口 |

### 4.7 按键模块

> ✅ 已实现。参见 [2.19 按键控制](#219-按键控制)、[3.11 key 模块](#311-key-模块)。

原版支持模拟物理按键，TrollAutoTouch 已通过 `TSKeyboardInjector`（GSEvent）实现 Home/Lock/VolumeUp/VolumeDown/Home2x 及文本输入。

| 函数 | 说明 |
|------|------|
| `key.up(keyCode)` | 按键抬起 |
| `key.down(keyCode)` | 按键按下 |
| `key.press(keyCode)` | 按一下按键 |
| `key.sendText(text)` | 模拟输入文本 |
| `key.clear()` | 清空输入 |
| `key.inputText(text)` | 输入文本（已废弃） |

### 4.8 触摸模块（原版）

原版触摸模块支持链式调用和更多参数。TrollAutoTouch 的 Lua `touch.*` 和 DSL `tap`/`swipe` 已覆盖核心功能，但不支持以下特性：

| 函数 | 说明 |
|------|------|
| `:radius(r)` | 触摸半径（3D Touch） |
| `:press(p)` | 触摸压力（3D Touch） |
| `:setpDelay(ms)` | 设置滑动步长延时 |
| `:msleep(ms)` | 触摸链延时 |

### 4.9 清理模块

| 函数 | 说明 |
|------|------|
| `clear.allPhotos()` | 清理所有相册 |
| `clear.allKeychain()` | 清理所有钥匙串 |
| `clear.keychain(bundleId)` | 清理指定 APP 钥匙串 |
| `clear.pasteboard()` | 清理粘贴板 |
| `clear.appData(bundleId)` | 清理 APP 数据 |
| `clear.idfav()` | 清理 IDFA/IDFV |
| `clear.safariCookies()` | 清理 Safari Cookies |

### 4.10 剪贴板模块

> ✅ 已实现。参见 [2.17 剪贴板](#217-剪贴板)、[3.8 pasteboard 模块](#38-pasteboard-模块)。

| 函数 | 说明 |
|------|------|
| `pasteboard.write(text)` | 写粘贴板 |
| `pasteboard.read()` | 读粘贴板 |

### 4.11 系统模块

| 函数 | 说明 |
|------|------|
| `sys.alert(提示内容, [显示时间], [标题])` | 提示框：`显示时间>0` 自动消失；`=0` 永久显示带"确定"按钮 |
| `sys.alertButtons(提示内容, {按钮...}, [标题], [显示时间])` | 带按钮提示框，返回用户点击的按钮文本；超时返回 `nil` |
| `sys.palyAudio(path)` | 播放音频文件 |
| `sys.availableMemory()` | 系统剩余内存 |
| `sys.processUsedMemory()` | 进程使用内存 |
| `sys.mtime()` | 毫秒级时间戳 |
| `sys.usedMemory()` | 系统已用内存 |
| `sys.osVersion()` | 系统版本信息 |
| `sys.version()` | 应用版本（原版称 TAS 版本） |
| `sys.setFloatBallPoint(x, y)` | 设置悬浮球位置 |

### 4.12 线程模块

| 函数 | 说明 |
|------|------|
| `thread.create(func)` | 创建线程 |
| `thread.timer(ms, func)` | 定时器 |
| `thread.Cancel(tid)` | 取消线程 |
| `thread.state(tid)` | 线程状态 |

### 4.13 节点模块

原版提供两套节点 API（旧版 `node.*` 已废弃，新版 `nodeView.*`）。TrollAutoTouch 通过 DSL 命令 `apptree`/`findnode`/`tapnode` 提供基本节点操作，不支持完整链式 API。

**新版 API (nodeView.*)**：

| 函数 | 说明 |
|------|------|
| `nodeView.info()` | 获取当前 APP 节点信息 |
| `nodeView.infoForMainWindow()` | 获取 keyWindow 节点 |
| `nodeView.windows()` | 获取所有 window 节点 |
| `nodeView.match(rule)` | 节点匹配 |
| `nodeView.matchForMainWindow(rule)` | 在 keyWindow 匹配 |
| `nodeView.forAddres(addr)` | 从内存地址加载 |
| `nodeView.forPoint(x, y)` | 从坐标加载 |
| `nodeView.tap(x, y)` | 触摸一个 APP |
| `:tap()` | 触摸控件 |
| `:frame()` | 矩形属性 |
| `:className()` | 类名 |
| `:superClass()` | 基类名 |
| `:parent()` | 父节点 |
| `:childrens()` | 子节点 |
| `:sibling()` | 兄弟节点 |
| `:text()` | 文本属性 |
| `:label()` | 标签属性 |
| `:info()` | 所有属性 |
| `:addres()` | 地址属性 |
| `:scrollCurrPoint()` | 可滚动控件偏移 |
| `:scrollToPoint(x, y)` | 滚动到指定位置 |

### 4.14 设备模块

| 函数 | 说明 |
|------|------|
| `device.turnOffCellular()` | 停用蜂窝网络 |
| `device.turnOffWiFi()` | 停用 WiFi |
| `device.turnOffFlash()` | 关闭闪光灯 |
| `device.turnOffAirplane()` | 关闭飞行模式 |
| `device.turnOffAssistiveTouch()` | 停用辅助触控 |
| `device.joinWiFi(ssid, pwd)` | 加入 WiFi |
| `device.reduceMotionOn()` | 启用减弱动态效果 |
| `device.invertColorsOn()` | 启用反转颜色 |
| `device.turnOnCellular()` | 启用蜂窝网络 |
| `device.turnOnWiFi()` | 启用 WiFi |
| `device.turnOnFlash()` | 打开闪光灯 |
| `device.turnOnAirplane()` | 打开飞行模式 |
| `device.turnOnAssistiveTouch()` | 启用辅助触控 |
| `device.reduceMotionOff()` | 禁用减弱动态效果 |
| `device.invertColorsOff()` | 禁用反转颜色 |
| `device.isScreenLocked()` | 屏幕是否锁定 |
| `device.lockScreen()` | 锁定屏幕 |
| `device.unlockScreen()` | 解锁屏幕 |
| `device.backlightLevel()` | 当前背光亮度 |
| `device.setBacklightLevel(n)` | 设置背光亮度 |
| `device.name()` | 设备名 |
| `device.setName(name)` | 设置设备名 |
| `device.serialNumber()` | 设备序列号 |
| `device.interMAC()` | 所有网卡 MAC |
| `device.interIPAddres()` | 所有 IP 信息 |
| `device.wifiMac()` | WiFi MAC 地址 |
| `device.type()` | 设备类型 |
| `device.bluetoothMac()` | 蓝牙 MAC |
| `device.udid()` | 设备 UDID |
| `device.isCellularEnabled()` | 蜂窝是否启用 |
| `device.isWiFiEnabled()` | WiFi 是否启用 |
| `device.isAirplaneEnabled()` | 飞行模式是否启用 |
| `device.setVolume(n)` | 设置音量 |
| `device.vibrator()` | 震动 |
| `device.currentSSID()` | 当前 WiFi 名称 |
| `device.removeCurrentWifiPassword()` | 删除当前 WiFi 密码 |

### 4.15 CoreML 模块

| 函数 | 说明 |
|------|------|
| `coreML.init(modelPath)` | 创建 VisionRequest |
| `coreML.compiledModel(modelPath)` | 编译模型 |
| `:forecast(img)` | 预测 |

### 4.16 HTTP 模块

| 函数 | 说明 |
|------|------|
| `http.download(url, path, cb)` | 下载文件 |
| `http.get(url, cb)` | GET 请求 |
| `http.post(url, data, cb)` | POST 请求 |

### 4.17 JSON 模块

TrollAutoTouch 已实现 `json.encode()` 和 `json.decode()`。

| 函数 | 说明 | 状态 |
|------|------|------|
| `json.encode(table)` | JSON 编码 | ✅ 已实现 |
| `json.decode(str)` | JSON 解码 | ✅ 已实现 (NSJSONSerialization) |

### 4.18 mobile 模块

| 函数 | 说明 |
|------|------|
| `mobile.saveVideoFileToAlbum(path)` | 保存视频至相册 |
| `mobile.shutdown()` | 关闭手机 |
| `mobile.reboot()` | 重启手机 |
| `mobile.removeAllPhoneNumber()` | 删除所有通讯录号码 |
| `mobile.addPhoneNumber(name, phone)` | 添加通讯录号码 |
| `mobile.sendMessage(phone, text)` | 发送短信 |
| `mobile.zipCompression(src, dst)` | 压缩文件夹 |
| `mobile.zipDecompress(src, dst)` | 解压文件 |
| `mobile.elements()` | 获取手机页面元素 |
| `mobile.elementsWithText(text)` | 获取包含文本的元素 |
| `mobile.elementsWithTextAtPosition(x, y)` | 获取坐标处文本元素 |

### 4.19 paddle 目标检测模块

| 函数 | 说明 |
|------|------|
| `paddleYolo.init(modelPath)` | 初始化模型 |
| `:forecast(img)` | 预测 |
| `:setThresh(threshold)` | 设置阈值 |
| `:result()` | 获取预测结果 |
| `:resultToImage()` | 获取预测结果图片 |
| `:release()` | 释放模型 |

### 4.20 plist 模块

> ✅ 已实现。参见 [2.18 Plist 操作](#218-plist-操作)、[3.9 plist 模块](#39-plist-模块)。

| 函数 | 说明 |
|------|------|
| `plist.read(path)` | 读 plist |
| `plist.write(path, data)` | 写 plist |

### 4.21 VPN 模块

| 函数 | 说明 |
|------|------|
| `vpn.create(config)` | 创建 VPN 配置 |
| `vpn.delete(id)` | 删除 VPN |
| `vpn.deleteAll()` | 删除所有 VPN |
| `vpn.list()` | 获取所有 VPN 配置 |
| `vpn.select(id)` | 选中 VPN |
| `vpn.selectName()` | 当前选中的 VPN 名称 |
| `vpn.connect()` | 连接当前 VPN |
| `vpn.desConnect()` | 断开连接 |
| `vpn.connectState()` | 连接状态 |

### 4.22 webView 模块

| 函数 | 说明 |
|------|------|
| `webView.init(frame)` | 创建 webView |
| `:eval(js)` | 执行 JS 代码 |
| `:show()` | 显示 |
| `:hidden()` | 隐藏 |
| `:release()` | 释放 |

---

## 附录

### 颜色值说明

颜色值使用十六进制整数表示，格式为 `0xRRGGBB`：

```
0xff0000  — 红色
0x00ff00  — 绿色
0x0000ff  — 蓝色
0xffffff  — 白色
0x000000  — 黑色
0x808080  — 灰色
```

### 坐标系统

- 坐标原点在屏幕**左上角**，x 向右，y 向下
- 单位均为**逻辑像素**（point），非物理像素
- 例如 iPhone 12 Pro 屏幕为 390x844 逻辑像素

### 相似度说明

相似度范围 `0.0 ~ 1.0`，越接近 1.0 匹配越严格：
- `0.9` — 默认值，适用于大多数场景
- `0.95` — 较高精度
- `0.8` — 较低精度，允许更多色差

### 项目结构

```
TrollAutoTouch/
├── Core/                    # 核心原生模块
│   ├── TSHIDEventTouch     # IOKit 触控注入
│   ├── TSScreenCapture     # IOSurface 截屏
│   ├── TSColorFinder       # 颜色查找/匹配
│   ├── TSTemplateMatcher   # 模板匹配（找图）
│   ├── TSTouchSimulator    # 触控模拟
│   ├── TSTouchRecorder     # 触控录制/回放
│   ├── TSNodeInspector     # UI 节点检查
│   ├── TSOCREngine         # Vision OCR 引擎
│   ├── TSDaemonManager     # 后台守护服务
│   ├── TSAppManager         # 应用管理（安装/卸载/启动/终止）
│   └── TSToolExecutor      # Shell/文件/网络/系统工具
├── Script/                  # 脚本引擎
│   ├── TSScriptEngine      # DSL 行式脚本引擎
│   ├── TSHTTPServer         # HTTP/WebSocket 远程控制
│   └── TSLuaBridge          # Lua 5.4 桥接
└── www/                     # Web 控制面板
```

---

> **文档版本**：v2.0（优化整理版）
>
> **来源**：原版 TrollAutoScript 文档（FlowUs 离线导出），经精简、修正和状态标记后重新编排
>
> **说明**：✅ = 已在 TrollAutoTouch 中实现，❌ = 原版功能尚未实现
