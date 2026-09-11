# TrollAutoTouch 点击(iOS 16.6)生效说明

> 记录时间: 2026-09-11 · 结论: iOS 16.6 上点击已实测可用
> 涉及代码: `TrollAutoTouch/Core/TSHIDEventTouch.m`(唯一实现文件)

---

## 一句话结论

**用的是「app 进程内 IOHID 直发」——不是注入 SpringBoard、不是 opainject、不需要 platform 身份。**

我们在自己的 app 进程里手工造一个「整只手(Hand)容器事件 + 一根手指(Finger)子事件」的
digitizer(数位板)事件,写上一个**伪装成系统触摸屏的固定 senderID**,然后用
`IOHIDEventSystemClientDispatchEvent` 把它投递给系统事件中心(backboardd)。
系统把它当成一次真实的硬件触摸,于是前台任何 App 都会被点到 —— **不需要任务注入、不需要越狱、
不需要 `task_for_pid`**。

这条路是逐字段逆向原版 `TrollAutoScript 2.2.0 / 2.3.6` 的 `HUDServices` 得到的
(网上流传的 ZXTouch 简版实现**不完整**,这正是此前"代码看着没错但就是点不动"的真正原因)。

---

## 1. 为什么这条路在 iOS 16.6 上能行

| 曾经的错误结论 | 事实 |
| --- | --- |
| "普通 app 直发 IOHID 事件会被 backboardd 丢弃" | 不成立。原版就是一个普通 app,在自己的进程里直发 |
| "必须注入 SpringBoard 才能模拟触摸" | 不需要。直发完全绕开注入 |
| "必须拿到 platform 身份 / 越狱" | 不需要。只需两个私有 entitlement(见第 4 节) |

原版 `HUDServices` 注册在 FrontBoard 服务域(`Info.plist` 的 `BSServiceDomains`),
但它**真正干活的那一步**是在自己进程里调 `IOHIDEventSystemClientDispatchEvent` 直发事件。
我们复刻的正是这一步。

此前测试失败的真实原因是两条,与机制本身无关:

1. **事件构造不完整**(网上 ZXTouch 简版): 父事件 index、子事件 identity、掩码、
   `range/touch` 状态、私有 setter 的 options 全都与原版有差异;
2. **senderID 用错了**: 用了"本机枚举到的 digitizer registryID"(如 `0x10000069B`),
   或者被"监听到的真实触摸值"覆盖 —— 这些值直发毫无反应。

---

## 2. 事件构造(逐字段,与原版 arm64 二进制对齐)

代码位置: `TSHIDEventTouch.m` → `- _dispatchIOHIDTouchAtPoint:index:phase:pressure:radius:`

1. **父事件 = Hand 容器**
   `IOHIDEventCreateDigitizerEvent(type=Hand=3, index=0, identity=1, 坐标/压力全 0,
   range=0, touch=0, options=0)`
   - 关键: `index=0`。简版写 `99`,容器 index 错位会让系统认不出这是"整只手"。
2. **父事件私有字段**(必须用带 options 的 setter,options 恒为 `0xF0000000`):
   `0xb0019 = 1`、`0x4 = 1`
3. **先给父事件写 senderID**,再构造子事件(顺序与原版一致)。
4. **子事件 = 单根手指**
   `IOHIDEventCreateDigitizerFingerEventWithQuality(...)`(**18 参版本**):
   - `index = 0`,`identity = 2`
   - `eventMask`: 按下 `0x803` / 移动 `0x844` / 抬起 `0x803`
     (`0x803 = 0x800 | Range | Touch`,`0x844 = 0x800 | Attribute | Position`)
   - `x, y` = **归一化坐标**(逻辑点 ÷ 屏幕 bounds,0~1)
   - `irregularity = 1.0`,其余质量/密度/半径参数为 0
   - `range = touch = 1`(按下/移动),**抬起时为 0**
5. **子事件私有字段** `0xb001a = 0` → `IOHIDEventAppendEvent(parent, child, 0xF0000000)`
   → **给子事件写 senderID = 父值 + 1**。
6. **父事件掩码/状态**: `0xb0007 = 0x863(按下) / 0x844(移动) / 0x823(抬起)`、
   `0xb0008 = 0xb0009 = range 标志`(**抬起时必须为 0**)。
   - 若抬起时仍报 `range/touch = 1`,系统状态机会残留一根"幽灵手指",后续点击全部错乱。
7. **最后再写一次父事件 senderID,然后 `IOHIDEventSystemClientDispatchEvent(client, parent)`**。

> `0x800` 这一位(私有头里叫 `kIOHIDDigitizerEventFromCorner`)简版完全没有,
> 而原版**每一个** digitizer 掩码都带着它。

---

## 3. senderID:固定伪装值,永不"学习"

| 事件 | 值 |
| --- | --- |
| 父事件(Hand 容器) | `0x8000000817319371` |
| 子事件(Finger) | `0x8000000817319372`(= 父值 + 1) |

- 这两个常量是**写死的**,与原版 `HUDServices 2.3.6` 完全一致。
  原版二进制里连 `IOHIDEventGetSenderID` 这个符号都没有 —— 它**从不**读取本机真实值。
- 因此本机枚举值(`touch.probe()` / `touch.senderIDs()`)和历史保存值**只作诊断**,
  不参与直发;监听真实触摸只用于记录日志,绝不覆盖直发值。
- 曾经的"监听到真实值就覆盖并持久化"是点击失效的直接原因之一:
  保存值一旦被写成直发无反应的 registryID,重启后依然是脏值,点击永远不动。
- 64 位值不要用 `double` 存/传(Lua 数字只有 53 位尾数,低位会被静默改写),
  所以 `touch.probe()` 返回的是**十六进制字符串**。

---

## 4. 需要的 entitlements(`TrollAutoTouch.entitlements`)

| entitlement | 作用 |
| --- | --- |
| `com.apple.private.hid.client.event-dispatch` | 允许通过 IOHID 事件客户端**下发**事件 |
| `com.apple.backboard.client` | 允许与 backboardd(系统事件中心)通信 |
| `com.apple.accessibility.api` | 兜底通道的 AX 点击(`AXUIElementCopyElementAtPosition` + `AXPress`) |

注意: 这几个 entitlement 用 TrollStore 安装即可生效(不涉及 platform 身份),
**不要**在该链路上引入 PushKit / `aps-environment` 之类需要真实签名凭证的能力。

---

## 5. 通道与回退(直发不可用时不会静默失败)

```
点击请求
  └─ 通道 = 自动(默认)
       ├─ 直发可用(client 创建成功 且 senderID ≠ 0) → IOHID 直发(系统级,跨 App)
       └─ 直发不可用                                   → 本应用点击(AX > 进程内 UIControl)
  └─ 通道 = 仅直发   → 只试直发, 不生效就明确报"事件未下发"(用于判定直发是否被受理)
  └─ 通道 = 仅本应用 → 只走 AX/进程内点击(用于判定兜底是否有效)
```

- 「直发可用」的判定是 **client 是否创建成功 + senderID 是否非 0** 两者同时成立。
  只看 senderID 会把"client 为 NULL"误判成"直发就绪":事件发不出去、又提前 return 回退不了,
  表现就是"点了完全没反应且没有任何日志"。
- AX 兜底只对**前台 App**有效(它是对屏幕上的 accessibility 元素执行 `AXPress`),
  不是系统级触摸;进程内 UIControl 兜底只对**本 app 自己的界面**有效。

---

## 6. 日志原则:只记错误,点击成功不写日志

`touch.log`(`/var/mobile/touch/log/touch.log`)**只保留错误/异常提示**,正常的点击成功、
状态查询、探测过程一律不写(改走设备控制台 NSLog)。

判定"这次点击有没有生效"仍然靠**自身回显**(下发的事件会再流经 HID 事件系统,被本进程常驻的
监听 client 收到,与肉手触摸同一条通路),但现在只在**没收到回显**时写一条告警:

```
[touch] ⚠ 点击 #12 未收到系统回显 (100.0,200.0) 通道=自动: 事件很可能未被 HID 事件系统接收(这次点击可能没生效)
```

- 一条告警都不出现 = 每次点击都被系统接收了(正常);
- 出现该告警 = 这一击可能没生效,原因按优先级排查: client/senderID 是否就绪 →
  坐标是否越界 → 是否被"仅直发"模式限制(见第 8 节)。
- 回显通常 1~10ms 到达;极短点击(tap 时长 0ms)的 UP 可能早于回显回调,因此判定会延迟
  0.3s 复核一次,不会误报。

需要"确认点击确实发生了"这类正常路径信息时,用脚本 API **主动查询**,而不是让程序刷日志:

```lua
log(touch.status())   -- 含 senderID/来源、client 状态、通道、已下发次数、最近一击回显次数
```

保留在 `touch.log` 里的其它告警(全部是"点击可能失效"的原因):

| 日志 | 含义 |
| --- | --- |
| `⚠ 直发失败: IOHIDEventSystemClient 未创建` | client 没建起来,事件根本没下发 |
| `HID client 创建失败...直发不可用` | 同上,启动时即发现,点击将回退本应用点击 |
| `⚠ 点击 #N 未收到系统回显 ...` | 下发了但疑似被入口丢弃 |
| `本应用点击(AX)失败 ...` / `(进程内 UIControl)失败 ...` | 兜底通道没命中任何可点击元素 |
| `IOHID 直发不可用..., 进入本应用点击模式`(每次启动一条) | 退化到兜底通道(只对前台 App 有效) |

---

## 7. 日志容量与降噪(2026-09-11 起)

挂机脚本一跑几小时,日志不能无限长。当前策略:

- **单文件 500 行封顶**:`touch.log` 与 `debug.log` 各自最多保留最新 500 行,
  超出即裁剪为最新 500 行(精确按行裁,不靠文件大小估算;日志按批落盘,裁剪紧随其后,
  因此瞬时最多多出不到一批 50 行);内存与设置页同样保留 500 行。
- 点击成功不再逐条记录(原来每次点击 2~3 行),只留上面那张表里的告警。
- 其它已删/已限流/已改 NSLog 的噪音:
  - tap 坐标映射:每次脚本启动只记**第 1 条**(越界坐标始终记);
  - `[HUD] HUD 宿主状态`:只在 `SBS class MISSING` / `startupFailedSBS=YES` 时记;
  - `[touch] 直发: client=... senderID=...` 启动横幅:仅 client 创建失败时才记;
  - `[touch] 检测到系统真实触屏 senderID=...`:改 NSLog;
  - 触摸/探测/候选切换/`touch.watch`/手动设置 senderID 等结果:改 NSLog
    (`⚠ 手动探测失败`、`⚠ touch.watch 采样期内没有捕获到任何真实触摸事件` 仍进 touch.log);
  - 后台任务到期续期:每 ~3 分钟一次,只记第 1 次与之后每 20 次(其余仅 NSLog);
  - 音量键监听停止:7 条步骤日志压缩为 1 条汇总(中间步骤仅 NSLog);
  - 连续相同内容的 toast:只记一条;
  - `willResignActive`:删除(切后台已由 `didEnterBackground` 记录)。

保留的少数"非错误但低频"边界日志(用于回溯"脚本什么时候跑的"):
`[Lua] 开始运行: <脚本名>`、`[Lua] 脚本执行结束`、暂停/继续、音量键操作、
加密项目(.tas)运行与清理 —— 每次运行各 1~2 行,不会随挂机时长增长。

> 原则:如果一个日志会**随脚本运行时间线性增长**(每次点击/每次循环/每次心跳),
> 它就不该进 touch.log;只有"出错了"和"脚本开始/结束"才值得留。

---

## 7.1 同一时刻只允许一个 Lua 脚本

启动第二个脚本时会被拒绝,并在设备上弹提示 **"其他脚本正在运行，请先停止"**:

- 覆盖全部启动入口:脚本列表/网页"开始运行"、悬浮球 ▶、音量键运行、HTTP
  `/task?cmd=start`(返回 `{"ok":false,"error":"其他脚本正在运行，请先停止"}`)、
  API 上传后自动运行。
- 判定不看 `isRunning`,而看"运行位是否被占用"(派发脚本之前就置位),因此
  "已派发还没开跑"的窗口期再点一次也会被拒绝,不会出现"点了停止却自己跑起来"。
- 若旧脚本**正在停止中**(已点停止但还没退出),提示语会变成
  "上一个脚本正在停止中，请稍候再启动",避免让用户去停一个已经在停的脚本。

---

## 8. 反例(别再做这些)

- ❌ 不要把 senderID 换成"本机枚举到的 registryID"或"监听到的真实触摸值"。
- ❌ 不要用 13 参简版 finger 事件、父事件 index=99、掩码 `0x3/0x4`、抬起时 range/touch=1。
- ❌ 不要给私有 setter 传 options=0(原版恒为 `0xF0000000`)。
- ❌ 不要试图走 `task_for_pid(SpringBoard)` 注入: iOS 15.5+ 的 TrollStore 无法授予
  `CS_PLATFORM_BINARY`,该路在原理上不可行(相关代码已移除)。
- ❌ 不要为了"学习真实 senderID"而释放监听 client: 点击回显确认依赖它常驻。
