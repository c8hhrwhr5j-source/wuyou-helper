//
//  roothelper.c
//  iOS 巨魔专用 RootHelper — 纯 C 编写，无沙盒环境
//  适配 iOS 15 ~ 18
//
//  功能：
//    - 重启手机: kfd 提权 → /usr/sbin/shutdown -r now
//    - 注销桌面: proc_listpids + kill(SpringBoard, SIGKILL)
//
//  编译命令 (在 macOS 上):
//    clang -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//          -mios-version-min=14.0 -O2 -o roothelper main.c kfd.c offsets.c \
//          -framework IOKit -framework CoreFoundation
//
//  签名命令:
//    ldid -Sentitlements.plist roothelper
//

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <errno.h>

#include "kfd.h"
#include "offsets.h"

extern char **environ;
extern int reboot(int);
#define RB_AUTOBOOT 0

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
        printf("[RootHelper] posix_spawn(%s) 失败: %d (errno=%d: %s)\n",
               path, ret, errno, strerror(errno));
        return -1;
    }
    int status;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) {
        int code = WEXITSTATUS(status);
        printf("[RootHelper] exit=%d\n", code);
        return code;
    }
    printf("[RootHelper] 信号终止: %d\n", WTERMSIG(status));
    return -1;
}

// ============================================================
// iOS SDK 可能没有 libproc.h，手动声明
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
            printf("[RootHelper] 找到 %s PID=%d\n", name, pid);
            return pid;
        }
    }
    printf("[RootHelper] 未找到进程: %s\n", name);
    return -1;
}

// ============================================================
// 1. 重启手机 — kfd 提权 → shutdown -r now
// ============================================================
static int cmd_reboot(void) {
    printf("\n");
    printf("========================================\n");
    printf("  RootHelper: 重启手机\n");
    printf("========================================\n");
    print_info();

    // ---- 步骤1: 尝试 kfd 提权 ----
    printf("\n[步骤1] kfd 提权...\n");

    if (kfd_init() != 0) {
        printf("[RootHelper] kfd_init 失败: %s\n", kfd_get_error());
        printf("[RootHelper] 跳过 kfd，尝试直接 shutdown...\n");
        goto direct_reboot;
    }

    if (kfd_open() != 0) {
        printf("[RootHelper] kfd_open 失败: %s\n", kfd_get_error());
        printf("[RootHelper] 跳过 kfd，尝试直接 shutdown...\n");
        goto direct_reboot;
    }

    printf("[RootHelper] kfd 打开成功！\n");

    if (kfd_get_root() == 0) {
        printf("[RootHelper] ✅ kfd 提权成功！EUID=%d\n", geteuid());
    } else {
        printf("[RootHelper] ⚠️  kfd_get_root 返回非零: %s\n", kfd_get_error());
    }

direct_reboot:
    kfd_close();

    // ---- 步骤2: 同步磁盘 ----
    printf("\n[步骤2] sync() 磁盘同步\n");
    sync();

    // ---- 步骤3: /usr/sbin/shutdown -r now (唯一策略) ----
    printf("\n[步骤3] /usr/sbin/shutdown -r now\n");

    char *shutdown_argv[] = { "/usr/sbin/shutdown", "-r", "now", NULL };
    int ret = spawn_program("/usr/sbin/shutdown", shutdown_argv);
    printf("[RootHelper] shutdown => exit=%d\n", ret);

    if (ret == 0) {
        printf("[RootHelper] ✅ shutdown 命令已发送\n");
        // shutdown 是异步的，给它一点时间
        sleep(2);
        return 0;
    }

    // ---- 步骤4: reboot syscall (需要 root) ----
    printf("\n[步骤4] reboot(RB_AUTOBOOT) syscall\n");
    sync();
    reboot(RB_AUTOBOOT);

    // ---- 全都失败 ----
    printf("\n❌ 所有重启策略均失败\n");
    printf("   UID=%d  EUID=%d\n", getuid(), geteuid());
    print_info();
    return -1;
}

// ================================================================
// 2. 提权到 root（同时提权本进程 + 父进程）
//    roothelper 以子进程方式被 Swift 主进程 spawn，
//    所以需要提权两个进程：自身 + 父进程（Swift 主进程）。
//    通过 kfd 修改内核 ucred 结构，不依赖 setuid(0)（sandbox 下无效）。
// ================================================================
static int cmd_escalate(void) {
    printf("\n");
    printf("========================================\n");
    printf("  RootHelper: 提权到 root\n");
    printf("========================================\n");
    print_info();

    pid_t parent_pid = getppid();
    printf("[RootHelper] 父进程 PID=%d\n", parent_pid);

    // 步骤1: 提根本进程
    int ret = kfd_init();
    if (ret != 0) {
        printf("[RootHelper] kfd_init 失败: %s\n", kfd_get_error());
        kfd_close();
        return -1;
    }

    ret = kfd_open();
    if (ret != 0) {
        printf("[RootHelper] kfd_open 失败: %s\n", kfd_get_error());
        // 即使没有内核 r/w，也尝试 setuid
        printf("[RootHelper] 尝试直接 setuid(0)...\n");
        seteuid(0);
        setuid(0);
        printf("[RootHelper] 结果: UID=%d EUID=%d\n", getuid(), geteuid());
        kfd_close();
        return (geteuid() == 0) ? 0 : -1;
    }

    // 步骤2: 提根本进程
    ret = kfd_get_root();
    printf("[RootHelper] kfd_get_root => %d, UID=%d EUID=%d\n", ret, getuid(), geteuid());

    int self_root = (geteuid() == 0) ? 1 : 0;

    // 步骤3: 如果父进程不是自己（即是被 spawn 调用的），提权父进程
    if (parent_pid > 1 && parent_pid != getpid()) {
        printf("[RootHelper] 尝试提权父进程 PID=%d ...\n", parent_pid);
        ret = kfd_escalate_pid(parent_pid);
        if (ret == 0) {
            printf("[RootHelper] ✅ 父进程已提权为 root\n");
        } else {
            printf("[RootHelper] ⚠️ 父进程提权失败: %s\n", kfd_get_error());
        }
    }

    kfd_close();
    print_info();

    // 本进程或父进程提权成功即视为成功
    return (self_root || ret == 0) ? 0 : -1;
}

// ============================================================
// 3. 注销桌面 Respring
// ============================================================
static int cmd_respring(void) {
    printf("[RootHelper] === 注销桌面 ===\n");
    print_info();

    // 方法1: kill SpringBoard
    printf("[RootHelper] [1/2] 查找 SpringBoard...\n");
    int pid = find_pid_by_name("SpringBoard");
    if (pid > 0) {
        printf("[RootHelper] kill(%d, SIGKILL)\n", pid);
        int ret = kill(pid, SIGKILL);
        printf("[RootHelper] kill => %d, errno=%d\n", ret, errno);
        if (ret == 0) {
            printf("[RootHelper] ✅ SpringBoard 已终止\n");
            return 0;
        }
    }

    // 方法2: 备用方案 kill backboardd
    printf("[RootHelper] [2/2] 查找 backboardd...\n");
    pid = find_pid_by_name("backboardd");
    if (pid > 0) {
        printf("[RootHelper] kill(%d, SIGKILL)\n", pid);
        int ret = kill(pid, SIGKILL);
        printf("[RootHelper] kill => %d, errno=%d\n", ret, errno);
        if (ret == 0) {
            printf("[RootHelper] ✅ backboardd 已终止\n");
            return 0;
        }
    }

    printf("[RootHelper] ❌ 未找到可杀的目标进程\n");
    return -1;
}

// ============================================================
// 主入口
// ============================================================

int main(int argc, char *argv[]) {
    if (argc < 2) {
        printf("==== iOS RootHelper (kfd) ====\n");
        printf("用法：\n");
        printf("  roothelper reboot     重启手机 (kfd提权 -> shutdown)\n");
        printf("  roothelper escalate   提权到 root (只提权，不重启)\n");
        printf("  roothelper respring   注销桌面\n");
        return 0;
    }

    if (strcmp(argv[1], "reboot") == 0) {
        return cmd_reboot();
    } else if (strcmp(argv[1], "escalate") == 0) {
        return cmd_escalate();
    } else if (strcmp(argv[1], "respring") == 0) {
        return cmd_respring();
    } else {
        printf("未知指令: %s\n", argv[1]);
        return 1;
    }
}
