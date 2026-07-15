//
//  roothelper.c
//  iOS 巨魔专用 RootHelper — 纯 C 编写，无沙盒环境
//  适配 iOS 15 ~ 18，支持：重启、关机、注销桌面、注销用户、执行系统命令
//
//  编译命令 (在 macOS 上):
//    clang -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//          -mios-version-min=14.0 -O2 -o roothelper main.c
//
//  签名命令:
//    ldid -Sentitlements.plist roothelper
//

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <sys/wait.h>
#include <sys/types.h>

// ============================================================
// 工具函数
// ============================================================

/// 打印当前进程权限信息
void print_info(void)
{
    printf("UID: %d  EUID: %d  GID: %d\n", getuid(), geteuid(), getgid());
}

/// 执行外部命令（fork + execv + waitpid）
int spawn_command(const char *path, char *const argv[])
{
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0)
    {
        execv(path, argv);
        _exit(1);
    }
    int status;
    waitpid(pid, &status, 0);
    return WEXITSTATUS(status);
}

/// Shell 执行命令（通过 system() 调用 /bin/sh -c）
int shell_command(const char *cmd)
{
    char buf[512] = {0};
    snprintf(buf, sizeof(buf), "/bin/sh -c \"%s\"", cmd);
    return system(buf);
}

/// 提升权限（巨魔无沙盒环境专用，seteuid(0) 即可生效）
void raise_priv(void)
{
    if (geteuid() != 0)
    {
        seteuid(0);
        setegid(0);
    }
}

// ============================================================
// 系统命令处理器
// ============================================================

/// 1. 重启手机【iOS 全版本稳定】
static int cmd_reboot(void)
{
    printf("[RootHelper] 准备重启 iPhone\n");
    print_info();
    raise_priv();
    sync();

    // iOS 官方标准重启指令（优先级最高）
    shell_command("/usr/sbin/shutdown -r now");
    return 0;
}

/// 2. 关机
static int cmd_shutdown(void)
{
    printf("[RootHelper] 准备关机\n");
    raise_priv();
    sync();
    shell_command("/usr/sbin/shutdown -h now");
    return 0;
}

/// 3. 注销桌面 Respring（重启 SpringBoard）
static int cmd_respring(void)
{
    printf("[RootHelper] 重启桌面 SpringBoard\n");
    raise_priv();
    shell_command("killall -9 SpringBoard");
    return 0;
}

/// 4. 注销用户（杀 loginwindow）
static int cmd_logout(void)
{
    raise_priv();
    shell_command("killall -9 loginwindow");
    return 0;
}

// ============================================================
// 主入口
// ============================================================

int main(int argc, char *argv[])
{
    if (argc < 2)
    {
        printf("==== iOS RootHelper 工具 ====\n");
        printf("用法：\n");
        printf("  roothelper reboot      重启手机\n");
        printf("  roothelper shutdown    关机\n");
        printf("  roothelper respring    重启桌面\n");
        printf("  roothelper logout      注销用户\n");
        return 0;
    }

    if (strcmp(argv[1], "reboot") == 0)
    {
        return cmd_reboot();
    }
    else if (strcmp(argv[1], "shutdown") == 0)
    {
        return cmd_shutdown();
    }
    else if (strcmp(argv[1], "respring") == 0)
    {
        return cmd_respring();
    }
    else if (strcmp(argv[1], "logout") == 0)
    {
        return cmd_logout();
    }
    else
    {
        printf("未知指令！\n");
    }
    return 0;
}
