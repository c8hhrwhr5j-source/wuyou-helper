//
//  main.c
//  roothelper — 无忧辅助 外部 helper 二进制
//
//  编译命令 (在 macOS 上):
//    clang -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//          -mios-version-min=14.0 -o roothelper main.c
//
//  签名命令:
//    ldid -Sentitlements.plist roothelper
//
//  放到 .app bundle 根目录下
//

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>

extern char **environ;

// ============================================================
// 工具函数
// ============================================================

/// 使用 posix_spawn 执行命令（完全 root 权限，兼容 iOS SDK）
static int spawn_command(const char *binary, char *const argv[]) {
    pid_t pid;
    int status;

    int ret = posix_spawn(&pid, binary, NULL, NULL, argv, environ);
    if (ret != 0) {
        printf("[roothelper] posix_spawn 失败: %s (errno: %d)\n", binary, ret);
        return -1;
    }

    waitpid(pid, &status, 0);
    printf("[roothelper] %s 退出码: %d\n", binary, WEXITSTATUS(status));
    return WEXITSTATUS(status);
}

/// 通过 /bin/sh 执行 shell 命令（兼容 iOS，不用 system()）
static int shell_command(const char *cmd) {
    printf("[roothelper] Shell: %s\n", cmd);
    char *argv[] = { "/bin/sh", "-c", (char *)cmd, NULL };
    return spawn_command("/bin/sh", argv);
}

// ============================================================
// 命令处理器
// ============================================================

static int cmd_reboot(void) {
    printf("[roothelper] ===== 重启手机 =====\n");
    // 方式1: /sbin/reboot (iOS 上通常可用)
    char *argv[] = { "/sbin/reboot", NULL };
    int ret = spawn_command("/sbin/reboot", argv);

    // 方式2: 如果 /sbin/reboot 不可用，尝试 reboot 系统调用
    if (ret != 0) {
        printf("[roothelper] /sbin/reboot 失败，尝试 reboot() 系统调用\n");
        reboot(0);  // RB_AUTOBOOT
    }
    return ret;
}

static int cmd_respring(void) {
    printf("[roothelper] ===== 注销手机 =====\n");

    // 方式1: sbreload (iOS 11.3+, 最快)
    char *sbreload_argv[] = { "/usr/bin/sbreload", NULL };
    int ret = spawn_command("/usr/bin/sbreload", sbreload_argv);

    if (ret != 0) {
        // 方式2: killall SpringBoard
        printf("[roothelper] sbreload 失败，尝试 killall SpringBoard\n");
        char *killall_argv[] = { "/usr/bin/killall", "-9", "SpringBoard", NULL };
        ret = spawn_command("/usr/bin/killall", killall_argv);
    }

    if (ret != 0) {
        // 方式3: launchctl kickstart
        printf("[roothelper] killall 失败，尝试 launchctl\n");
        char *launchctl_argv[] = { "/usr/bin/launchctl", "kickstart", "-k", "system/com.apple.backboardd", NULL };
        ret = spawn_command("/usr/bin/launchctl", launchctl_argv);
    }

    return ret;
}

static int cmd_shell(const char *command) {
    printf("[roothelper] ===== 执行 Shell: %s =====\n", command);
    return shell_command(command);
}

// ============================================================
// 主入口
// ============================================================

int main(int argc, char *argv[]) {
    printf("[roothelper] 启动 (pid: %d, uid: %d)\n", getpid(), getuid());

    if (argc < 2) {
        printf("用法: roothelper <command> [args...]\n");
        printf("命令:\n");
        printf("  reboot   - 重启手机\n");
        printf("  respring - 注销手机\n");
        printf("  shell    - 执行 Shell 命令\n");
        return 1;
    }

    const char *cmd = argv[1];

    if (strcmp(cmd, "reboot") == 0) {
        return cmd_reboot();
    } else if (strcmp(cmd, "respring") == 0) {
        return cmd_respring();
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
