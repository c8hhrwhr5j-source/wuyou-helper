//
//  roothelper.c
//  iOS 巨魔专用 RootHelper — 纯 C 编写，无沙盒环境
//
//  功能：
//    - escalate: kfd 内核提权 → UID=0
//    - respring: 注销桌面 (kill SpringBoard)
//    - pixel x,y: 读取指定坐标像素 (root 进程 IOMFB)
//    - size:      返回屏幕尺寸和 bpr
//    - capture filepath: 全屏帧缓冲写入文件
//
//  编译命令:
//    clang -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//          -mios-version-min=14.0 -O2 -o roothelper main.c kfd.c offsets.c \
//          -framework IOKit -framework CoreFoundation -framework IOSurface
//
//  签名:
//    ldid -Shelper.entitlements roothelper
//

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <signal.h>
#include <dlfcn.h>
#include <IOSurface/IOSurfaceRef.h>

// ---- IOMobileFramebuffer 私有 API (dlsym 动态加载) ----
typedef struct __IOMobileFramebuffer *IOMFBRef;
static kern_return_t (*_IMFBGetMain)(IOMFBRef*) = NULL;
static kern_return_t (*_IMFBGetSurface)(IOMFBRef, int, IOSurfaceRef*) = NULL;

static void _loadIOMFB(void) {
    _IMFBGetMain = (kern_return_t(*)(IOMFBRef*))dlsym(RTLD_DEFAULT, "IOMobileFramebufferGetMainDisplay");
    _IMFBGetSurface = (kern_return_t(*)(IOMFBRef, int, IOSurfaceRef*))dlsym(RTLD_DEFAULT, "IOMobileFramebufferGetLayerDefaultSurface");
}
#include <spawn.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <errno.h>
#include <mach/mach.h>

#include "kfd.h"
#include "offsets.h"

extern char **environ;

// ============================================================
// 工具函数
// ============================================================

static void print_info(void) {
    printf("UID: %d  EUID: %d  GID: %d  EGID: %d\n",
           getuid(), geteuid(), getgid(), getegid());
}

static int spawn_program(const char *path, char *const argv[]) {
    pid_t pid;
    int ret = posix_spawn(&pid, path, NULL, NULL, argv, environ);
    if (ret != 0) {
        printf("[RootHelper] posix_spawn(%s) 失败: %d (%s)\n",
               path, ret, strerror(ret));
        return -1;
    }
    int status;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return -1;
}

// ============================================================
// 进程搜索 (用于 respring)
// ============================================================

extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);

static int find_pid_by_name(const char *name) {
    pid_t buffer[4096];
    int count = proc_listpids(1, 0, buffer, (int)sizeof(buffer));
    int num = count / (int)sizeof(pid_t);

    for (int i = 0; i < num; i++) {
        pid_t pid = buffer[i];
        if (pid <= 0) continue;
        char namebuf[256] = {0};
        int len = proc_name(pid, namebuf, 256);
        if (len > 0 && strcmp(namebuf, name) == 0) {
            return pid;
        }
    }
    return -1;
}

// ============================================================
// 1. 提权到 root
// ============================================================

static int cmd_escalate(void) {
    printf("\n");
    printf("========================================\n");
    printf("  RootHelper: 提权到 root\n");
    printf("========================================\n");
    print_info();

    // 先尝试 kfd 内核提权
    printf("[escalate] 开始内核提权...\n");
    int ret = kfd_escalate();

    if (ret != 0) {
        printf("[escalate] ❌ kfd_escalate 失败: %s\n", kfd_get_error());
        kfd_close();
        print_info();
        return 1;
    }

    // kfd 已修改内核 ucred，再调用 setuid(0) 让用户态同步
    setgid(0);
    setuid(0);
    seteuid(0);

    print_info();
    printf("[escalate] ✅ 提权成功 UID=%d EUID=%d\n", getuid(), geteuid());
    return 0;
}

// ============================================================
// 2. 注销桌面 Respring
// ============================================================

static int cmd_respring(void) {
    printf("[respring] === 注销桌面 ===\n");
    print_info();

    int pid = find_pid_by_name("SpringBoard");
    if (pid > 0) {
        printf("[respring] kill SpringBoard PID=%d\n", pid);
        if (kill(pid, SIGKILL) == 0) {
            printf("[respring] ✅ SpringBoard 已终止\n");
            return 0;
        }
    }

    pid = find_pid_by_name("backboardd");
    if (pid > 0) {
        printf("[respring] kill backboardd PID=%d\n", pid);
        if (kill(pid, SIGKILL) == 0) {
            printf("[respring] ✅ backboardd 已终止\n");
            return 0;
        }
    }

    printf("[respring] ❌ 未找到可杀的目标进程\n");
    return -1;
}

// ============================================================
// 屏幕捕获（通过 root 进程 IOMFB → dlsym 动态加载）
// ============================================================

static int cmd_pixel(int x, int y) {
    _loadIOMFB();
    kfd_escalate();

    IOMFBRef fb = NULL;
    kern_return_t ret = _IMFBGetMain(&fb);
    if (ret != KERN_SUCCESS || !fb) {
        printf("ERR IOMFB 连接失败\n");
        return 1;
    }

    IOSurfaceRef sf = NULL;
    for (int l = 0; l <= 2; l++) {
        ret = _IMFBGetSurface(fb, l, &sf);
        if (ret == KERN_SUCCESS && sf) break;
    }
    if (!sf) {
        printf("ERR Surface 获取失败\n");
        return 1;
    }

    int w = (int)IOSurfaceGetWidth(sf);
    int h = (int)IOSurfaceGetHeight(sf);
    int bpr = (int)IOSurfaceGetBytesPerRow(sf);

    if (x < 0 || y < 0 || x >= w || y >= h) {
        CFRelease(sf);
        printf("ERR 坐标越界 %d,%d (%dx%d)\n", x, y, w, h);
        return 1;
    }

    ret = IOSurfaceLock(sf, 1/*kIOSurfaceLockReadOnly*/, NULL);
    if (ret != KERN_SUCCESS) {
        CFRelease(sf);
        printf("ERR Lock 失败 0x%x\n", ret);
        return 1;
    }

    void *base = IOSurfaceGetBaseAddress(sf);
    if (!base) {
        IOSurfaceUnlock(sf, 1, NULL);
        CFRelease(sf);
        printf("ERR BaseAddress NULL\n");
        return 1;
    }

    int offset = y * bpr + x * 4;
    unsigned char *p = (unsigned char *)base + offset;
    int b = p[0], g = p[1], r = p[2];

    IOSurfaceUnlock(sf, 1, NULL);
    CFRelease(sf);

    printf("OK %d %d %d\n", r, g, b);
    return 0;
}

static int cmd_size(void) {
    _loadIOMFB();
    kfd_escalate();

    IOMFBRef fb = NULL;
    if (_IMFBGetMain(&fb) != KERN_SUCCESS || !fb) {
        printf("ERR IOMFB 失败\n");
        return 1;
    }

    IOSurfaceRef sf = NULL;
    for (int l = 0; l <= 2; l++) {
        if (_IMFBGetSurface(fb, l, &sf) == KERN_SUCCESS && sf) break;
    }
    if (!sf) { printf("ERR Surface 失败\n"); return 1; }

    printf("SIZE %d %d %d\n",
           (int)IOSurfaceGetWidth(sf),
           (int)IOSurfaceGetHeight(sf),
           (int)IOSurfaceGetBytesPerRow(sf));
    CFRelease(sf);
    return 0;
}

static int cmd_capture(const char *path) {
    _loadIOMFB();
    kfd_escalate();

    IOMFBRef fb = NULL;
    if (_IMFBGetMain(&fb) != KERN_SUCCESS || !fb) {
        printf("ERR IOMFB 失败\n"); return 1;
    }

    IOSurfaceRef sf = NULL;
    for (int l = 0; l <= 2; l++) {
        if (_IMFBGetSurface(fb, l, &sf) == KERN_SUCCESS && sf) break;
    }
    if (!sf) { printf("ERR Surface 失败\n"); return 1; }

    int w = (int)IOSurfaceGetWidth(sf);
    int h = (int)IOSurfaceGetHeight(sf);
    int bpr = (int)IOSurfaceGetBytesPerRow(sf);

    if (IOSurfaceLock(sf, 1, NULL) != KERN_SUCCESS) {
        CFRelease(sf); printf("ERR Lock 失败\n"); return 1;
    }

    void *base = IOSurfaceGetBaseAddress(sf);
    if (!base) {
        IOSurfaceUnlock(sf, 1, NULL);
        CFRelease(sf); printf("ERR BaseAddress NULL\n"); return 1;
    }

    size_t total = (size_t)h * bpr;
    FILE *fp = fopen(path, "wb");
    if (!fp) {
        IOSurfaceUnlock(sf, 1, NULL);
        CFRelease(sf); printf("ERR 无法创建文件 %s\n", path); return 1;
    }

    fwrite(base, 1, total, fp);
    fclose(fp);

    IOSurfaceUnlock(sf, 1, NULL);
    CFRelease(sf);

    printf("OK %d bytes\n", (int)total);
    return 0;
}

// ============================================================
// 主入口
// ============================================================

int main(int argc, char *argv[]) {
    setbuf(stdout, NULL);
    setbuf(stderr, NULL);

    if (argc < 2) {
        printf("==== iOS RootHelper (kfd) ====\n");
        printf("用法:\n");
        printf("  roothelper escalate   提权到 root\n");
        printf("  roothelper respring   注销桌面\n");
        printf("  roothelper pixel x,y  取像素 RGB (root+IOMFB)\n");
        printf("  roothelper size       屏幕尺寸\n");
        printf("  roothelper capture [path]  全屏帧缓冲写入文件\n");
        return 0;
    }

    if (strcmp(argv[1], "escalate") == 0) {
        return cmd_escalate();
    } else if (strcmp(argv[1], "respring") == 0) {
        return cmd_respring();
    } else if (strcmp(argv[1], "pixel") == 0) {
        if (argc < 3) { printf("用法: pixel x,y\n"); return 1; }
        int x=0, y=0;
        sscanf(argv[2], "%d,%d", &x, &y);
        return cmd_pixel(x, y);
    } else if (strcmp(argv[1], "size") == 0) {
        return cmd_size();
    } else if (strcmp(argv[1], "capture") == 0) {
        const char *path = (argc >= 3) ? argv[2] : "/tmp/sc_cap.raw";
        return cmd_capture(path);
    } else {
        printf("未知指令: %s\n", argv[1]);
        return 1;
    }
}
