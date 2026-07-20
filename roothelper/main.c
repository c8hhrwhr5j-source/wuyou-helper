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
// 1. 重启手机 — 先尝试 setuid(0) (TrollStore 通常直接成功)，再 fallback 到 kfd
// ============================================================
static int cmd_reboot(void) {
    printf("\n");
    printf("========================================\n");
    printf("  RootHelper: 重启手机\n");
    printf("========================================\n");
    print_info();

    // ---- 步骤1: TrollStore 环境直接 setuid(0) ----
    // platform-application + persona-mgmt + no-sandbox 通常可以直接 setuid(0)
    // 不需要 kfd 内核漏洞（iOS 16.6+ / 17+ 上 kfd 已不可用）
    printf("\n[步骤1] 尝试 setuid(0) (TrollStore 平台权限)...\n");
    int r1 = seteuid(0);
    int r2 = setuid(0);
    printf("[RootHelper] setuid(0)=%d seteuid(0)=%d => UID=%d EUID=%d\n",
           r2, r1, getuid(), geteuid());

    int is_root = (getuid() == 0 || geteuid() == 0);
    if (is_root) {
        printf("[RootHelper] ✅ setuid(0) 直接成功！跳过 kfd。\n");
        goto do_reboot;
    }
    printf("[RootHelper] ⚠️ setuid(0) 失败，继续尝试 kfd...\n");

    // ---- 步骤2: kfd 内核提权（仅适用于 iOS 15.x / 16.0-16.5）----
    printf("\n[步骤2] kfd 内核提权...\n");

    if (kfd_init() != 0) {
        printf("[RootHelper] kfd_init 失败: %s\n", kfd_get_error());
        goto do_reboot;  // 即使没有 kfd，也尝试 reboot（如果 setuid 之前成功过）
    }

    if (kfd_open() != 0) {
        printf("[RootHelper] kfd_open 失败: %s\n", kfd_get_error());
        goto do_reboot;
    }

    printf("[RootHelper] kfd 打开成功！\n");

    if (kfd_get_root() == 0) {
        printf("[RootHelper] ✅ kfd 提权成功！EUID=%d\n", geteuid());
        is_root = 1;
    } else {
        printf("[RootHelper] ⚠️  kfd_get_root 返回非零: %s\n", kfd_get_error());
    }

do_reboot:
    kfd_close();

    if (!is_root) {
        printf("\n❌ 无法获得 root 权限，重启失败\n");
        printf("   UID=%d EUID=%d\n", getuid(), geteuid());
        printf("   可能原因：1) offsets 不匹配 2) iOS 16.6+ task_for_pid 被限制 3) setuid 被拒绝\n");
        return -1;
    }

    printf("\n[RootHelper] ✅ 已获得 root 权限，执行重启...\n");

    // ---- 步骤3: 同步磁盘 ----
    printf("\n[步骤3] sync() 磁盘同步\n");
    sync();

    // ---- 步骤4: reboot() 系统调用（最可靠） ----
    printf("\n[步骤4] reboot(RB_AUTOBOOT) 系统调用...\n");
    if (reboot(RB_AUTOBOOT) == 0) {
        printf("[RootHelper] ✅ reboot() 成功返回\n");
        sleep(2);
        return 0;
    }
    printf("[RootHelper] ⚠️  reboot() 失败: errno=%d (%s)\n", errno, strerror(errno));

    // ---- 步骤5: /usr/sbin/shutdown -r now ----
    printf("\n[步骤5] /usr/sbin/shutdown -r now\n");
    char *shutdown_argv[] = { "/usr/sbin/shutdown", "-r", "now", NULL };
    int ret = spawn_program("/usr/sbin/shutdown", shutdown_argv);
    printf("[RootHelper] shutdown => exit=%d\n", ret);

    if (ret == 0) {
        printf("[RootHelper] ✅ shutdown 命令已执行\n");
        sleep(2);
        return 0;
    }

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
//    策略：先尝试 setuid(0)（TrollStore 通常直接成功），再 fallback 到 kfd 内核修改。
// ================================================================
static int cmd_escalate(void) {
    printf("\n");
    printf("========================================\n");
    printf("  RootHelper: 提权到 root\n");
    printf("========================================\n");
    print_info();

    pid_t parent_pid = getppid();
    printf("[RootHelper] 父进程 PID=%d\n", parent_pid);

    // 步骤1: 先尝试 setuid(0)（TrollStore 环境通常直接成功）
    printf("\n[步骤1] 尝试 setuid(0) (TrollStore 平台权限)...\n");
    int r1 = seteuid(0);
    int r2 = setuid(0);
    printf("[RootHelper] setuid(0)=%d seteuid(0)=%d => UID=%d EUID=%d\n",
           r2, r1, getuid(), geteuid());

    int self_root = (getuid() == 0 || geteuid() == 0);

    if (self_root) {
        printf("[RootHelper] ✅ setuid(0) 直接成功！\n");
        // 即使 setuid(0) 成功，也尝试 kfd 提权父进程
        // 但如果 kfd 不可用（iOS 16.6+），父进程只能通过 Swift 端自行 setuid(0)
    }

    // 步骤2: 如果 setuid 失败，尝试 kfd 内核提权（iOS 15.x / 16.0-16.5）
    if (!self_root) {
        printf("\n[步骤2] setuid 失败，尝试 kfd 内核提权...\n");
        int ret = kfd_init();
        if (ret != 0) {
            printf("[RootHelper] kfd_init 失败: %s\n", kfd_get_error());
            kfd_close();
            print_info();
            return -1;
        }

        ret = kfd_open();
        if (ret != 0) {
            printf("[RootHelper] kfd_open 失败: %s\n", kfd_get_error());
            printf("[RootHelper] 所有提权方式均失败\n");
            kfd_close();
            print_info();
            return -1;
        }

        // 提根本进程
        ret = kfd_get_root();
        printf("[RootHelper] kfd_get_root => %d, UID=%d EUID=%d\n", ret, getuid(), geteuid());
        self_root = (getuid() == 0 || geteuid() == 0);

        // 如果父进程不是自己（即是被 spawn 调用的），提权父进程
        if (self_root && parent_pid > 1 && parent_pid != getpid()) {
            printf("[RootHelper] 尝试提权父进程 PID=%d ...\n", parent_pid);
            ret = kfd_escalate_pid(parent_pid);
            if (ret == 0) {
                printf("[RootHelper] ✅ 父进程已提权为 root\n");
            } else {
                printf("[RootHelper] ⚠️ 父进程提权失败: %s\n", kfd_get_error());
            }
        }

        kfd_close();
    }

    print_info();

    // 本进程或父进程提权成功即视为成功
    return self_root ? 0 : -1;
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
