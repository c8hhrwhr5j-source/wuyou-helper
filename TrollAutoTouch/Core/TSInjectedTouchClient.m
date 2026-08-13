//
//  TSInjectedTouchClient.m
//  TrollAutoTouch
//
//  app 端触摸注入客户端实现 (详见头文件)

#import "TSInjectedTouchClient.h"
#import "TSInjectedTouchService.h"

#include <spawn.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/sysctl.h>

extern char **environ;

@interface TSInjectedTouchClient () {
    int _socketFD;
    pid_t _springBoardPid;
    BOOL _injected;
    BOOL _injectFailed;
    // 暴露最后失败阶段 + errno 给 statusDescription, 否则 Lua 侧只能看到 NSLog, 看不到具体错误码
    NSString *_lastErrorStage;  // nil = 暂无失败; 否则 "deploy" / "spawn" / "log-open"
    int _lastErrorErrno;        // 0 = 暂无失败; 否则 POSIX errno 或 posix_spawn 返回值
}
@end

@implementation TSInjectedTouchClient

+ (instancetype)shared {
    static TSInjectedTouchClient *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TSInjectedTouchClient alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _socketFD = -1;
        _springBoardPid = -1;
        _lastErrorErrno = 0;
    }
    return self;
}

- (BOOL)isConnected {
    return _socketFD >= 0;
}

- (pid_t)springBoardPid {
    return _springBoardPid;
}

- (NSString *)statusDescription {
    if (_injectFailed) {
        // 附上 opainject 的具体错误 (task_for_pid / dlopen 失败原因), 便于真机定位
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *logPath = [docs stringByAppendingPathComponent:@"bin/opainject.log"];
        NSString *out = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:NULL];
        NSString *detail = @"";
        if (out.length > 0) {
            NSArray<NSString *> *lines = [out componentsSeparatedByString:@"\n"];
            // 只取最后几行最有用的报错
            NSUInteger from = lines.count > 4 ? lines.count - 4 : 0;
            detail = [[[lines subarrayWithRange:NSMakeRange(from, lines.count - from)] componentsJoinedByString:@"\n"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        if (detail.length > 0) {
            return [NSString stringWithFormat:@"注入失败: %@", detail];
        }
        // opainject.log 为空/不存在 → 兜底. 附上最后一次失败阶段 + errno, 方便 Lua 侧直接定位
        if (_lastErrorStage != nil && _lastErrorErrno != 0) {
            return [NSString stringWithFormat:@"注入失败(无法注入 SpringBoard, [%@] errno=%d)", _lastErrorStage, _lastErrorErrno];
        } else if (_lastErrorStage != nil) {
            return [NSString stringWithFormat:@"注入失败(无法注入 SpringBoard, [%@])", _lastErrorStage];
        } else if (_lastErrorErrno != 0) {
            return [NSString stringWithFormat:@"注入失败(无法注入 SpringBoard, errno=%d)", _lastErrorErrno];
        }
        return @"注入失败(无法注入 SpringBoard)";
    }
    if (!_injected) {
        return @"未注入";
    }
    if (_socketFD < 0) {
        return @"已注入但未连接";
    }
    return [NSString stringWithFormat:@"已注入 SpringBoard(pid=%d), socket 已连接", _springBoardPid];
}

#pragma mark - SpringBoard pid

- (pid_t)findSpringBoardPid {
    // 用 sysctl 遍历进程 (KERN_PROC_ALL), 不依赖 libproc/shell/grep/launchctl
    // (libproc.h 仅存在于 macOS, iOS SDK 没有; iOS 上也没有 /usr/bin/grep)
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) return -1;

    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return -1;
    memset(procs, 0, size);
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) {
        free(procs);
        return -1;
    }

    int count = (int)(size / sizeof(struct kinfo_proc));
    pid_t result = -1;
    for (int i = 0; i < count; i++) {
        if (procs[i].kp_proc.p_comm[0] != '\0' &&
            strcmp(procs[i].kp_proc.p_comm, "SpringBoard") == 0) {
            result = procs[i].kp_proc.p_pid;
            break;
        }
    }
    free(procs);
    return result;
}

#pragma mark - 文件部署 (opainject + dylib -> Documents)

- (BOOL)deployBinaries {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) return NO;
    NSString *binDir = [docs stringByAppendingPathComponent:@"bin"];
    [fm createDirectoryAtPath:binDir withIntermediateDirectories:YES attributes:nil error:NULL];

    // 注入器 (bundle/bin/opainject -> Documents/bin/opainject)
    NSString *injectorSrc = [[NSBundle mainBundle] pathForResource:@"opainject" ofType:nil inDirectory:@"bin"];
    NSString *injectorDst = [binDir stringByAppendingPathComponent:@"opainject"];
    if (!injectorSrc) {
        NSLog(@"[TSInjectedTouch] bundle 中找不到 opainject");
        return NO;
    }
    // 每次强制覆盖, 避免旧版本二进制残留 (此前仅不存在时拷贝, bundle 更新后 Documents 里仍是旧文件)
    [fm removeItemAtPath:injectorDst error:NULL];
    [fm copyItemAtPath:injectorSrc toPath:injectorDst error:NULL];
    chmod(injectorDst.UTF8String, 0755);

    // 触摸服务 dylib (bundle/bin/TSInjectedTouchService.dylib -> Documents/bin/)
    NSString *dylibSrc = [[NSBundle mainBundle] pathForResource:@"TSInjectedTouchService" ofType:@"dylib" inDirectory:@"bin"];
    NSString *dylibDst = [binDir stringByAppendingPathComponent:@"TSInjectedTouchService.dylib"];
    if (!dylibSrc) {
        NSLog(@"[TSInjectedTouch] bundle 中找不到 TSInjectedTouchService.dylib");
        return NO;
    }
    [fm removeItemAtPath:dylibDst error:NULL];
    [fm copyItemAtPath:dylibSrc toPath:dylibDst error:NULL];
    chmod(dylibDst.UTF8String, 0755);

    // 重签工具链保留部署 (与原版 bin/ 一致), 但运行时不再使用——重签会剥离
    // opainject 原版的 system-task-ports/platform-application 权限并破坏 arm64e
    // 签名。此处保留仅为对齐原版文件结构, 供后续排查/备用。
    NSArray<NSString *> *tools = @[@"ldid", @"fastPathSign"];
    for (NSString *tool in tools) {
        NSString *src = [[NSBundle mainBundle] pathForResource:tool ofType:nil inDirectory:@"bin"];
        NSString *dst = [binDir stringByAppendingPathComponent:tool];
        if (src) {
            [fm removeItemAtPath:dst error:NULL];
            [fm copyItemAtPath:src toPath:dst error:NULL];
            chmod(dst.UTF8String, 0755);
        } else {
            NSLog(@"[TSInjectedTouch] bundle 中找不到 %@", tool);
        }
    }
    NSArray<NSString *> *plists = @[@"ent2.xml", @"injector.entitlements.xml"];
    for (NSString *plist in plists) {
        NSString *src = [[NSBundle mainBundle] pathForResource:plist.stringByDeletingPathExtension ofType:plist.pathExtension inDirectory:@"bin"];
        if (!src && [plist isEqualToString:@"injector.entitlements.xml"]) {
            // injector.entitlements.xml 在 Resources 根目录 (不在 bin/ 下)
            src = [[NSBundle mainBundle] pathForResource:@"injector.entitlements" ofType:@"xml"];
        }
        if (src) {
            NSString *dst = [binDir stringByAppendingPathComponent:plist];
            [fm removeItemAtPath:dst error:NULL];
            [fm copyItemAtPath:src toPath:dst error:NULL];
        }
    }

    NSLog(@"[TSInjectedTouch] 部署完成: %@", dylibDst);
    return YES;
}

#pragma mark - 注入

- (BOOL)injectSpringBoard {
    pid_t pid = [self findSpringBoardPid];
    if (pid <= 0) {
        NSLog(@"[TSInjectedTouch] 未找到 SpringBoard 进程");
        return NO;
    }
    _springBoardPid = pid;

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *injectorPath = [docs stringByAppendingPathComponent:@"bin/opainject"];
    NSString *dylibPath = [docs stringByAppendingPathComponent:@"bin/TSInjectedTouchService.dylib"];

    // 注意: 不在运行时重签 opainject/dylib!
    // 原版 opainject 自带的签名已含完整 entitlements (com.apple.system-task-ports +
    // platform-application), CI 打包时也原样保留。运行时用 ldid 重签反而会剥离这些
    // 关键权限并破坏 arm64e slice 签名 (opainject dyld 崩溃 → 零输出 → log 为空)。
    // dylib 已在 CI 用 injector.entitlements.xml 签名 (platform-application),
    // TrollStore 安装时保留二进制内已嵌入的 entitlements, 无需再签。

    // opainject <pid> <dylib_path>
    const char *args[] = {
        injectorPath.UTF8String,
        [NSString stringWithFormat:@"%d", pid].UTF8String,
        dylibPath.UTF8String,
        NULL
    };

    // 捕获 opainject 的 stdout/stderr 到日志文件, 注入失败时能定位原因
    NSString *logPath = [docs stringByAppendingPathComponent:@"bin/opainject.log"];
    int logFD = open(logPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (logFD < 0) {
        _lastErrorStage = @"log-open";
        _lastErrorErrno = errno;
        NSLog(@"[TSInjectedTouch] 打开 opainject.log 失败: %d (%s) logPath=%@", errno, strerror(errno), logPath);
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    if (logFD >= 0) {
        posix_spawn_file_actions_adddup2(&actions, logFD, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, logFD);
    }

    pid_t child = -1;
    int rc = posix_spawn(&child, injectorPath.UTF8String, logFD >= 0 ? &actions : NULL, NULL,
                         (char *const *)args, environ);
    if (logFD >= 0) {
        posix_spawn_file_actions_destroy(&actions);
        close(logFD);
    }
    if (rc != 0) {
        _lastErrorStage = @"spawn";
        _lastErrorErrno = rc;
        NSLog(@"[TSInjectedTouch] posix_spawn opainject 失败: %d (%s)", rc, strerror(rc));
        return NO;
    }

    int status = 0;
    waitpid(child, &status, 0);
    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    NSLog(@"[TSInjectedTouch] opainject 退出, status=%d exit=%d (SpringBoard pid=%d)", status, exitCode, pid);

    // 读回注入日志 (opainject 的具体错误信息)
    NSString *out = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:NULL];
    if (out.length > 0) {
        NSLog(@"[TSInjectedTouch] opainject 输出:\n%@", out);
    } else {
        NSLog(@"[TSInjectedTouch] opainject 无输出 (logPath=%@)", logPath);
    }

    // 读回 SpringBoard 侧 dylib 日志 (constructor 在 dlopen 时已同步执行)
    NSString *dylibLog = [NSString stringWithContentsOfFile:@"/tmp/ts_touch.log" encoding:NSUTF8StringEncoding error:NULL];
    if (dylibLog.length > 0) {
        NSLog(@"[TSInjectedTouch] SpringBoard dylib 日志:\n%@", dylibLog);
    }

    // opainject 正常退出且 exit code 为 0 才算注入成功
    if (WIFEXITED(status) && exitCode == 0) {
        _lastErrorStage = nil;
        _lastErrorErrno = 0;
        return YES;
    }
    return NO;
}

#pragma mark - socket

- (BOOL)connectSocket {
    if (_socketFD >= 0) return YES;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(TS_TOUCH_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    struct timeval tv = {1, 0}; // 1s 连接超时
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        int err = errno;
        NSLog(@"[TSInjectedTouch] connect 127.0.0.1:%d 失败: %d (%s)", TS_TOUCH_PORT, err, strerror(err));
        close(fd);
        return NO;
    }
    _socketFD = fd;
    NSLog(@"[TSInjectedTouch] socket 已连接 127.0.0.1:%d", TS_TOUCH_PORT);
    return YES;
}

- (BOOL)ensureInjected {
    if (_injected && _socketFD >= 0) return YES;
    if (_injectFailed) return NO;

    if (![self deployBinaries]) {
        _lastErrorStage = @"deploy";
        _injectFailed = YES;
        return NO;
    }

    // 注入 + 等待服务端就绪 (最多 ~4s)
    for (int attempt = 0; attempt < 3; attempt++) {
        if (![self injectSpringBoard]) {
            // opainject 本身失败, 不再重试
            _injectFailed = YES;
            return NO;
        }
        // 等待 dylib 加载 + socket server 启动
        for (int i = 0; i < 10; i++) {
            usleep(200 * 1000);
            if ([self connectSocket]) {
                _injected = YES;
                return YES;
            }
        }
        NSLog(@"[TSInjectedTouch] 第 %d 次注入后未连上服务, 重试", attempt + 1);
    }
    _injectFailed = YES;
    return NO;
}

#pragma mark - 发送

- (void)sendTouchType:(uint8_t)type index:(uint8_t)index point:(CGPoint)point {
    if (![self ensureInjected]) return;

    // 归一化坐标 (物理像素 / 屏幕物理尺寸)
    CGRect bounds = [UIScreen mainScreen].bounds;
    float x = bounds.size.width  > 0 ? (float)(point.x / bounds.size.width)  : 0.0f;
    float y = bounds.size.height > 0 ? (float)(point.y / bounds.size.height) : 0.0f;

    uint8_t cmd[2 + TS_TOUCH_PER_FINGER];
    cmd[0] = TS_TOUCH_MAGIC;
    cmd[1] = 1;                      // count
    cmd[2] = (uint8_t)(type & 0xFF); // type
    cmd[3] = (uint8_t)(index & 0xFF);// index
    memcpy(cmd + 4, &x, 4);
    memcpy(cmd + 8, &y, 4);

    ssize_t n = send(_socketFD, cmd, sizeof(cmd), 0);
    if (n < 0) {
        // 连接断开, 关闭以便下次重连
        close(_socketFD);
        _socketFD = -1;
    }
}

@end
