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
//   - 重启: reboot() syscall + trollstorehelper fallback
//   - 注销桌面: proc_listpids + kill(SpringBoard, SIGKILL)
//     (参考 TrollServer 实现，不依赖 killall shell 命令)
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

// iOS SDK 没有 sys/reboot.h，手动声明 reboot() 与常量
extern int reboot(int);
#define RB_AUTOBOOT 0

// iOS SDK 可能没有 libproc.h，手动声明进程相关函数
extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);

extern char **environ;

// ============================================================
// 工具函数
// ============================================================

/// 打印当前进程权限信息
void print_info(void)
{
    printf("UID: %d  EUID: %d  GID: %d\n", getuid(), geteuid(), getgid());
}

/// spawn 外部程序（不通过 shell）
static int spawn_program(const char *path, char *const argv[])
{
    pid_t pid;
    int ret = posix_spawn(&pid, path, NULL, NULL, argv, environ);
    if (ret != 0) {
        printf("[RootHelper] posix_spawn(%s) 失败: %d\n", path, ret);
        return -1;
    }
    int status;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) {
        printf("[RootHelper] exit=%d\n", WEXITSTATUS(status));
        return WEXITSTATUS(status);
    }
    printf("[RootHelper] 信号终止: %d\n", WTERMSIG(status));
    return -1;
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

/// 按名称查找进程 PID（proc_listpids + proc_name，纯系统调用无 shell 依赖）
static int find_pid_by_name(const char *name)
{
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
// 系统命令处理器
// ============================================================

/// 1. 重启手机 —— reboot() syscall + trollstorehelper 回退链
static int cmd_reboot(void)
{
    printf("[RootHelper] === 开始重启流程 ===\n");
    print_info();
    sync();

    // 策略1: 直接 reboot() syscall（需要 root UID 或 system-actions entitlement）
    printf("[RootHelper] 策略1: reboot(RB_AUTOBOOT)...\n");
    raise_priv();
    reboot(RB_AUTOBOOT);
    printf("[RootHelper] reboot() 返回了 (EUID=%d, errno=%d: %s)\n", geteuid(), errno, strerror(errno));

    // 策略2: 通过 trollstorehelper（它自带 setuid root）
    const char *helper_paths[] = {
        "/var/jb/usr/bin/trollstorehelper",
        "/usr/bin/trollstorehelper",
        "/usr/local/bin/trollstorehelper",
        NULL
    };
    for (int i = 0; helper_paths[i]; i++) {
        if (access(helper_paths[i], X_OK) != 0) continue;

        // 验证 setuid 位
        struct stat st;
        int has_suid = (stat(helper_paths[i], &st) == 0 && (st.st_mode & S_ISUID));
        printf("[RootHelper] 策略2: trollstorehelper(%s) setuid=%d\n", helper_paths[i], has_suid);

        char *const argv1[] = { "trollstorehelper", "reboot", NULL };
        spawn_program(helper_paths[i], argv1);

        char *const argv2[] = { "trollstorehelper", "system", "reboot", NULL };
        spawn_program(helper_paths[i], argv2);
    }

    // 策略3: launchctl reboot
    printf("[RootHelper] 策略3: launchctl reboot...\n");
    char *const lctl_argv[] = { "launchctl", "reboot", NULL };
    spawn_program("/bin/launchctl", lctl_argv);

    printf("[RootHelper] ❌ 所有重启策略均失败 (EUID=%d)\n", geteuid());
    return -1;
}

/// 2. 注销桌面 Respring（proc_listpids + kill，参考 TrollServer 实现）
static int cmd_respring(void)
{
    printf("[RootHelper] === 注销桌面 ===\n");
    print_info();
    raise_priv();

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

int main(int argc, char *argv[])
{
    if (argc < 2)
    {
        printf("==== iOS RootHelper 工具 ====\n");
        printf("用法：\n");
        printf("  roothelper reboot     重启手机\n");
        printf("  roothelper respring   注销桌面\n");
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
