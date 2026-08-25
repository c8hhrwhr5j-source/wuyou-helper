//
//  TSCrashReporter.m
//  TrollAutoTouch
//

#import "TSCrashReporter.h"
#import "TSLogStore.h"
#import "TSPaths.h"

#import <signal.h>
#import <execinfo.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <stdint.h>
#import <pthread.h>

static char g_crashLogPath[1024];
static char g_touchLogPath[1024];

// C 级 TAS 音量监听状态 (仅整数, 供 signal handler 只读; 由 TSLuaBridge 开/关时更新)
static int g_volumeMonitorRunning;

void TSCrashSetVolumeMonitorRunning(int running) {
    g_volumeMonitorRunning = running ? 1 : 0;
}

// ─────────────────────────────────────────────────────────
// C 级安全写入 —— 仅使用 async-signal-safe 函数, 供信号 handler 使用
// ─────────────────────────────────────────────────────────
static void crash_write_len(int fd, const char *s, size_t len) {
    if (!s) s = "(null)";
    const char *p = s;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n <= 0) break;
        p += n;
        len -= (size_t)n;
    }
}

static void crash_write(int fd, const char *s) {
    crash_write_len(fd, s, strlen(s ? s : "(null)"));
}

static void crash_write_int(int fd, long v) {
    char buf[32], tmp[32];
    if (v == 0) { write(fd, "0", 1); return; }
    if (v < 0)  { write(fd, "-", 1); v = -v; }
    int i = 0;
    while (v > 0) { tmp[i++] = (char)('0' + (v % 10)); v /= 10; }
    int j = 0;
    while (i > 0) buf[j++] = tmp[--i];
    buf[j] = 0;
    crash_write(fd, buf);
}

static void crash_write_hex(int fd, uintptr_t v) {
    if (v == 0) { crash_write(fd, "0x0"); return; }
    const char hex[] = "0123456789abcdef";
    char tmp[32];
    int i = 0;
    while (v > 0) { tmp[i++] = hex[v & 0xF]; v >>= 4; }
    crash_write(fd, "0x");
    while (i > 0) write(fd, &tmp[--i], 1);
}

// 读取 touch.log 尾部最近约 4KB (open/read/lseek/close 均 async-signal-safe)
static void crash_dump_log_tail(int fd) {
    if (g_touchLogPath[0] == 0) return;
    int lfd = open(g_touchLogPath, O_RDONLY);
    if (lfd < 0) return;
    off_t end = lseek(lfd, 0, SEEK_END);
    if (end <= 0) { close(lfd); return; }
    const off_t kTail = 4096;
    off_t start = end > kTail ? end - kTail : 0;
    lseek(lfd, start, SEEK_SET);
    char buf[4096];
    ssize_t n = read(lfd, buf, sizeof(buf));
    if (n > 0) {
        crash_write(fd, "\n--- 崩溃前最近日志 (touch.log 尾部) ---\n");
        // 从完整一行的开头开始输出, 避免截断半行
        ssize_t begin = 0;
        if (start > 0) {
            while (begin < n && buf[begin] != '\n') begin++;
            begin++;
        }
        crash_write_len(fd, buf + begin, (size_t)(n - begin));
        if (buf[n - 1] != '\n') crash_write(fd, "\n");
    }
    close(lfd);
}

static void TSCrashSignalHandler(int sig) {
    if (g_crashLogPath[0] == 0) return;
    int fd = open(g_crashLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;

    crash_write(fd, "\n========================================\n");
    crash_write(fd, "[CRASH] signal=");
    crash_write_int(fd, sig);
    crash_write(fd, " (");
    switch (sig) {
        case SIGABRT: crash_write(fd, "SIGABRT"); break;
        case SIGSEGV: crash_write(fd, "SIGSEGV"); break;
        case SIGBUS:  crash_write(fd, "SIGBUS"); break;
        case SIGILL:  crash_write(fd, "SIGILL"); break;
        case SIGFPE:  crash_write(fd, "SIGFPE"); break;
        case SIGTRAP: crash_write(fd, "SIGTRAP"); break;
        default: break;
    }
    crash_write(fd, ")\n");

    // 崩溃线程信息: 主线程还是后台 + 线程 id
    crash_write(fd, "thread: ");
    crash_write(fd, pthread_main_np() ? "main" : "background");
    crash_write(fd, " id=");
    crash_write_hex(fd, (uintptr_t)pthread_self());
    crash_write(fd, "\n");

    // TAS 服务状态
    crash_write(fd, "tas_volume_monitor=");
    crash_write_int(fd, g_volumeMonitorRunning);
    crash_write(fd, "\n");

    void *frames[128];
    int n = backtrace(frames, 128);
    crash_write(fd, "backtrace:\n");
    // 带符号栈 —— 需要构建时保留符号 (build-ipa.sh 已设 STRIP_INSTALLED_PRODUCT=NO)。
    // backtrace_symbols_fd 内部仅用 write(), 可在 signal handler 中安全调用。
    backtrace_symbols_fd(frames, n, fd);
    // 同时保留裸地址, 供后续离线符号化 (atos/llvm-symbolizer + dSYM)
    crash_write(fd, "raw:\n");
    for (int i = 0; i < n; i++) {
        crash_write_hex(fd, (uintptr_t)frames[i]);
        crash_write(fd, "\n");
    }

    // 崩溃前最近日志
    crash_dump_log_tail(fd);

    crash_write(fd, "========================================\n");
    close(fd);

    // 恢复默认处理并重新触发, 让系统照常生成标准崩溃日志(.ips)并退出
    signal(sig, SIG_DFL);
    raise(sig);
}

static void TSCatchExceptionHandler(NSException *e) {
    @autoreleasepool {
        NSString *report = [NSString stringWithFormat:
            @"\n========================================\n"
            @"[CRASH] NSException\n"
            @"name: %@\n"
            @"reason: %@\n"
            @"stack:\n%@\n"
            @"========================================\n",
            e.name ?: @"(null)",
            e.reason ?: @"(null)",
            [[e callStackSymbols] componentsJoinedByString:@"\n"]];
        if (g_crashLogPath[0]) {
            // 追加写入, 不覆盖, 保留可能存在的上一次记录 / 后续 signal 段
            @try {
                NSString *path = [NSString stringWithUTF8String:g_crashLogPath];
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
                if (!fh) {
                    [[NSFileManager defaultManager] createFileAtPath:path
                                                            contents:nil
                                                          attributes:nil];
                    fh = [NSFileHandle fileHandleForWritingAtPath:path];
                }
                if (fh) {
                    [fh seekToEndOfFile];
                    [fh writeData:[report dataUsingEncoding:NSUTF8StringEncoding]];
                    [fh closeFile];
                }
            } @catch (id ex) {}
        }
        @try {
            [[TSLogStore shared] append:[NSString stringWithFormat:@"!! %@", report]];
        } @catch (id ex) {}
        NSLog(@"[TSCrashReporter] %@", report);
    }
}

@implementation TSCrashReporter

+ (void)install {
    [TSPaths ensureDirectoriesExist];

    NSString *logDir = [TSPaths logDir];
    if (logDir.length == 0) return;
    NSString *crashPath = [logDir stringByAppendingPathComponent:@"crash.log"];
    strncpy(g_crashLogPath, crashPath.UTF8String, sizeof(g_crashLogPath) - 1);

    NSString *touchPath = [TSPaths pathForLog:@"touch.log"];
    strncpy(g_touchLogPath, touchPath.UTF8String, sizeof(g_touchLogPath) - 1);

    // 把上次的崩溃记录载入内存日志, 用户 app 内"查看系统日志"直接可见
    NSString *old = [NSString stringWithContentsOfFile:crashPath
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    if (old.length > 0) {
        @try {
            [[TSLogStore shared] append:[NSString stringWithFormat:@"!! 上次崩溃记录:\n%@", old]];
        } @catch (id ex) {}
        // 清空, 避免每次启动重复显示同一条
        @try {
            [[NSFileManager defaultManager] removeItemAtPath:crashPath error:nil];
        } @catch (id ex) {}
    }

    // 捕获未处理 NSException (SIGABRT 之前先走这里)
    NSSetUncaughtExceptionHandler(&TSCatchExceptionHandler);

    // 捕获信号级崩溃 (EXC_BAD_ACCESS → SIGSEGV/SIGBUS, 断言 → SIGABRT 等)
    signal(SIGABRT, TSCrashSignalHandler);
    signal(SIGSEGV, TSCrashSignalHandler);
    signal(SIGBUS,  TSCrashSignalHandler);
    signal(SIGILL,  TSCrashSignalHandler);
    signal(SIGFPE,  TSCrashSignalHandler);
    signal(SIGTRAP, TSCrashSignalHandler);
}

@end
