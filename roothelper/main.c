//
//  roothelper.c
//  iOS 巨魔专用 RootHelper — 纯 C 编写，无沙盒环境
//
//  功能：
//    - escalate: kfd 内核提权 → UID=0
//    - respring: 注销桌面 (kill SpringBoard)
//
//  编译命令:
//    clang -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//          -mios-version-min=14.0 -O2 -o roothelper main.c kfd.c offsets.c \
//          -framework IOKit -framework CoreFoundation
//
//  签名:
//    ldid -Shelper.entitlements roothelper
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
        return 0;
    }

    if (strcmp(argv[1], "escalate") == 0) {
        return cmd_escalate();
    } else if (strcmp(argv[1], "respring") == 0) {
        return cmd_respring();
    } else {
        printf("未知指令: %s\n", argv[1]);
        return 1;
    }
}
