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
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/reboot.h>

extern char **environ;

// ============================================================
// 工具函数
// ============================================================

/// 打印当前进程信息
static void print_info(void) {
    printf("[roothelper] pid=%d, uid=%d, gid=%d, euid=%d\n",
           getpid(), getuid(), getgid(), geteuid());
}

/// 使用 posix_spawn 执行命令（继承环境变量）
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

/// 通过 /bin/sh 执行 shell 命令
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
    print_info();

    // 确保以 root 权限操作
    if (getuid() != 0) {
        printf("[roothelper] 当前 uid=%d，尝试 setuid(0)...\n", getuid());
        setuid(0);
        setgid(0);
    }
    printf("[roothelper] 提升后 uid=%d euid=%d\n", getuid(), geteuid());

    // 方式1: reboot() 系统调用（最可靠）
    printf("[roothelper] 调用 reboot(RB_AUTOBOOT)...\n");
    sync();           // 同步磁盘缓存
    reboot(RB_AUTOBOOT);

    // 如果 reboot() 返回（权限不足），打印错误
    perror("[roothelper] reboot() 失败");

    // 方式2: 尝试 /sbin/reboot
    printf("[roothelper] 尝试 /sbin/reboot...\n");
    char *rb_argv[] = { "/sbin/reboot", NULL };
    int ret = spawn_command("/sbin/reboot", rb_argv);

    // 方式3: shell 命令重启
    if (ret != 0) {
        printf("[roothelper] 尝试 shell reboot...\n");
        shell_command("reboot");
    }

    return ret;
}

static int cmd_respring(void) {
    printf("[roothelper] ===== 注销手机 =====\n");
    print_info();

    // 确保以 root 权限操作
    if (getuid() != 0) {
        printf("[roothelper] 当前 uid=%d，尝试 setuid(0)...\n", getuid());
        setuid(0);
        setgid(0);
    }
    printf("[roothelper] 提升后 uid=%d euid=%d\n", getuid(), geteuid());

    // 方式1: killall -9 SpringBoard（最直接有效）
    printf("[roothelper] killall -9 SpringBoard...\n");
    char *kill_argv1[] = { "/usr/bin/killall", "-9", "SpringBoard", NULL };
    int ret = spawn_command("/usr/bin/killall", kill_argv1);

    if (ret == 0) {
        printf("[roothelper] killall SpringBoard 成功\n");
        return 0;
    }

    // 方式2: sbreload（iOS 11.3+ 专用重启 SpringBoard 工具）
    printf("[roothelper] 尝试 /usr/bin/sbreload...\n");
    char *sbreload_argv[] = { "/usr/bin/sbreload", NULL };
    ret = spawn_command("/usr/bin/sbreload", sbreload_argv);

    if (ret == 0) {
        return 0;
    }

    // 方式3: launchctl kickstart backboardd
    printf("[roothelper] 尝试 launchctl kickstart backboardd...\n");
    shell_command("launchctl kickstart -k system/com.apple.backboardd");

    // 方式4: kill -9 $(pgrep SpringBoard) 用 shell 兜底
    printf("[roothelper] 尝试 pgrep + kill...\n");
    shell_command("kill -9 $(pgrep SpringBoard 2>/dev/null) 2>/dev/null");

    return 0;
}

static int cmd_shell(const char *command) {
    printf("[roothelper] ===== 执行 Shell: %s =====\n", command);
    print_info();

    if (getuid() != 0) {
        setuid(0);
        setgid(0);
    }

    return shell_command(command);
}

// ============================================================
// 主入口
// ============================================================

int main(int argc, char *argv[]) {
    print_info();

    // 尝试提升到 root
    setuid(0);
    setgid(0);

    printf("[roothelper] 提升后 uid=%d euid=%d\n", getuid(), geteuid());

    if (argc < 2) {
        printf("用法: roothelper <command> [args...]\n");
        printf("命令:\n");
        printf("  reboot   - 重启手机\n");
        printf("  respring - 注销手机 (重启 SpringBoard)\n");
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
