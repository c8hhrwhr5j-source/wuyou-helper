//
//  TSInjectedTouchService.m
//  TrollAutoTouch
//
//  注入 SpringBoard 的触摸服务 (dylib)
//
//  由 opainject 注入到 SpringBoard 进程后通过 dlopen 加载本 dylib:
//    - 加载后启动 TCP server (127.0.0.1:23333) 接收触摸指令
//    - 从 SpringBoard 进程用 IOHID 事件系统向 backboardd 注入触摸
//
//  为什么必须注入 SpringBoard:
//    backboardd 只接受来自 SpringBoard / 受信 HID 服务进程的 IOHID 触摸事件。
//    普通 app 进程即使拥有 com.apple.private.hid.client.event-dispatch entitlement,
//    IOHIDEventSystemClientDispatchEvent 发出的事件也会被 backboardd 直接丢弃
//    —— 这是此前"找色成功但点击无效"的根因（已实测 13 参与 18 参两种
//    finger 事件签名、radius/quality/tipPressure 参数对齐 ZXTouch 与
//    原版 luaLib 后依旧无效，证明参数不是问题，发送者进程身份才是）。
//
//  触摸事件构造逻辑: 严格复刻 ZXTouch Touch.xm（iOS 上被广泛验证的实现）:
//    1. 父事件: IOHIDEventCreateDigitizerEvent 15 参, type=Hand(3), index=99,
//       identity=1; 补写 0xb0019=1、0x4=1、0xb0007=0x23、0xb0008=1、0xb0009=1。
//    2. 子事件: IOHIDEventCreateDigitizerFingerEvent 13 参, identity=3;
//       Down mask=3/range=1/touch=1; Move mask=4/range=1/touch=1;
//       Up mask=2/range=0/touch=0; radius 用私有字段 0xb0014/0xb0015=0.04。
//    3. senderID 动态获取（ZXTouch setSenderIdCallback 同款），兜底 0x8000000800。
//
//  协议见 TSInjectedTouchService.h（坐标在 app 端已归一化为 0~1）。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <mach/mach_time.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <errno.h>
#import <stdint.h>
#import "TSInjectedTouchService.h"

// UIKit 符号说明: 本 dylib 链接时使用 -Wl,-undefined,dynamic_lookup,
// UIKit 符号在运行时由宿主进程(SpringBoard, 已加载 UIKit)解析, 无需显式链接。

// ---------- IOHID 私有符号声明 (SpringBoard 进程内由 dyld 运行时解析) ----------
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDService *IOHIDServiceRef;
// 注意: CFAllocatorRef / kCFAllocatorDefault 直接用 CoreFoundation 的系统定义
// (Foundation.h 已导入)。不要在此重复 typedef/extern —— iOS SDK 中
// CFAllocatorRef 是 const 版本, 重复声明会报 typedef redefinition / redeclaration。
typedef double IOHIDFloat;
typedef uint32_t IOHIDEventOptionBits;
typedef uint32_t IOHIDEventType;

// iOS 13+ 新签名 (15 参)
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t type, uint32_t index, uint32_t identity,
    uint32_t eventMask, uint32_t buttonMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat barrelPressure,
    Boolean range, Boolean touch, IOHIDEventOptionBits options);

// 13 参 finger 子事件 (ZXTouch 使用)
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(
    CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t index, uint32_t identity, uint32_t eventMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat twist,
    Boolean range, Boolean touch, IOHIDEventOptionBits options);

extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, IOHIDEventOptionBits options);
extern void IOHIDEventSetFloatValue(IOHIDEventRef event, uint32_t field, IOHIDFloat value);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, int value);
extern void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t senderID);
extern uint64_t IOHIDEventGetSenderID(IOHIDEventRef event);

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef client, CFRunLoopRef runLoop, CFStringRef mode);
extern void IOHIDEventSystemClientUnscheduleWithRunLoop(IOHIDEventSystemClientRef client, CFRunLoopRef runLoop, CFStringRef mode);
extern int IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef client, void *callback, void *target, void *refcon);
extern int IOHIDEventSystemClientUnregisterEventCallback(IOHIDEventSystemClientRef client);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);
// 按键(含音量键)事件是 IOHIDEventTypeKeyboard, 需要读取事件类型与按键字段
extern uint32_t IOHIDEventGetType(IOHIDEventRef event);

// ZXTouch 兜底 senderID (iPhone 触摸屏标准值, 动态获取前的 fallback)
#define TS_SENDER_ID_FALLBACK 0x8000000800ULL

static IOHIDEventSystemClientRef s_client = NULL;
static uint64_t s_senderID = 0;

// ── 音量键控制面板状态 ──────────────────────────────────────────────
// s_clientFD: 当前 app 连接的 socket (控制事件回写通道)。
//   注意: TSHandleClient 在独立线程处理, 与弹窗回调线程不同, 用 volatile 保证可见性。
static volatile int  s_clientFD = -1;
static volatile BOOL s_volumeControlEnabled = NO;  // 脚本运行期间才响应音量键
static volatile BOOL s_scriptPaused = NO;         // 面板"暂停/继续"按钮切换
static UIWindow        *s_controlWindow = nil;    // 承载控制面板的系统级窗口
static UIAlertController *s_presentedAlert = nil;

#pragma mark - 文件日志 (SpringBoard 内 NSLog 用户看不到, 写入 /tmp 供 app 读回定位)

static void TSLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSLog(@"[TSInjectedTouch] %@", msg);
    @try {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/ts_touch.log"];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:@"/tmp/ts_touch.log" contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/ts_touch.log"];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[[NSString stringWithFormat:@"[%@] %@\n",
                            [NSDate date], msg] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {
        // 写日志失败不致命
    }
}

#pragma mark - senderID 动态获取 (ZXTouch setSenderIdCallback 同款)

// 音量键触发回调 (定义在本文件后部, HID 回调内需要调用, 提前声明)
static void TSVolumeKeyDidFire(void);

static void TSSenderIDCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event) {
    if (!event) return;
    uint64_t sid = IOHIDEventGetSenderID(event);
    if (sid != 0 && s_senderID == 0) {
        s_senderID = sid;
        TSLog(@"已获取真实 senderID: 0x%llX", (unsigned long long)sid);
    }

    // ── 音量键物理按下监听 (HID 层, 不依赖任何通知转发) ──────────────
    // SpringBoard 自身就是通过 IOHIDEventSystemClient 接收音量键/Home/锁屏键的,
    // 本进程内独立的 client 同样能收到 keyboard 类型事件。
    // Consumer Page(0x0C) 上 Volume Up=0xE9, Volume Down=0xEA。
    uint32_t etype = IOHIDEventGetType(event);
    if (etype == 3) { // IOHIDEventTypeKeyboard
        uint64_t usagePage = IOHIDEventGetIntegerValue(event, 0x20001); // kIOHIDEventFieldKeyboardUsagePage
        uint64_t usage    = IOHIDEventGetIntegerValue(event, 0x20002); // kIOHIDEventFieldKeyboardUsage
        if (usagePage == 0x0C && (usage == 0xE9 || usage == 0xEA)) {
            uint64_t down = IOHIDEventGetIntegerValue(event, 0x20004); // kIOHIDEventFieldKeyboardDown
            TSLog(@"HID 音量键事件: usage=0x%llX down=%llu", usage, down);
            if (down != 0) TSVolumeKeyDidFire();
        }
    }
}

// 注册监听: 必须挂在 SpringBoard 主 RunLoop (SpringBoard 主线程一直在跑)。
static void TSStartSenderIDMonitor(void) {
    if (s_client) return;
    s_client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!s_client) {
        TSLog(@"IOHIDEventSystemClientCreate 失败");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        IOHIDEventSystemClientScheduleWithRunLoop(s_client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDEventSystemClientRegisterEventCallback(s_client, TSSenderIDCallback, NULL, NULL);
    });
}

#pragma mark - IOHID 触摸事件构造 (ZXTouch Touch.xm 权威实现)

static void TSAppendChildEvent(IOHIDEventRef parent, int type, int index, float x, float y) {
    IOHIDEventRef child = NULL;
    switch (type) {
        case TS_TOUCH_TYPE_DOWN: // mask=3(Range|Touch), range=1, touch=1
            child = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                         index, 3, 3, x, y, 0.0f, 0.0f, 0.0f, 1, 1, 0);
            break;
        case TS_TOUCH_TYPE_MOVE: // mask=4(Position), range=1, touch=1
            child = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                         index, 3, 4, x, y, 0.0f, 0.0f, 0.0f, 1, 1, 0);
            break;
        case TS_TOUCH_TYPE_UP:   // mask=2(Touch), range=0, touch=0
            child = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                         index, 3, 2, x, y, 0.0f, 0.0f, 0.0f, 0, 0, 0);
            break;
        default:
            return;
    }
    if (child) {
        // ZXTouch: 触摸半径用私有字段 0xb0014/0xb0015 (0.04)
        IOHIDEventSetFloatValue(child, 0xb0014, 0.04f);
        IOHIDEventSetFloatValue(child, 0xb0015, 0.04f);
        IOHIDEventAppendEvent(parent, child, 0);
        CFRelease(child);
    }
}

static void TSPerformTouch(int type, int index, float x, float y) {
    // 父事件: 整只手容器, ZXTouch 固定参数
    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, mach_absolute_time(),
        3, 99, 1, 0, 0,
        0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0, 0, 0);
    if (!parent) return;

    // ZXTouch: 父事件 flags 补写
    IOHIDEventSetIntegerValue(parent, 0xb0019, 1);
    IOHIDEventSetIntegerValue(parent, 0x4, 1);

    TSAppendChildEvent(parent, type, index, x, y);

    // ZXTouch: 父事件关键字段 (EventMask=0x23, Range=1, Touch=1)
    IOHIDEventSetIntegerValue(parent, 0xb0007, 0x23);
    IOHIDEventSetIntegerValue(parent, 0xb0008, 0x1);
    IOHIDEventSetIntegerValue(parent, 0xb0009, 0x1);

    // 标记发送者: 动态获取的真实 senderID, 未就绪时用兜底值
    if (s_senderID == 0) s_senderID = TS_SENDER_ID_FALLBACK;
    IOHIDEventSetSenderID(parent, s_senderID);

    if (s_client) {
        IOHIDEventSystemClientDispatchEvent(s_client, parent);
    }
    CFRelease(parent);
}

#pragma mark - socket server

static ssize_t TSRecvFull(int fd, void *buf, size_t len) {
    size_t got = 0;
    uint8_t *p = (uint8_t *)buf;
    while (got < len) {
        ssize_t n = recv(fd, p + got, len - got, 0);
        if (n <= 0) break;
        got += (size_t)n;
    }
    return (ssize_t)got;
}

// 通知 app 端控制事件 (dylib -> app)。暂停/继续/停止面板按钮点击时调用。
static void TSNotifyApp(uint8_t event) {
    int fd = s_clientFD;
    if (fd < 0) {
        TSLog(@"控制事件 %d 未发送: 当前无 app 连接", event);
        return;
    }
    uint8_t pkt[3] = { TS_EVENT_MAGIC, 0x01, event };
    ssize_t n = send(fd, pkt, 3, MSG_NOSIGNAL);
    if (n < 0) {
        TSLog(@"控制事件 %d 发送失败: %s", event, strerror(errno));
    } else {
        TSLog(@"已通知 app 控制事件: %d", event);
    }
}

static void TSHandleClient(int fd) {
    s_clientFD = fd;   // 记录当前 app 连接, 供控制事件回写
    uint8_t header[2];
    while (1) {
        if (TSRecvFull(fd, header, 2) != 2) break;
        if (header[0] != TS_TOUCH_MAGIC) break;
        int count = header[1];

        if (count == TS_CTRL_FLAG) {
            // 控制命令包: [0]=magic [1]=TS_CTRL_FLAG [2]=cmd
            uint8_t cmd = 0;
            if (TSRecvFull(fd, &cmd, 1) != 1) break;
            if (cmd == TS_CTRL_VOLUME_ON) {
                s_volumeControlEnabled = YES;
                s_scriptPaused = NO;
                TSLog(@"音量键控制面板已启用");
            } else if (cmd == TS_CTRL_VOLUME_OFF) {
                s_volumeControlEnabled = NO;
                s_scriptPaused = NO;
                TSLog(@"音量键控制面板已禁用");
            } else {
                TSLog(@"未知控制命令: %d", cmd);
            }
            continue;
        }

        if (count < 1 || count > TS_TOUCH_MAX_FINGERS) break;

        int cmdLen = count * TS_TOUCH_PER_FINGER;
        uint8_t *cmd = malloc((size_t)cmdLen);
        if (!cmd) break;
        if (TSRecvFull(fd, cmd, (size_t)cmdLen) != cmdLen) {
            free(cmd);
            break;
        }

        for (int i = 0; i < count; i++) {
            uint8_t *p = cmd + i * TS_TOUCH_PER_FINGER;
            uint8_t type  = p[0];
            uint8_t index = p[1];
            float x, y;
            memcpy(&x, p + 2, 4);
            memcpy(&y, p + 6, 4);
            TSPerformTouch(type, index, x, y);
        }
        free(cmd);
    }
    if (s_clientFD == fd) s_clientFD = -1;
    close(fd);
}

static void TSRunServer(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(TS_TOUCH_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        TSLog(@"bind 失败 (端口 %d 可能被占用): %s", TS_TOUCH_PORT, strerror(errno));
        close(fd);
        return;
    }
    if (listen(fd, 4) < 0) {
        TSLog(@"listen 失败: %s", strerror(errno));
        close(fd);
        return;
    }

    TSLog(@"触摸服务已启动, 监听 127.0.0.1:%d", TS_TOUCH_PORT);

    while (1) {
        int client = accept(fd, NULL, NULL);
        if (client < 0) continue;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            TSHandleClient(client);
        });
    }
}

#pragma mark - 音量键控制面板 (在 SpringBoard 进程内弹出系统级菜单)

// 关闭面板: 隐藏承载窗口并清引用。
static void TSDismissControlAlert(void) {
    s_presentedAlert = nil;
    UIWindow *w = s_controlWindow;
    s_controlWindow = nil;
    [w setHidden:YES];
}

// 弹出 暂停/继续 · 停止 · 取消 面板。必须在 SpringBoard 主线程调用。
static void TSPresentControlAlert(void) {
    static NSTimeInterval s_lastShown = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (s_presentedAlert != nil) return;   // 已在显示中, 不再重复弹出
    if ((now - s_lastShown) < 1.0) return; // 1s 防抖 (音量变化通知 + 按键通知会双触发)
    s_lastShown = now;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TrollAutoTouch"
                                                                   message:s_scriptPaused ? @"脚本已暂停，请选择操作" : @"脚本运行中，请选择操作"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    NSString *toggleTitle = s_scriptPaused ? @"继续" : @"暂停";
    uint8_t   toggleEvent = s_scriptPaused ? TS_EVENT_RESUME : TS_EVENT_PAUSE;
    [alert addAction:[UIAlertAction actionWithTitle:toggleTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        s_scriptPaused = !s_scriptPaused;
        TSNotifyApp(toggleEvent);
        TSDismissControlAlert();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"停止" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        s_scriptPaused = NO;
        TSNotifyApp(TS_EVENT_STOP);
        TSDismissControlAlert();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        TSDismissControlAlert();
    }]];
    s_presentedAlert = alert;

    // 自建 UIWindow 承载 (windowLevel 2000 = 原 UIWindowLevelAlert 的数值,
    // iOS13+ 该常量已废弃但数值不变), 确保盖过游戏/任意 app 界面。
    UIWindow *win = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    win.windowLevel = 2000.0;
    win.rootViewController = [UIViewController new];
    [win makeKeyAndVisible];
    s_controlWindow = win;
    [win.rootViewController presentViewController:alert animated:YES completion:nil];
}

// 音量键触发回调: 仅脚本运行期间(音量键控制已启用)响应, 任意线程 → 主线程弹面板。
static void TSVolumeKeyDidFire(void) {
    TSLog(@"音量键触发, 控制面板启用状态=%d", s_volumeControlEnabled);
    if (!s_volumeControlEnabled) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        TSPresentControlAlert();
    });
}

// 注册音量键监听:
//   主要手段: HID 层 IOHIDEventSystemClient 回调直接识别物理按键按下 (见 TSSenderIDCallback),
//   不依赖任何系统通知转发, 最可靠。
//   辅助手段: 以下两个私有 NSNotification 也一并监听, 作为不同 iOS 版本上的兜底:
//   1. AVSystemController_SystemVolumeDidChangeNotification: 音量变化广播 (mediaremoted 转发)。
//   2. AVSystemController_VolumeButtonDownNotification: iOS 16+ 的按键按下通知。
//   注意: 这两个通知需要进程内有活跃的 Audio/MediaRemote 连接才会被转发, SpringBoard
//   进程内不一定收得到, 所以它们只是辅助; 事件是否收到会在 /tmp/ts_touch.log 留痕。
static void TSStartVolumeKeyMonitor(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
                    object:nil queue:nil usingBlock:^(NSNotification *note) {
                        TSLog(@"收到通知: AVSystemController_SystemVolumeDidChangeNotification");
                        TSVolumeKeyDidFire();
                    }];
    [nc addObserverForName:@"AVSystemController_VolumeButtonDownNotification"
                    object:nil queue:nil usingBlock:^(NSNotification *note) {
                        TSLog(@"收到通知: AVSystemController_VolumeButtonDownNotification");
                        TSVolumeKeyDidFire();
                    }];
    TSLog(@"音量键控制监听已注册 (HID 物理按键 + 通知兜底)");
}

#pragma mark - dylib 入口

// dlopen 成功后由 dyld 自动调用
__attribute__((constructor))
static void TSInjectedTouchInit(void) {
    // 清空上一次的日志, 避免混淆
    [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/ts_touch.log" error:NULL];
    TSLog(@"触摸服务 dylib 已加载到进程: %@", [NSProcessInfo processInfo].processName);
    TSStartSenderIDMonitor();
    TSStartVolumeKeyMonitor();
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        TSRunServer();
    });
}
