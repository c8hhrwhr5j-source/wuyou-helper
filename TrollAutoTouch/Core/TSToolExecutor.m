//
//  TSToolExecutor.m
//  TrollAutoTouch
//
//  系统工具执行器实现。
//  在 ObjC 层实现原版 busybox 工具集的核心功能。
//

#import "TSToolExecutor.h"
#import <spawn.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/mount.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <ifaddrs.h>
#import <netdb.h>
#import <dirent.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/time.h>
#import <errno.h>
#import <string.h>

// ── posix_spawn 的私有 persona API ──
// 来源: TrollServer / TrollStore，允许以 root 身份 spawn 子进程
extern int posix_spawnattr_set_persona_np(posix_spawnattr_t * __restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(posix_spawnattr_t * __restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(posix_spawnattr_t * __restrict, gid_t);

static const uint32_t POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE = 1;
static const uid_t    POSIX_SPAWN_PERSONA_ID_ROOT       = 99;

// libproc / proc_info 声明(macOS 专用头文件，iOS SDK 中不存在)
// 这些函数在 iOS 运行时存在但头文件中未公开
#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 4096
#endif
#ifndef PROC_PIDTASKINFO
#define PROC_PIDTASKINFO         4
#endif

#ifndef PROC_TASKINFO_DEFINED
#define PROC_TASKINFO_DEFINED
struct proc_taskinfo {
    uint64_t        pti_virtual_size;
    uint64_t        pti_resident_size;
    uint64_t        pti_total_user;
    uint64_t        pti_total_system;
    uint64_t        pti_threads_user;
    uint64_t        pti_threads_system;
    int32_t         pti_policy;
    int32_t         pti_faults;
    int32_t         pti_pageins;
    int32_t         pti_cow_faults;
    int32_t         pti_messages_sent;
    int32_t         pti_messages_received;
    int32_t         pti_syscalls_mach;
    int32_t         pti_syscalls_unix;
    int32_t         pti_csw;
    int32_t         pti_threadnum;
    int32_t         pti_numrunning;
    int32_t         pti_priority;
    uint64_t        pti_start_time;
};
#endif

extern int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

#pragma mark - 结果类型

@implementation TSCmdResult
- (NSString *)description {
    return [NSString stringWithFormat:@"<TSCmdResult exit=%d elapsed=%.3fs out=\"%@\" err=\"%@\">",
            _exitCode, _elapsed,
            _standardOutput.length > 100 ? [[_standardOutput substringToIndex:100] stringByAppendingString:@"..."] : _standardOutput,
            _standardError.length > 100 ? [[_standardError substringToIndex:100] stringByAppendingString:@"..."] : _standardError];
}
@end

@implementation TSProcessInfo
- (NSString *)description {
    return [NSString stringWithFormat:@"<Process pid=%d name=\"%@\">", _pid, _name];
}
@end

@implementation TSFileEntry
- (NSString *)description {
    return [NSString stringWithFormat:@"<File \"%@\" %c size=%lld>",
            _name, _isDirectory ? 'd' : 'f', (long long)_size];
}
@end

#pragma mark - TSToolExecutor

@interface TSToolExecutor ()
@property (nonatomic, strong) dispatch_queue_t execQueue;
@end

@implementation TSToolExecutor

+ (instancetype)shared {
    static TSToolExecutor *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[TSToolExecutor alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _execQueue = dispatch_queue_create("com.trollautotouch.toolexec", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

#pragma mark - Shell 命令

- (TSCmdResult *)executeCommand:(NSString *)command {
    return [self executeCommand:command timeout:30];
}

- (TSCmdResult *)executeCommand:(NSString *)command timeout:(NSTimeInterval)timeout {
    TSCmdResult *result = [[TSCmdResult alloc] init];
    NSTimeInterval start = [[NSDate date] timeIntervalSince1970];

    // 创建管道
    int outPipe[2], errPipe[2];
    pipe(outPipe);
    pipe(errPipe);

    // 设置非阻塞
    fcntl(outPipe[0], F_SETFL, O_NONBLOCK);
    fcntl(errPipe[0], F_SETFL, O_NONBLOCK);

    pid_t pid;
    char *argv[] = {"/bin/sh", "-c", (char *)[command UTF8String], NULL};

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    // ── 以 root 身份 spawn（需要 platform-application + persona-mgmt 权限）──
    posix_spawnattr_set_persona_np(&attr, POSIX_SPAWN_PERSONA_ID_ROOT, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, outPipe[0]);
    posix_spawn_file_actions_addclose(&actions, errPipe[0]);

    int spawnErr = posix_spawn(&pid, "/bin/sh", &actions, &attr, argv, NULL);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);

    // 关闭写端
    close(outPipe[1]);
    close(errPipe[1]);

    if (spawnErr != 0) {
        close(outPipe[0]);
        close(errPipe[0]);
        result.exitCode = -1;
        result.standardError = [NSString stringWithFormat:@"spawn error: %s", strerror(spawnErr)];
        result.elapsed = [[NSDate date] timeIntervalSince1970] - start;
        return result;
    }

    // 读取输出
    NSMutableData *outData = [NSMutableData data];
    NSMutableData *errData = [NSMutableData data];

    int status = 0;
    NSTimeInterval deadline = start + timeout;

    while (1) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now > deadline) {
            kill(pid, SIGKILL);
            result.exitCode = -2;
            result.standardError = @"命令执行超时";
            break;
        }

        // 检查进程是否结束
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid) {
            result.exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
            break;
        }

        // 读取输出
        uint8_t buf[4096];
        ssize_t n;

        n = read(outPipe[0], buf, sizeof(buf));
        if (n > 0) [outData appendBytes:buf length:n];

        n = read(errPipe[0], buf, sizeof(buf));
        if (n > 0) [errData appendBytes:buf length:n];

        usleep(5000); // 5ms
    }

    // 清空剩余数据
    uint8_t buf[4096];
    ssize_t n;
    while ((n = read(outPipe[0], buf, sizeof(buf))) > 0) [outData appendBytes:buf length:n];
    while ((n = read(errPipe[0], buf, sizeof(buf))) > 0) [errData appendBytes:buf length:n];

    close(outPipe[0]);
    close(errPipe[0]);

    result.standardOutput = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: @"";
    result.standardError = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: result.standardError ?: @"";
    result.elapsed = [[NSDate date] timeIntervalSince1970] - start;

    return result;
}

- (void)executeCommand:(NSString *)command completion:(void (^)(TSCmdResult *))completion {
    dispatch_async(_execQueue, ^{
        TSCmdResult *result = [self executeCommand:command];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    });
}

#pragma mark - 文件管理

- (NSArray<TSFileEntry *> *)listDirectory:(NSString *)path {
    return [self listDirectory:path recursive:NO];
}

- (NSArray<TSFileEntry *> *)listDirectoryRecursive:(NSString *)path {
    return [self listDirectory:path recursive:YES];
}

- (NSArray<TSFileEntry *> *)listDirectory:(NSString *)path recursive:(BOOL)recursive {
    NSMutableArray<TSFileEntry *> *entries = [NSMutableArray array];
    [self _listPath:path into:entries recursive:recursive];
    return entries;
}

- (void)_listPath:(NSString *)path into:(NSMutableArray *)entries recursive:(BOOL)recursive {
    DIR *dir = opendir([path UTF8String]);
    if (!dir) return;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;

        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        NSString *full = [path stringByAppendingPathComponent:name];

        TSFileEntry *fe = [[TSFileEntry alloc] init];
        fe.name = name;
        fe.path = full;
        fe.isDirectory = (entry->d_type == DT_DIR);

        struct stat st;
        if (lstat([full UTF8String], &st) == 0) {
            fe.size = st.st_size;
            fe.permissions = st.st_mode & 0777;
            fe.modificationDate = [NSDate dateWithTimeIntervalSince1970:st.st_mtimespec.tv_sec];
            fe.isDirectory = S_ISDIR(st.st_mode);
        }

        [entries addObject:fe];

        if (recursive && fe.isDirectory) {
            [self _listPath:full into:entries recursive:YES];
        }
    }
    closedir(dir);
}

- (nullable TSFileEntry *)fileInfo:(NSString *)path {
    struct stat st;
    if (lstat([path UTF8String], &st) != 0) return nil;

    TSFileEntry *fe = [[TSFileEntry alloc] init];
    fe.name = [path lastPathComponent];
    fe.path = path;
    fe.isDirectory = S_ISDIR(st.st_mode);
    fe.size = st.st_size;
    fe.permissions = st.st_mode & 0777;
    fe.modificationDate = [NSDate dateWithTimeIntervalSince1970:st.st_mtimespec.tv_sec];

    return fe;
}

- (BOOL)fileExists:(NSString *)path {
    return access([path UTF8String], F_OK) == 0;
}

- (off_t)fileSize:(NSString *)path {
    struct stat st;
    if (stat([path UTF8String], &st) != 0) return -1;
    return st.st_size;
}

- (nullable NSString *)readTextFile:(NSString *)path {
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)writeTextFile:(NSString *)path content:(NSString *)content {
    return [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)copyItem:(NSString *)src to:(NSString *)dst {
    return [[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:nil];
}

- (BOOL)moveItem:(NSString *)src to:(NSString *)dst {
    return [[NSFileManager defaultManager] moveItemAtPath:src toPath:dst error:nil];
}

- (BOOL)removeItem:(NSString *)path {
    return [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

- (BOOL)createDirectory:(NSString *)path {
    return [[NSFileManager defaultManager] createDirectoryAtPath:path
                                     withIntermediateDirectories:YES attributes:nil error:nil];
}

- (BOOL)isReadable:(NSString *)path  { return access([path UTF8String], R_OK) == 0; }
- (BOOL)isWritable:(NSString *)path  { return access([path UTF8String], W_OK) == 0; }
- (BOOL)isExecutable:(NSString *)path { return access([path UTF8String], X_OK) == 0; }

#pragma mark - 进程管理

- (NSArray<TSProcessInfo *> *)runningProcesses {
    NSMutableArray *procs = [NSMutableArray array];

    // 获取所有 PID
    int bufSize = proc_listallpids(NULL, 0);
    if (bufSize <= 0) return @[];

    pid_t *pids = (pid_t *)malloc((size_t)bufSize);
    bufSize = proc_listallpids(pids, bufSize);
    if (bufSize <= 0) { free(pids); return @[]; }

    int numPids = bufSize / (int)sizeof(pid_t);

    for (int i = 0; i < numPids; i++) {
        TSProcessInfo *info = [self processInfoForPID:pids[i]];
        if (info) [procs addObject:info];
    }

    free(pids);
    return procs;
}

- (NSArray<TSProcessInfo *> *)findProcessesByName:(NSString *)name {
    NSMutableArray *results = [NSMutableArray array];
    for (TSProcessInfo *info in [self runningProcesses]) {
        if ([info.name isEqualToString:name] || [info.name containsString:name]) {
            [results addObject:info];
        }
    }
    return results;
}

- (nullable TSProcessInfo *)processInfoForPID:(pid_t)pid {
    // 获取进程名称
    char nameBuf[256] = {0};
    proc_name(pid, nameBuf, sizeof(nameBuf));

    if (nameBuf[0] == 0) return nil; // 进程不存在或无权限

    TSProcessInfo *info = [[TSProcessInfo alloc] init];
    info.pid = pid;
    info.name = [NSString stringWithUTF8String:nameBuf];

    // 获取进程路径
    char pathBuf[PROC_PIDPATHINFO_MAXSIZE] = {0};
    proc_pidpath(pid, pathBuf, sizeof(pathBuf));
    if (pathBuf[0]) info.path = [NSString stringWithUTF8String:pathBuf];

    // 获取启动时间
    struct proc_taskinfo pti;
    int ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &pti, (int)sizeof(pti));
    if (ret > 0) {
        struct timeval boottime;
        size_t len = sizeof(boottime);
        int mib[2] = {CTL_KERN, KERN_BOOTTIME};
        if (sysctl(mib, 2, &boottime, &len, NULL, 0) == 0) {
            NSTimeInterval boot = boottime.tv_sec + boottime.tv_usec / 1000000.0;
            NSTimeInterval start = boot + pti.pti_start_time / 1000000000.0;
            info.startTime = [NSDate dateWithTimeIntervalSince1970:start];
        }
    }

    return info;
}

- (BOOL)killProcess:(pid_t)pid {
    return kill(pid, SIGTERM) == 0 || kill(pid, SIGKILL) == 0;
}

- (BOOL)killProcessByName:(NSString *)name {
    BOOL killedAny = NO;
    for (TSProcessInfo *info in [self findProcessesByName:name]) {
        if ([self killProcess:info.pid]) killedAny = YES;
    }
    return killedAny;
}

- (BOOL)processExists:(pid_t)pid {
    return kill(pid, 0) == 0;
}

#pragma mark - 网络工具

- (NSDictionary<NSString *, NSDictionary *> *)networkInterfaces {
    NSMutableDictionary *interfaces = [NSMutableDictionary dictionary];
    struct ifaddrs *ifAddrList = NULL;
    if (getifaddrs(&ifAddrList) != 0) return interfaces;

    struct ifaddrs *cursor = ifAddrList;
    while (cursor) {
        NSString *name = [NSString stringWithUTF8String:cursor->ifa_name];

        NSMutableDictionary *info = interfaces[name] ?: [NSMutableDictionary dictionary];

        if (cursor->ifa_addr->sa_family == AF_INET) {
            char addrStr[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &((struct sockaddr_in *)cursor->ifa_addr)->sin_addr, addrStr, sizeof(addrStr));
            info[@"ipv4"] = [NSString stringWithUTF8String:addrStr];

            char maskStr[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &((struct sockaddr_in *)cursor->ifa_netmask)->sin_addr, maskStr, sizeof(maskStr));
            info[@"netmask"] = [NSString stringWithUTF8String:maskStr];
        } else if (cursor->ifa_addr->sa_family == AF_INET6) {
            char addrStr[INET6_ADDRSTRLEN];
            inet_ntop(AF_INET6, &((struct sockaddr_in6 *)cursor->ifa_addr)->sin6_addr, addrStr, sizeof(addrStr));
            info[@"ipv6"] = [NSString stringWithUTF8String:addrStr];
        }

        info[@"flags"] = @(cursor->ifa_flags);
        interfaces[name] = info;
        cursor = cursor->ifa_next;
    }
    freeifaddrs(ifAddrList);
    return interfaces;
}

- (BOOL)isPortAvailable:(uint16_t)port {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return NO;

    int opt = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    int ret = bind(sock, (struct sockaddr *)&addr, sizeof(addr));
    close(sock);
    return ret == 0;
}

- (nullable NSString *)wifiIPAddress {
    struct ifaddrs *interfaces = NULL;
    NSString *ip = nil;

    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *cursor = interfaces; cursor; cursor = cursor->ifa_next) {
            if (cursor->ifa_addr && cursor->ifa_addr->sa_family == AF_INET) {
                NSString *name = [NSString stringWithUTF8String:cursor->ifa_name];
                if ([name isEqualToString:@"en0"]) {
                    char addrStr[INET_ADDRSTRLEN];
                    inet_ntop(AF_INET, &((struct sockaddr_in *)cursor->ifa_addr)->sin_addr, addrStr, sizeof(addrStr));
                    ip = [NSString stringWithUTF8String:addrStr];
                    break;
                }
            }
        }
        freeifaddrs(interfaces);
    }
    return ip;
}

- (nullable NSString *)cellularIPAddress {
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *cursor = NULL;
    NSString *ip = nil;

    if (getifaddrs(&interfaces) == 0) {
        cursor = interfaces;
        while (cursor) {
            if (cursor->ifa_addr->sa_family == AF_INET) {
                NSString *name = [NSString stringWithUTF8String:cursor->ifa_name];
                if ([name hasPrefix:@"pdp_ip"] || [name hasPrefix:@"utun"]) {
                    char addrStr[INET_ADDRSTRLEN];
                    inet_ntop(AF_INET, &((struct sockaddr_in *)cursor->ifa_addr)->sin_addr, addrStr, sizeof(addrStr));
                    ip = [NSString stringWithUTF8String:addrStr];
                    break;
                }
            }
            cursor = cursor->ifa_next;
        }
        freeifaddrs(interfaces);
    }
    return ip;
}

- (void)httpGet:(NSString *)url completion:(void (^)(NSData * _Nullable, NSError * _Nullable))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                   timeoutInterval:30];
    req.HTTPMethod = @"GET";
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(data, error); });
        }
    }] resume];
}

- (void)httpPost:(NSString *)url body:(NSData *)body contentType:(NSString *)contentType
      completion:(void (^)(NSData * _Nullable, NSError * _Nullable))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                   timeoutInterval:30];
    req.HTTPMethod = @"POST";
    req.HTTPBody = body;
    [req setValue:contentType ?: @"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(data, error); });
        }
    }] resume];
}

#pragma mark - FTP 下载 (明文标准 FTP, 同步阻塞)

// ── FTP 协议工具函数 ──
// 全部用 BSD socket 自实现是因为 iOS 的 NSURLSession 不支持 ftp:// scheme。

// 从 FTP 控制连接读一行(以 \r\n 结尾), 直到拿到 "NNN " 形式的最终响应行
// (RFC 959 多行响应的中间行是 "NNN-", 末行是 "NNN "), 返回 3 位响应码,
// 把 "NNN " 之后的描述文本写入 outText (outTextCap 含终止符)。
// 失败/关闭/超时返回 -1。
static int ftp_read_response(int sock, char *outText, size_t outTextCap) {
    char line[1024];
    for (;;) {
        size_t pos = 0;
        for (;;) {
            char c = 0;
            ssize_t n = recv(sock, &c, 1, 0);
            if (n <= 0) return -1;       // EOF 或 recv 错误/超时
            if (c == '\n') break;
            if (pos < sizeof(line) - 1) line[pos++] = c;
        }
        if (pos > 0 && line[pos-1] == '\r') pos--;
        line[pos] = '\0';
        if (pos < 4) continue;          // 不足 4 字符(应至少 "NNN-x"), 跳过
        if (line[3] == ' ') {           // 末行: "NNN text"
            int code = (line[0]-'0')*100 + (line[1]-'0')*10 + (line[2]-'0');
            if (outText && outTextCap > 0) {
                size_t copyLen = pos - 4;
                if (copyLen >= outTextCap) copyLen = outTextCap - 1;
                memcpy(outText, line + 4, copyLen);
                outText[copyLen] = '\0';
            }
            return code;
        }
        // 中间行: "NNN-text" 继续读
    }
}

// 发送一行 FTP 命令(末尾自动追加 \r\n)并读取一次响应。
// 返回响应码, 描述文本写入 outText。返回 -1 表示发送/读取失败。
static int ftp_send_cmd(int sock, const char *cmd, char *outText, size_t outTextCap) {
    NSMutableData *d = [NSMutableData dataWithBytes:cmd length:strlen(cmd)];
    [d appendBytes:"\r\n" length:2];
    if (send(sock, d.bytes, d.length, 0) != (ssize_t)d.size) return -1;
    return ftp_read_response(sock, outText, outTextCap);
}

// 设置 socket 的收发超时(秒)
static void ftp_set_timeout(int sock, int sec) {
    struct timeval tv = { sec, 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

// 包装 errno 为 NSError
static NSError *ftp_error(int errCode, NSString *msg) {
    return [NSError errorWithDomain:@"TSFTP" code:errCode
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"FTP 操作失败"}];
}

- (BOOL)ftpDownloadHost:(NSString *)host
                   port:(uint16_t)port
                   user:(NSString *)user
               password:(NSString *)password
             remotePath:(NSString *)remotePath
              localPath:(NSString *)localPath
                  error:(NSError **)error
{
    if (host.length == 0 || remotePath.length == 0 || localPath.length == 0) {
        if (error) *error = ftp_error(1, @"参数缺失 (host/remotePath/localPath 必填)");
        return NO;
    }
    if (port == 0) port = 21;
    if (user.length == 0) user = @"anonymous";
    if (password.length == 0) password = @"anonymous@";
    const int timeoutSec = 30;

    // ── 1. 解析 host (支持域名/IPv4) ──
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;          // 仅 IPv4 (PASV 协议最简单)
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = NULL;
    int gai = getaddrinfo(host.UTF8String, NULL, &hints, &res);
    if (gai != 0 || !res) {
        if (error) *error = ftp_error(2, [NSString stringWithFormat:@"域名解析失败: %s", gai == 0 ? "无结果" : gai_strerror(gai)]);
        if (res) freeaddrinfo(res);
        return NO;
    }
    struct sockaddr_in ctrlAddr;
    memcpy(&ctrlAddr, res->ai_addr, sizeof(ctrlAddr));
    ctrlAddr.sin_port = htons(port);
    freeaddrinfo(res);

    // ── 2. 控制 socket 连接 ──
    int ctrl = socket(AF_INET, SOCK_STREAM, 0);
    if (ctrl < 0) {
        if (error) *error = ftp_error(3, @"socket() 创建失败");
        return NO;
    }
    ftp_set_timeout(ctrl, timeoutSec);
    if (connect(ctrl, (struct sockaddr *)&ctrlAddr, sizeof(ctrlAddr)) != 0) {
        int e = errno;
        NSString *m = [NSString stringWithFormat:@"连接 %@:%u 失败: %s", host, port, strerror(e)];
        close(ctrl);
        if (error) *error = ftp_error(4, m);
        return NO;
    }

    // ── 3. 读取欢迎横幅 220 ──
    char resp[1024];
    int code = ftp_read_response(ctrl, resp, sizeof(resp));
    if (code != 220) {
        close(ctrl);
        if (error) *error = ftp_error(5, [NSString stringWithFormat:@"非 220 欢迎: %d %s", code, resp]);
        return NO;
    }

    // ── 4. USER ──
    char userBuf[256];
    snprintf(userBuf, sizeof(userBuf), "USER %s", user.UTF8String);
    code = ftp_send_cmd(ctrl, userBuf, resp, sizeof(resp));
    if (code != 331 && code != 230) {       // 331 需密码; 230 已登录(匿名直接过)
        close(ctrl);
        if (error) *error = ftp_error(6, [NSString stringWithFormat:@"USER 失败: %d %s", code, resp]);
        return NO;
    }
    if (code == 331) {
        // ── 5. PASS ──
        char passBuf[256];
        snprintf(passBuf, sizeof(passBuf), "PASS %s", password.UTF8String);
        code = ftp_send_cmd(ctrl, passBuf, resp, sizeof(resp));
        if (code != 230) {
            close(ctrl);
            if (error) *error = ftp_error(7, [NSString stringWithFormat:@"PASS 失败 (账号或密码错误): %d %s", code, resp]);
            return NO;
        }
    }

    // ── 6. TYPE I (二进制, 后续 RETR 按字节流读) ──
    code = ftp_send_cmd(ctrl, "TYPE I", resp, sizeof(resp));
    if (code != 200) {
        close(ctrl);
        if (error) *error = ftp_error(8, [NSString stringWithFormat:@"TYPE I 失败: %d %s", code, resp]);
        return NO;
    }

    // ── 7. SIZE 远端文件 (RFC 3659, best-effort) ──
    char sizeBuf[1024];
    snprintf(sizeBuf, sizeof(sizeBuf), "SIZE %s", remotePath.UTF8String);
    code = ftp_send_cmd(ctrl, sizeBuf, resp, sizeof(resp));
    int64_t expectedSize = -1;
    if (code == 213) {
        expectedSize = strtoll(resp, NULL, 10);
    }
    // 550 = 文件不存在, 直接终止
    if (code == 550) {
        close(ctrl);
        if (error) *error = ftp_error(9, [NSString stringWithFormat:@"远端文件不存在: %@", remotePath]);
        return NO;
    }

    // ── 8. PASV 解析数据通道地址 ──
    code = ftp_send_cmd(ctrl, "PASV", resp, sizeof(resp));
    if (code != 227) {
        close(ctrl);
        if (error) *error = ftp_error(10, [NSString stringWithFormat:@"PASV 失败: %d %s", code, resp]);
        return NO;
    }
    char *p = strchr(resp, '(');
    if (!p) {
        close(ctrl);
        if (error) *error = ftp_error(11, @"PASV 响应未含地址括号");
        return NO;
    }
    int h1=0, h2=0, h3=0, h4=0, p1=0, p2=0;
    if (sscanf(p, "(%d,%d,%d,%d,%d,%d)", &h1, &h2, &h3, &h4, &p1, &p2) != 6) {
        close(ctrl);
        if (error) *error = ftp_error(12, [NSString stringWithFormat:@"PASV 地址解析失败: %s", resp]);
        return NO;
    }
    char dataIP[64];
    snprintf(dataIP, sizeof(dataIP), "%d.%d.%d.%d", h1, h2, h3, h4);
    uint16_t dataPort = (uint16_t)(p1 * 256 + p2);

    // ── 9. 连接数据 socket ──
    struct sockaddr_in dataAddr;
    memset(&dataAddr, 0, sizeof(dataAddr));
    dataAddr.sin_family = AF_INET;
    dataAddr.sin_port = htons(dataPort);
    inet_pton(AF_INET, dataIP, &dataAddr.sin_addr);
    int data = socket(AF_INET, SOCK_STREAM, 0);
    if (data < 0) {
        close(ctrl);
        if (error) *error = ftp_error(13, @"data socket() 创建失败");
        return NO;
    }
    ftp_set_timeout(data, timeoutSec);
    if (connect(data, (struct sockaddr *)&dataAddr, sizeof(dataAddr)) != 0) {
        int e = errno;
        NSString *m = [NSString stringWithFormat:@"连接数据通道 %s:%d 失败: %s",
                       dataIP, dataPort, strerror(e)];
        close(data);
        close(ctrl);
        if (error) *error = ftp_error(14, m);
        return NO;
    }

    // ── 10. RETR ──
    char retrBuf[1024];
    snprintf(retrBuf, sizeof(retrBuf), "RETR %s", remotePath.UTF8String);
    code = ftp_send_cmd(ctrl, retrBuf, resp, sizeof(resp));
    if (code != 150 && code != 125) {
        close(data);
        close(ctrl);
        if (error) *error = ftp_error(15, [NSString stringWithFormat:@"RETR 失败: %d %s", code, resp]);
        return NO;
    }

    // ── 11. 确保本地目录存在, 创建空文件 ──
    NSString *parentDir = [localPath stringByDeletingLastPathComponent];
    if (parentDir.length) {
        [[NSFileManager defaultManager] createDirectoryAtPath:parentDir
            withIntermediateDirectories:YES attributes:nil error:nil];
    }
    int fd = open(localPath.UTF8FileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        int e = errno;
        NSString *m = [NSString stringWithFormat:@"创建本地文件失败: %s", strerror(e)];
        close(data);
        close(ctrl);
        if (error) *error = ftp_error(16, m);
        return NO;
    }

    // ── 12. 边读数据 socket 边写本地文件, 写完循环到 EOF ──
    char buf[8192];
    int64_t total = 0;
    BOOL writeFail = NO;
    while (1) {
        ssize_t n = recv(data, buf, sizeof(buf), 0);
        if (n == 0) break;                // 对端正常关闭 → 传输结束
        if (n < 0) {
            if (errno == EINTR) continue;  // 被信号打断, 重试
            int e = errno;
            NSString *m = [NSString stringWithFormat:@"数据通道 recv 失败: %s", strerror(e)];
            writeFail = YES;
            if (error) *error = ftp_error(17, m);
            break;
        }
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(fd, buf + off, (size_t)(n - off));
            if (w <= 0) {
                if (errno == EINTR) continue;
                int e = errno;
                NSString *m = [NSString stringWithFormat:@"本地 write 失败: %s", strerror(e)];
                writeFail = YES;
                if (error) *error = ftp_error(18, m);
                break;
            }
            off += w;
        }
        if (writeFail) break;
        total += n;
    }
    close(fd);
    close(data);

    // ── 13. 等待控制连接 226 Transfer complete ──
    code = ftp_read_response(ctrl, resp, sizeof(resp));
    BOOL transferOk = (code == 226 || code == 250);
    if (writeFail || !transferOk) {
        if (!writeFail && error && *error == nil) {
            *error = ftp_error(19, [NSString stringWithFormat:@"传输结束码异常: %d %s", code, resp]);
        }
        close(ctrl);
        return NO;
    }

    // ── 14. SIZE 校验(若服务器支持) ──
    if (expectedSize >= 0 && total != expectedSize) {
        if (error) *error = ftp_error(20,
            [NSString stringWithFormat:@"传输字节数与 SIZE 不符: 实际 %lld, 期望 %lld",
             (long long)total, (long long)expectedSize]);
        close(ctrl);
        return NO;
    }

    // ── 15. QUIT ──
    ftp_send_cmd(ctrl, "QUIT", resp, sizeof(resp));
    close(ctrl);

    NSLog(@"[FTP] 下载完成: %@:%u%@ -> %@ (%lld bytes)",
          host, port, remotePath, localPath, (long long)total);
    return YES;
}

#pragma mark - 设备信息

- (NSDictionary *)diskInfo {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    // 获取可用空间
    NSString *homePath = NSHomeDirectory();
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:homePath error:nil];
    if (attrs) {
        info[@"total"] = attrs[NSFileSystemSize];
        info[@"free"] = attrs[NSFileSystemFreeSize];
        info[@"used"] = @([attrs[NSFileSystemSize] unsignedLongLongValue] -
                           [attrs[NSFileSystemFreeSize] unsignedLongLongValue]);
    }

    // 使用 statfs 获取更多信息
    struct statfs fs;
    if (statfs([homePath UTF8String], &fs) == 0) {
        info[@"blockSize"] = @(fs.f_bsize);
        info[@"totalBlocks"] = @(fs.f_blocks);
        info[@"freeBlocks"] = @(fs.f_bfree);
    }

    return info;
}

- (NSDictionary *)memoryInfo {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    // 物理内存
    info[@"physicalMemory"] = @([NSProcessInfo processInfo].physicalMemory);

    // 使用 host_statistics 获取 VM 统计
    mach_port_t hostPort = mach_host_self();
    vm_size_t pageSize;
    host_page_size(hostPort, &pageSize);

    vm_statistics64_data_t vmStat;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(hostPort, HOST_VM_INFO64, (host_info_t)&vmStat, &count) == KERN_SUCCESS) {
        info[@"freePages"] = @(vmStat.free_count);
        info[@"activePages"] = @(vmStat.active_count);
        info[@"inactivePages"] = @(vmStat.inactive_count);
        info[@"wiredPages"] = @(vmStat.wire_count);
        info[@"freeMemory"] = @(vmStat.free_count * pageSize);
        info[@"usedMemory"] = @((vmStat.active_count + vmStat.inactive_count + vmStat.wire_count) * pageSize);
        info[@"pageSize"] = @(pageSize);
    }
    return info;
}

- (NSDictionary *)cpuInfo {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    // CPU 核心数
    info[@"activeProcessorCount"] = @([NSProcessInfo processInfo].activeProcessorCount);
    info[@"processorCount"] = @([NSProcessInfo processInfo].processorCount);

    // 从 sysctl 获取 CPU 品牌
    char brand[256] = {0};
    size_t len = sizeof(brand);
    if (sysctlbyname("machdep.cpu.brand_string", brand, &len, NULL, 0) == 0) {
        info[@"brand"] = [NSString stringWithUTF8String:brand];
    }

    // 架构
    info[@"architecture"] = sizeof(void *) == 8 ? @"arm64" : @"armv7";

    return info;
}

- (NSTimeInterval)systemUptime {
    struct timeval boottime;
    size_t len = sizeof(boottime);
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &boottime, &len, NULL, 0) == 0) {
        NSTimeInterval boot = boottime.tv_sec + boottime.tv_usec / 1000000.0;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        return now - boot;
    }
    return 0;
}

@end
