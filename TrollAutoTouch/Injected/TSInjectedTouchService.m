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

// ---------- IOHID 私有符号声明 (SpringBoard 进程内由 dyld 运行时解析) ----------
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDService *IOHIDServiceRef;
typedef struct __CFAllocator *CFAllocatorRef;
typedef double IOHIDFloat;
typedef uint32_t IOHIDEventOptionBits;
typedef uint32_t IOHIDEventType;

extern CFAllocatorRef kCFAllocatorDefault;

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

// ZXTouch 兜底 senderID (iPhone 触摸屏标准值, 动态获取前的 fallback)
#define TS_SENDER_ID_FALLBACK 0x8000000800ULL

static IOHIDEventSystemClientRef s_client = NULL;
static uint64_t s_senderID = 0;

#pragma mark - senderID 动态获取 (ZXTouch setSenderIdCallback 同款)

static void TSSenderIDCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event) {
    if (!event) return;
    uint64_t sid = IOHIDEventGetSenderID(event);
    if (sid != 0 && s_senderID == 0) {
        s_senderID = sid;
        NSLog(@"[TSInjectedTouch] 已获取真实 senderID: 0x%llX", (unsigned long long)sid);
    }
}

// 注册监听: 必须挂在 SpringBoard 主 RunLoop (SpringBoard 主线程一直在跑)。
static void TSStartSenderIDMonitor(void) {
    if (s_client) return;
    s_client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!s_client) {
        NSLog(@"[TSInjectedTouch] IOHIDEventSystemClientCreate 失败");
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

static void TSHandleClient(int fd) {
    uint8_t header[2];
    while (1) {
        if (TSRecvFull(fd, header, 2) != 2) break;
        if (header[0] != TS_TOUCH_MAGIC) break;
        int count = header[1];
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
        NSLog(@"[TSInjectedTouch] bind 失败 (端口 %d 可能被占用): %s", TS_TOUCH_PORT, strerror(errno));
        close(fd);
        return;
    }
    if (listen(fd, 4) < 0) {
        close(fd);
        return;
    }

    NSLog(@"[TSInjectedTouch] 触摸服务已启动, 监听 127.0.0.1:%d", TS_TOUCH_PORT);

    while (1) {
        int client = accept(fd, NULL, NULL);
        if (client < 0) continue;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            TSHandleClient(client);
        });
    }
}

#pragma mark - dylib 入口

// dlopen 成功后由 dyld 自动调用
__attribute__((constructor))
static void TSInjectedTouchInit(void) {
    NSLog(@"[TSInjectedTouch] 触摸服务 dylib 已加载到进程: %@", [NSProcessInfo processInfo].processName);
    TSStartSenderIDMonitor();
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        TSRunServer();
    });
}
