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

extern char **environ;

// ============================================================
// 工具函数
// ============================================================

/// 打印当前进程信息
static void print_info(void) {
    printf("[roothelper] pid=%d, uid=%d, gid=%d, euid=%d\n",
           getpid(), getuid(), getgid(), geteuid());
}

/// 通过 system() 执行 shell 命令
static int shell_command(const char *cmd) {
    printf("[roothelper] Shell: %s\n", cmd);
    return system(cmd);
}

// ============================================================
// 系统命令处理器（全部基于 system() 调用）
// ============================================================

/// 强制重启：shutdown -r now
static int cmd_reboot(void) {
    printf("[roothelper] ===== 强制重启手机 =====\n");
    print_info();

    // 确保以 root 权限操作
    if (getuid() != 0) {
        printf("[roothelper] 当前 uid=%d，尝试 setuid(0)...\n", getuid());
        setuid(0);
        setgid(0);
    }
    printf("[roothelper] 提升后 uid=%d euid=%d\n", getuid(), geteuid());

    // 同步磁盘缓存后执行强制重启
    sync();
    printf("[roothelper] 执行: shutdown -r now\n");
    int ret = system("shutdown -r now");
    printf("[roothelper] shutdown -r now 返回: %d\n", ret);
    return ret;
}

/// 重启桌面（注销）：killall SpringBoard
static int cmd_respring(void) {
    printf("[roothelper] ===== 重启桌面（注销） =====\n");
    print_info();

    // 确保以 root 权限操作
    if (getuid() != 0) {
        printf("[roothelper] 当前 uid=%d，尝试 setuid(0)...\n", getuid());
        setuid(0);
        setgid(0);
    }
    printf("[roothelper] 提升后 uid=%d euid=%d\n", getuid(), geteuid());

    printf("[roothelper] 执行: killall SpringBoard\n");
    int ret = system("killall SpringBoard");
    printf("[roothelper] killall SpringBoard 返回: %d\n", ret);
    return ret;
}

/// 关机：shutdown -h now
static int cmd_shutdown(void) {
    printf("[roothelper] ===== 关机 =====\n");
    print_info();

    // 确保以 root 权限操作
    if (getuid() != 0) {
        printf("[roothelper] 当前 uid=%d，尝试 setuid(0)...\n", getuid());
        setuid(0);
        setgid(0);
    }
    printf("[roothelper] 提升后 uid=%d euid=%d\n", getuid(), geteuid());

    // 同步磁盘缓存后执行关机
    sync();
    printf("[roothelper] 执行: shutdown -h now\n");
    int ret = system("shutdown -h now");
    printf("[roothelper] shutdown -h now 返回: %d\n", ret);
    return ret;
}

/// 通用 Shell 命令执行
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
        printf("  reboot   - 强制重启手机 (shutdown -r now)\n");
        printf("  respring - 重启桌面/注销 (killall SpringBoard)\n");
        printf("  shutdown - 关机 (shutdown -h now)\n");
        printf("  shell    - 执行 Shell 命令\n");
        return 1;
    }

    const char *cmd = argv[1];

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
