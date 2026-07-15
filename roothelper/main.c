//
//  main.c
//  roothelper — 无忧辅助 外部 helper 二进制
//
//  流程: kfd 内核提权 → root 权限 → 执行系统命令
//
//  编译命令 (在 macOS 上):
//    clang -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//          -mios-version-min=14.0 -o roothelper main.c kfd.c \
//          -framework IOKit -framework CoreFoundation
//
//  签名命令:
//    ldid -Sentitlements.plist roothelper
//

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
#include "kfd.h"

extern char **environ;

// ============================================================
// 工具函数
// ============================================================

/// 打印当前进程信息
static void print_info(void) {
    printf("[roothelper] pid=%d, uid=%d, gid=%d, euid=%d\n",
           getpid(), getuid(), getgid(), geteuid());
}

/// 通过 posix_spawn + /bin/sh -c 执行 shell 命令
static int shell_command(const char *cmd) {
    printf("[roothelper] Shell: %s\n", cmd);

    pid_t pid;
    const char *sh_path = "/bin/sh";
    char *const sh_argv[] = { "sh", "-c", (char *)cmd, NULL };

    int ret = posix_spawn(&pid, sh_path, NULL, NULL, sh_argv, environ);
    if (ret != 0) {
        printf("[roothelper] posix_spawn 失败: errno=%d\n", ret);
        return -1;
    }

    int status;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) {
        printf("[roothelper] 退出码: %d\n", WEXITSTATUS(status));
        return WEXITSTATUS(status);
    } else {
        printf("[roothelper] 信号终止: %d\n", WTERMSIG(status));
        return -1;
    }
}

// ============================================================
// kfd 提权流程
// ============================================================

/// 执行 kfd 内核提权，获得真正的 root
/// 返回 0 成功（或不需要提权），非 0 失败
static int do_kfd_elevate(void) {
    printf("[roothelper] ===== kfd 内核提权 =====\n");
    print_info();

    // 如果已经是 root，跳过内核提权
    if (getuid() == 0 && geteuid() == 0) {
        printf("[roothelper] ✅ 当前已是 root，跳过 kfd 提权\n");
        return 0;
    }

    // 步骤 1: 初始化 kfd exploit，获取内核读写能力
    printf("[roothelper] [1/3] 初始化 kfd 内核读写...\n");
    if (kfd_init() != 0) {
        printf("[roothelper] ⚠️ kfd 初始化失败，尝试传统 setuid 方式...\n");
        setuid(0);
        setgid(0);
        printf("[roothelper] setuid 后 uid=%d euid=%d\n", getuid(), geteuid());
        return (getuid() == 0) ? 0 : -1;
    }

    // 步骤 2: 利用内核读写覆写 ucred，提权为 root
    printf("[roothelper] [2/3] 内核提权为 root...\n");
    if (kfd_get_root() != 0) {
        printf("[roothelper] ⚠️ 内核提权失败\n");
        kfd_cleanup();
        return -1;
    }

    // 步骤 3: 验证提权结果
    printf("[roothelper] [3/3] 验证权限...\n");
    printf("[roothelper] 提权后 uid=%d euid=%d gid=%d\n",
           getuid(), geteuid(), getgid());

    if (getuid() == 0 && geteuid() == 0) {
        printf("[roothelper] ✅ kfd 提权成功，已获得 root 权限\n");
        kfd_cleanup();
        return 0;
    } else {
        printf("[roothelper] ⚠️ uid 未变为 0，尝试 setuid(0) 兜底...\n");
        setuid(0);
        setgid(0);
        int final_uid = getuid();
        kfd_cleanup();
        return (final_uid == 0) ? 0 : -1;
    }
}

// ============================================================
// 系统命令处理器
// ============================================================

/// 强制重启：shutdown -r now
static int cmd_reboot(void) {
    printf("[roothelper] ===== 强制重启手机 =====\n");
    sync();
    printf("[roothelper] 执行: shutdown -r now\n");
    return shell_command("shutdown -r now");
}

/// 重启桌面（注销）：killall SpringBoard
static int cmd_respring(void) {
    printf("[roothelper] ===== 重启桌面（注销） =====\n");
    printf("[roothelper] 执行: killall SpringBoard\n");
    return shell_command("killall SpringBoard");
}

/// 关机：shutdown -h now
static int cmd_shutdown(void) {
    printf("[roothelper] ===== 关机 =====\n");
    sync();
    printf("[roothelper] 执行: shutdown -h now\n");
    return shell_command("shutdown -h now");
}

/// 通用 Shell 命令执行
static int cmd_shell(const char *command) {
    printf("[roothelper] ===== 执行 Shell: %s =====\n", command);
    print_info();
    return shell_command(command);
}

// ============================================================
// 主入口
// ============================================================

int main(int argc, char *argv[]) {
    print_info();

    if (argc < 2) {
        printf("用法: roothelper <command> [args...]\n");
        printf("命令:\n");
        printf("  reboot   - kfd提权后强制重启 (shutdown -r now)\n");
        printf("  respring - kfd提权后重启桌面 (killall SpringBoard)\n");
        printf("  shutdown - kfd提权后关机 (shutdown -h now)\n");
        printf("  shell    - 执行 Shell 命令\n");
        return 1;
    }

    const char *cmd = argv[1];

    // ============================================================
    // reboot / respring / shutdown 需要 root 权限，先通过 kfd 提权
    // ============================================================
    int need_root = (strcmp(cmd, "reboot") == 0 ||
                     strcmp(cmd, "respring") == 0 ||
                     strcmp(cmd, "shutdown") == 0);

    if (need_root) {
        int elevate_ret = do_kfd_elevate();
        if (elevate_ret != 0) {
            printf("[roothelper] ❌ 提权失败，操作可能无法执行\n");
            // 继续执行 —— 即使提权失败也尝试（可能 persona 已有部分权限）
        }
    } else {
        // 通用 shell 命令也尝试 setuid
        setuid(0);
        setgid(0);
    }

    printf("[roothelper] 执行前 uid=%d euid=%d\n", getuid(), geteuid());

    // 命令分发
    if (strcmp(cmd, "reboot") == 0) {
        return cmd_reboot();
    } else if (strcmp(cmd, "respring") == 0) {
        return cmd_respring();
    } else if (strcmp(cmd, "shutdown") == 0) {
        return cmd_shutdown();
    } else if (strcmp(cmd, "shell") == 0) {
        if (argc < 3) {
            printf("错误: shell 命令需要参数\n");
            return 1;
        }
        return cmd_shell(argv[2]);
    } else {
        printf("未知命令: %s\n", cmd);
        return 1;
    }
}
