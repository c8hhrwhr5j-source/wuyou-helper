# TrollAutoTouch

一个简化版 **巨魔商店(TrollStore) 找色点击自动化应用**，逆向复刻自 `TrollAutoScript.app`（v2.3.6，Bundle ID `com.TrollAutoScript.apple`）的核心机制：**截屏 → 找色 → 系统级触摸注入**，并附带可拖动悬浮控制窗与脚本引擎。

> 本项目用于学习 iOS 自动化与 TrollStore 机制。请勿用于破坏游戏公平性或违反目标应用条款的用途，自行承担使用风险。

---

## 一、逆向结论（原版做了什么）

对上传的 `TrollAutoScript.app` 解包分析得到以下架构，本项目据此复刻核心三件套：

| 原版组件 | 逆向发现 | 本项目对应 |
|---|---|---|
| 主 App `TrollAutoScript` (1.4MB, arm64) | Lua 宿主 + 业务编排 | `AppDelegate` / `ViewController` |
| `HUD/HUDServices` (5MB, 独立进程) | 悬浮窗 + 触摸注入，链接 `BackBoardServices`/`FrontBoard` | `TSHUDWindow`（App 内版） |
| 触摸注入 | `IOHIDEventSystemClientDispatchEvent` + `IOHIDEventCreateDigitizerFingerEventWithQuality`（**系统级 HID 注入**，非 XCTest） | `TSHIDEventTouch` |
| 截屏 | IOSurface 私有权限（`IOSurfaceRootUserClient`/`IOSurfaceAcceleratorClient`） | `TSScreenCapture`（含 keep/unkeep 缓存） |
| 脚本层 | Lua 5.x + 原生 `.so`（cjson/openssl/sqlite3/`TomatoOCR.so`）+ 加密 `.tas` 脚本 | `TSScriptEngine`（20+ 命令 DSL）+ `TSLuaBridge`（完整实现，注释待激活） |
| 触控录制 | 录制触摸事件帧并回放 | `TSTouchRecorder` ✅ |
| 模板匹配 | NCC 图像模板匹配（`findImage`） | `TSTemplateMatcher` ✅ |
| UI 节点 | 递归遍历运行时 UIView 树，支持文本/类名查找点击 | `TSAppNodeInfo` ✅ |
| 设备信息 | 屏幕尺寸/分辨率/模型/系统版本 | `TSDeviceInfo` ✅ |
| Lua 脚本 | 188 个原版 .lua 脚本 + OCR 模型 | `Resources/lua/` ✅ |
| 工具 | `bin/` busybox 工具集 + `npc` 隧道 + `kcaccess` | `TSToolExecutor` (ObjC 原生实现) ✅ |
| 远程控制 | WebRTC + `www/` Web UI | `TSHTTPServer` (HTTP+WS 内嵌服务器) ✅ |
| OCR | PaddleOCR 模型配置已包含 (`res/`) | `TSOCREngine` (Vision Framework) ✅ |
| 守护服务 | HUDServices 独立进程 + 后台保活 | `TSDaemonManager` (音频后台+悬浮窗) ✅ |

**无法"完全"逆向的部分**（已说明）：

- 主二进制与 HUDServices 为 strip 过的机器码，逐行反汇编不现实；
- `.tas` 脚本是加密字节码（魔数 `\xe7TAS`），无法直接还原逻辑；
- 原生 `.so`（OCR/openssl 等）用 Apple Vision / NSURLSession / CommonCrypto 等系统框架等效替换。

本项目复刻的是**机制与能力**，而非逐字节复刻二进制。所有尚未复刻的功能（Web 远程控制、OCR、守护服务、工具集）现已全部实现。

---

## 二、核心机制说明

### 1. 系统级触摸注入（关键）
原版 `HUDServices` 提取到这些 IOKit 私有符号：
```
IOHIDEventSystemClientCreate / DispatchEvent / ScheduleWithRunLoop
IOHIDEventCreateDigitizerEvent
IOHIDEventCreateDigitizerFingerEventWithQuality
IOHIDEventAppendEvent / IOHIDEventSetSenderID
```
做法：构造一个 digitizer（数位板）父事件 + 一根 finger 子事件，设置 `senderID=0x8000000800`（伪装成触屏），通过 `IOHIDEventSystemClientDispatchEvent` 投递给 `backboardd`。这是 ZXTouch / SimulateTouch 同款技术，**系统级、跨 App**，不需要 XCTest 测试宿主。

> 见 `Core/TSHIDEventTouch.m`。私有函数签名随 iOS 版本略有差异，已加注释。

### 2. 截屏
通过 `IOMobileFramebuffer` + `IOSurface` 私有框架读取 GPU 帧缓冲，可截任意 App。失败时回退到 `UIGraphicsImageRenderer`（仅本 App 窗口）。见 `Core/TSScreenCapture.m`。

### 3. 找色
在 RGBA 像素缓冲中按颜色距离（RGB 平方差）匹配，支持单色 `findColor` 与多点 `findMultiColor`。见 `Core/TSColorFinder.m`。

---

## 三、目录结构

```
TrollAutoTouch/
├── project.yml                 # XcodeGen 工程定义
├── build-ipa.sh                # 编译+打包 IPA 脚本
├── _copy_lua.py                # Lua 脚本复制工具
└── TrollAutoTouch/
    ├── Info.plist
    ├── TrollAutoTouch.entitlements   # TrollStore 权限
    ├── main.m / AppDelegate / SceneDelegate
    ├── ViewController.m         # 配置/自检/测试界面
    ├── Core/
    │   ├── TSHIDEventTouch      # IOHIDEvent 触摸注入
    │   ├── TSScreenCapture      # IOSurface 截屏（含 keep/unkeep 缓存）
    │   ├── TSColorFinder        # 找色（单色 + 多点）
    │   ├── TSTouchSimulator     # 高层门面
    │   ├── TSTouchRecorder      # 触摸录制/回放
    │   ├── TSTemplateMatcher    # NCC 图像模板匹配
    │   ├── TSAppNodeInfo        # 运行时 UIView 树遍历
    │   ├── TSDeviceInfo         # 设备信息
    │   ├── TSOCREngine          # OCR 文字识别 (Vision) ✅ NEW
    │   ├── TSDaemonManager      # 后台守护/悬浮窗管理 ✅ NEW
    │   └── TSToolExecutor       # Shell/文件/网络/进程工具 ✅ NEW
    ├── Script/
    │   ├── TSScriptEngine       # DSL 脚本引擎（30+ 命令）
    │   ├── TSLuaBridge          # Lua 5.4 桥接（完整实现注释中）
    │   └── TSHTTPServer         # 内嵌 HTTP/WebSocket 服务器 ✅ NEW
    ├── HUD/
    │   └── TSHUDWindow          # 可拖动悬浮控制窗
    └── Resources/
        ├── demo.script          # 演示脚本
        ├── lua/                 # 188 个原版 .lua 脚本 + 子目录
        ├── www/                 # Web 远程控制 UI ✅ NEW
        ├── lib/                 # 原版 .so 动态库 ✅ NEW
        └── res/                 # OCR 模型配置 ✅ NEW
```

---

## 四、构建与安装

**前提**：macOS + Xcode（建议 15+），已装 TrollStore 的 iOS 设备（iOS 15~16.x，部分 17.x）。

1. 安装 XcodeGen：`brew install xcodegen ldid`
2. 生成工程：
   ```bash
   cd TrollAutoTouch
   xcodegen generate
   ```
3. 编译并打包 IPA：
   ```bash
   ./build-ipa.sh xcode
   # 产物: build/TrollAutoTouch.ipa
   ```
4. 把 `TrollAutoTouch.ipa` 传到设备（AirDrop / 网页 / iCloud）。
5. 在 TrollStore 里打开该 IPA 安装。
6. 首次运行到目标 App，在系统设置里授予相关权限（辅助功能等，按设备提示）。

> 若已有 Xcode 编译好的 `.app`，可直接 `./build-ipa.sh payload path/to/TrollAutoTouch.app` 打包。

---

## 五、用法

### 方式 A：悬浮窗 + 脚本（推荐）
1. 打开 App，点 **显示HUD**，出现可拖动的圆形按钮。
2. 切到目标 App（触摸注入是系统级，切走也能继续）。
3. 点悬浮按钮 → 加载 `demo.script` 并运行；再点一次停止。

### 方式 B：主界面手动测试
- **自检**：验证截屏权限与模块加载。
- **截屏预览**：把当前屏截图显示到预览框，量取目标颜色。
- **测试点击**：在屏幕中心注入一次点击。
- **运行/停止脚本**：同悬浮窗。

### 脚本 DSL（`demo.script`，30+ 命令）
```
# —————— 基本操作 ——————
sleep 500                           # 等待毫秒
tap 200 300                         # 点击 (x, y)
tap 200 300 100                     # 点击 (x, y) 持续 100ms
longtap 200 300 500                 # 长按 (x, y) 500ms
swipe 100 400 400 400 300           # x1 y1 x2 y2 耗时ms
stroke 100 100 200 200 300 100      # 多点轨迹 (x1 y1 x2 y2 ...)

# —————— 多点触摸 ——————
hold 200 300 0                      # 按下手指0在(200,300)
hold 201 301 1                      # 按下手指1在(201,301)
move 250 300 0                      # 移动手指0到(250,300)
release 250 300 0                   # 抬起手指0

# —————— 找色 ——————
keep                                # 缓存当前截屏
findcolor 0xFF0000                  # 整屏找红色
findcolor 0xFF0000 0.9              # 找红色 90% 相似度
findcolor 0xFF0000 0 0 540 960 0.9  # 区域: x y w h sim → $x $y
findmcs 0xFF0000 0.95 10 0 0x00FF00  # 多点找色: 主色 sim dx1 dy1 c1...
unkeep                              # 释放缓存

# —————— 模板匹配 ——————
findimg tpl.png 0.8                 # 匹配模板 80% 相似度
findimg tpl.png 0.8 0 0 540 960     # 区域内匹配 → $x $y

# —————— 图像 ——————
screenshot                          # 保存截屏到本地
screenshot /tmp/my.png              # 指定路径保存
getcolor 200 300                    # 取色点 (x,y) → $color

# —————— 触控录制/回放 ——————
recordrate 10                       # 开始录制 (10ms 采样间隔)
record 10                           # 同上
stoprecord                          # 停止录制
playrecord                          # 回放录制
playrecord 2.0                      # 2x 加速回放
stopplay                            # 停止回放

# —————— UI 节点 ——————
uihierarchy                         # 打印完整 UI 树 JSON
uifind com.apple.Button "确定"      # 查找类名+文本匹配的节点
uitap com.apple.Button "确定"       # 点击匹配的节点

# —————— 信息 ——————
screensize                          # 打印屏幕尺寸
deviceinfo                          # 打印设备信息
log 你好世界                         # 输出日志

# —————— 流程控制 ——————
loop 20                             # 循环 20 次
  tapColor 0xRRGGBB 0.95
  sleep 1000
endloop
if 0xFF0000 0 0 100 100            # 若区域内找到颜色则执行下一行
endif                                # if 块结束

# —————— 脚本调用 ——————
run sub.script                      # 调用子脚本
stop                                # 停止运行

# —————— OCR 文字识别 (Apple Vision) ——————
ocr                                 # 整屏 OCR 识别
ocr 0 0 540 960                     # 区域 OCR
findtext "确认"                      # 查找指定文字坐标
tapText "确认"                       # 查找并点击文字
ocrtext 0 0 500 100                 # 提取区域首条文字

# —————— Web 远程控制 ——————
server                              # 启动 Web 服务器 (端口 8080)
server 9090                         # 指定端口启动
serverstop                          # 停止 Web 服务器

# —————— Shell 执行 ——————
exec "uname -a"                     # 执行 Shell 命令
shell "ls -la /tmp"                 # 别名

# —————— 文件操作 ——————
filedir /tmp                        # 列出目录
fileread /tmp/test.txt              # 读取文本文件
filewrite /tmp/test.txt "hello"     # 写入文本文件
filedelete /tmp/test.txt            # 删除文件
filecopy /tmp/a.txt /tmp/b.txt      # 复制文件

# —————— 网络 ——————
ip / myip                           # 显示 IP 地址
httpget "http://httpbin.org/ip"     # HTTP GET 请求
httppost "http://httpbin.org/post" "data"  # HTTP POST

# —————— 系统信息 ——————
disk / diskinfo                     # 磁盘使用情况
memory / meminfo                    # 内存使用情况
cpu / cpuinfo                       # CPU 信息
uptime                              # 系统运行时间
```
> 颜色值用 `getcolor` 获取，坐标用截屏预览量取。OCR 支持中文/英文/数字。

### 可选：接入完整 Lua 引擎
已将原版 188 个 .lua 脚本复制到 `Resources/lua/`（含 cjson/copas/websocket 等库）。
`Script/TSLuaBridge.m` 包含完整的 Lua 5.4 桥接实现（现为注释状态 + stub 占位），接入后支持 `tas.tap/swipe/findColor/mSleep/http` 等全部原版 API。

1. 将 Lua 5.4.x 源码加入工程（`lua.h`, `lualib.h` 等）
2. 在 `project.yml` 中配置 Lua 源码路径
3. 打开 `TSLuaBridge.m`，删除底部的 stub 实现和 `/* ... */` 注释，激活完整实现
4. 构建 → 即获得原版 Lua 引擎体验

---

## 六、进阶：Web 远程控制

### 设备网页控制面板
启动后浏览器访问 `http://<设备WiFi IP>:8080` 即可获得远程控制面板：
- **实时截屏**：定时刷新屏幕画面（~3fps 轮询）
- **直接点击**：在截图画面上点击/滑动，实时转 IOHIDEvent 注入
- **脚本执行**：在线编写/粘贴 DSL 脚本并远程运行
- **批量控制**：适合挂机时通过电脑浏览器管控设备

### 后台守护服务
`TSDaemonManager` 实现：
- **音频后台保活**：静默音频循环播放，保持进程不被挂起
- **beginBackgroundTask**：每 3 分钟续期后台任务
- **心跳**：每 10s 检查存活状态
- **通知**：脚本完成/异常时发送本地通知

### Web API 接口
| 端点 | 方法 | 说明 |
|------|------|------|
| `/api/screenshot` | GET | 返回 JPEG 截图 |
| `/api/stream` | GET | MJPEG 实时屏幕流 (~10fps) |
| `/api/tap` | POST | `{"x":100,"y":200}` |
| `/api/swipe` | POST | `{"x1":100,"y1":200,"x2":300,"y2":400,"ms":500}` |
| `/api/run` | POST | `{"script":"tap 100 200\\nsleep 500"}` |
| `/api/stop` | POST | 停止脚本 |
| `/api/device` | GET | 设备信息 JSON |
| `/ws` | WS | WebSocket 双向控制通道 |

---

## 七、已知限制与调优点

- **触摸坐标**：默认按屏幕逻辑点（左上原点）。若在某机型上偏移，检查 `TSHIDEventTouch._sendFingerEventAtPoint:` 的坐标是否需要按屏幕宽高归一化。
- **私有签名**：`IOHIDEventCreateDigitizerEvent` 等参数个数在新 iOS 上可能变化，按 `<IOKit/hid/IOHIDEvent.h>` 校正。
- **截屏**：帧缓冲私有 API 在部分 iOS 17+ 上路径变化，必要时改用 `ScreenCaptureKit` 私有接口或 `ReplayKit`。
- **后台保活**：音频后台模式 + beginBackgroundTask 组合在 iOS 15/16 上可维持约 3 分钟；iOS 17+ 限制更严。
- **Web 服务器**：由于 App 无法持久监听端口，切到后台超时后连接会断开；建议配合守护服务使用。
- **OCR 精度**：Apple Vision 在 iOS 13+ 可用，中英文识别效果好，但对小字号/低对比度文字识别率有限。

---

## 八、免责声明
本项目仅用于技术学习与个人自动化研究。使用者须遵守当地法律及目标应用的服务条款；因使用本工具产生的任何后果由使用者自行承担。作者不鼓励、不支持任何破坏公平性或侵犯他人权益的用途。
