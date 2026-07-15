//
//  roothelper.c
//  iOS 巨魔专用 RootHelper — 纯 C 编写，无沙盒环境
//  适配 iOS 15 ~ 18，支持：重启、注销桌面
//
//  编译命令 (在 macOS 上):
//    clang -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//          -mios-version-min=14.0 -O2 -o roothelper main.c
//
//  签名命令:
//    ldid -Sentitlements.plist roothelper
//
//  说明:
//   - 重启直接调用 reboot(RB_AUTOBOOT) syscall（巨魔 platform binary + system-actions 权限生效）
//   - 注销桌面 killall -9 SpringBoard（依赖 launchd KeepAlive 自动重生）
//   - 注意: iOS 无 loginwindow 进程，不提供 logout 命令
//

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/reboot.h>

extern char **environ;

// ============================================================
// 工具函数
// ============================================================

/// 打印当前进程权限信息
void print_info(void)
{
    printf("UID: %d  EUID: %d  GID: %d\n", getuid(), geteuid(), getgid());
}

/// Shell 执行命令（通过 posix_spawn + /bin/sh -c 替代 system()，iOS SDK 禁用 system()）
int shell_command(const char *cmd)
{
    printf("[RootHelper] Shell: %s\n", cmd);

    pid_t pid;
    const char *sh_path = "/bin/sh";
    char *const sh_argv[] = { "sh", "-c", (char *)cmd, NULL };

    int ret = posix_spawn(&pid, sh_path, NULL, NULL, sh_argv, environ);
    if (ret != 0) {
        printf("[RootHelper] posix_spawn 失败: errno=%d\n", ret);
        return -1;
    }

    int status;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) {
        printf("[RootHelper] 退出码: %d\n", WEXITSTATUS(status));
        return WEXITSTATUS(status);
    } else {
        printf("[RootHelper] 信号终止: %d\n", WTERMSIG(status));
        return -1;
    }
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

/// 1. 重启手机 —— 直接调用 reboot() syscall（最可靠，巨魔 platform binary 可生效）
static int cmd_reboot(void)
{
    printf("[RootHelper] 准备重启 iPhone\n");
    print_info();
    raise_priv();
    sync();   // 先落盘，避免数据丢失

    // RB_AUTOBOOT == 0，触发整机重启
    // 需要 entitlements: com.apple.private.security.system-actions
    printf("[RootHelper] 调用 reboot(RB_AUTOBOOT)...\n");
    reboot(RB_AUTOBOOT);
    // 成功则不会返回
    perror("[RootHelper] reboot() 失败");
    return -1;
}

/// 2. 注销桌面 Respring（重启 SpringBoard，依赖 launchd 自动重生）
static int cmd_respring(void)
{
    printf("[RootHelper] 重启桌面 SpringBoard\n");
    raise_priv();
    shell_command("killall -9 SpringBoard");
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
        printf("  roothelper respring    重启桌面\n");
        return 0;
    }

    if (strcmp(argv[1], "reboot") == 0)
    {
        return cmd_reboot();
    }
    else if (strcmp(argv[1], "respring") == 0)
    {
        return cmd_respring();
    }
    else
    {
        printf("未知指令！\n");
    }
    return 0;
}
