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

// ── 文件内 HTTP 静态工具函数的前向声明 ──
// TSHTTPDownloadDelegate (@implementation 在 @implementation TSToolExecutor 之前)
// 的 URLSession:dataTask:didReceiveResponse:completionHandler: 会调用
// http_contentLength(), 而 http_contentLength() 的函数体在 @implementation
// TSToolExecutor 内 (后续 L640 附近) 才定义。ISO C99 不允许隐式函数声明,
// 必须前向声明。
static int64_t http_contentLength(NSURLResponse *resp);

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

#pragma mark - TSHTTPDownloadDelegate (NSURLSessionDataDelegate)
//
// 把 NSURLSession 委托封装成一个小型 ObjC 类, 用于同步阻塞下载 (httpDownloadSync)。
// 该类必须在 @implementation TSToolExecutor 之前定义, 因为 ObjC 不允许
// @interface/@implementation 嵌套在另一个 @implementation 内部 (CI 失败过,
// 报 missing '@end')。
//
@interface TSHTTPDownloadDelegate : NSObject<NSURLSessionDataDelegate>
@property (atomic, assign) int64_t totalLength;     // -1 表示未知
@property (atomic, assign) int64_t currentLength;   // delegate 线程写, 任意线程读
@property (atomic, readonly) BOOL success;
@property (atomic, readonly) BOOL finished;         // 委托回调结束(成功或失败)
@property (atomic, readonly) NSError *lastError;
@end

@implementation TSHTTPDownloadDelegate {
@public
    NSFileHandle *_fileHandle;
    int _fd;
    int64_t _lastSampleBytes;
    NSTimeInterval _lastSampleTime;
    NSError *_lastError;
    BOOL _success;
    NSURLSessionDataTask *_dataTask;   // 由 httpDownloadSync 在创建后赋值, fireProgress 用于主动 cancel
}
- (void)openLocalFile:(NSString *)path {
    NSString *parent = [path stringByDeletingLastPathComponent];
    if (parent.length) {
        [[NSFileManager defaultManager] createDirectoryAtPath:parent
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    }
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    _fd = open([path fileSystemRepresentation], O_WRONLY);
    _fileHandle = (_fd >= 0) ? [[NSFileHandle alloc] initWithFileDescriptor:_fd
                                                            closeOnDealloc:NO] : nil;
}
- (void)closeLocalFile {
    if (_fileHandle) { [_fileHandle closeFile]; _fileHandle = nil; }
    if (_fd >= 0) { close(_fd); _fd = -1; }
}
- (NSURLSessionResponseDisposition)URLSession:(NSURLSession *)session
                               dataTask:(NSURLSessionDataTask *)dataTask
                               didReceiveResponse:(NSURLResponse *)response
                                completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    _totalLength = http_contentLength(response);
    // completionHandler 是 void(^)(NSURLSessionResponseDisposition), 调用后
    // 返回 void, 不能作为 NSURLSessionResponseDisposition 方法的 return 值。
    NSHTTPURLResponse *httpResp = [response isKindOfClass:[NSHTTPURLResponse class]]
                                ? (NSHTTPURLResponse *)response : nil;
    NSInteger statusCode = httpResp.statusCode;
    if (statusCode < 200 || statusCode >= 300) {
        // 非 2xx 视为下载失败: 阻止后续 data 写入本地文件, 并把 status code
        // 透传给 Lua 调用方 (避免把 404 HTML 错误页当成有效下载产物)。
        _success = NO;
        _lastError = [NSError errorWithDomain:@"TSHTTPDownload"
                                         code:statusCode
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"HTTP %ld", (long)statusCode],
                                                @"TSHTTPStatusCode": @(statusCode)}];
        completionHandler(NSURLSessionResponseCancel);
        // 显式 cancel, 确保 didCompleteWithError 触发 (NSURLErrorCancelled),
        // 配合 didCompleteWithError 中 `if (error && !_lastError)` 的保护,
        // 我们预设的 _lastError 不会被取消错误覆盖, _success 也会被算成 NO。
        [dataTask cancel];
        return NSURLSessionResponseCancel;
    }
    completionHandler(NSURLSessionResponseAllow);
    return NSURLSessionResponseAllow;
}
- (void)URLSession:(NSURLSession *)session
                dataTask:(NSURLSessionDataTask *)dataTask
   didReceiveData:(NSData *)data {
    if (!_fileHandle) return;
    @try {
        [_fileHandle writeData:data];
        // 累加已下载量 (data.length 已通过写入检查, 直接累加)
        _currentLength += (int64_t)data.length;
        // 计算瞬时速率
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (_lastSampleTime == 0) {
            _lastSampleTime = now;
            _lastSampleBytes = _currentLength;
        }
        int64_t speed = 0;
        NSTimeInterval dt = now - _lastSampleTime;
        if (dt >= 0.5) {
            speed = (int64_t)((double)(_currentLength - _lastSampleBytes) / dt);
            _lastSampleTime = now;
            _lastSampleBytes = _currentLength;
        }
        // 注: 进度回调不由委托线程触发, 而是 httpDownloadSync 主调用线程
        // 通过轮询 _currentLength / _totalLength 在自身 NSRunLoop 上触发,
        // 保证 Lua 进度回调在 Lua 线程上执行(避免跨线程访问 lua_State)。
    } @catch (NSException *e) {
        _lastError = [NSError errorWithDomain:@"TSHTTPDownload" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"写文件失败"}];
    }
}
- (void)URLSession:(NSURLSession *)session
                task:(NSURLSessionTask *)task
   didCompleteWithError:(NSError *)error {
    if (error && !_lastError) _lastError = error;
    _success = (error == nil && _lastError == nil);
    [self closeLocalFile];
    // 注: 写 _finished (property `finished` 的 backing ivar), 而非 _complete,
    // 两者是不同 ivar, httpDownloadSync 的 while (!del.finished) 等此值。
    _finished = YES;
}
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

#pragma mark - HTTP 同步请求 (用于 Lua http.get / http.post)

/// 把 NSDictionary<NSHTTPHeader*> 转成表头(用于"返回头")
static NSDictionary *http_responseHeaders(NSURLResponse *resp) {
    if (![resp isKindOfClass:[NSHTTPURLResponse class]]) return @{};
    NSDictionary *h = ((NSHTTPURLResponse *)resp).allHeaderFields;
    return h ?: @{};
}

/// HTTP body → 字符串(失败回退 latin1)
static NSString *http_bodyToString(NSData *data) {
    if (data.length == 0) return @"";
    // 优先 UTF-8 (中国大陆 Web 默认编码), 失败回退 ASCII/Latin-1
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (s) return s;
    return [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
}

/// 通用 HTTP 同步执行器 (GET / POST 共用)
///   requestBody == nil → GET, 否则 POST (Content-Type 用 application/x-www-form-urlencoded)
///   返回结构: { status:int, headers:NSDictionary, body:string }
static NSDictionary *http_performSync(NSString *url,
                                       NSTimeInterval timeoutSec,
                                       NSDictionary<NSString *, NSString *> *headers,
                                       NSString *requestBody) {
    NSURL *u = [NSURL URLWithString:url];
    if (!u) {
        return @{ @"status": @0, @"headers": @{}, @"body": @"URL 无效" };
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                   timeoutInterval:timeoutSec];
    req.HTTPMethod = requestBody ? @"POST" : @"GET";
    if (requestBody) {
        req.HTTPBody = [requestBody dataUsingEncoding:NSUTF8StringEncoding];
        [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    }
    // 默认 UA: TAS 头信息
    NSMutableDictionary *allHeaders = [NSMutableDictionary dictionary];
    allHeaders[@"User-Agent"] = @"TrollAutoTouch/1.0 (TAS)";
    allHeaders[@"Accept"]     = @"*/*";
    if (headers) [allHeaders addEntriesFromDictionary:headers];
    [allHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        if (v.length) [req setValue:v forHTTPHeaderField:k];
    }];

    __block NSData *outData = nil;
    __block NSURLResponse *outResp = nil;
    __block NSError *outErr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        outData = data; outResp = resp; outErr = error;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    // 调用方线程 (Lua 后台线程) 阻塞等待; NSURLSession 回调在其 delegate queue
    // 上跑, 与当前线程不冲突, 无死锁风险。
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (outErr) {
        return @{ @"status": @0,
                  @"headers": @{},
                  @"body": [NSString stringWithFormat:@"网络错误: %@", outErr.localizedDescription] };
    }
    NSInteger code = 0;
    if ([outResp isKindOfClass:[NSHTTPURLResponse class]]) {
        code = ((NSHTTPURLResponse *)outResp).statusCode;
    }
    return @{ @"status": @(code),
              @"headers": http_responseHeaders(outResp),
              @"body": http_bodyToString(outData) };
}

- (NSDictionary *)httpGetSync:(NSString *)url
                  timeoutSec:(NSTimeInterval)timeoutSec
                     headers:(NSDictionary<NSString *, NSString *> *)headers {
    return http_performSync(url, timeoutSec, headers, nil);
}

- (NSDictionary *)httpPostSync:(NSString *)url
                   timeoutSec:(NSTimeInterval)timeoutSec
                      headers:(NSDictionary<NSString *, NSString *> *)headers
                  requestBody:(NSString *)requestBody {
    return http_performSync(url, timeoutSec, headers, requestBody ?: @"");
}

#pragma mark - HTTP 下载 (用于 Lua http.download, 同步阻塞, 带进度回调)

/// 解析 HTTP 响应头 Content-Length; 没有就返回 -1 (未知大小)
static int64_t http_contentLength(NSURLResponse *resp) {
    if (![resp isKindOfClass:[NSHTTPURLResponse class]]) return -1;
    NSString *v = ((NSHTTPURLResponse *)resp).allHeaderFields[@"Content-Length"];
    if (!v.length) return -1;
    return (int64_t)[v longLongValue];
}



- (BOOL)httpDownloadSync:(NSString *)url
                savePath:(NSString *)localPath
              timeoutSec:(NSTimeInterval)timeoutSec
                progress:(void (^)(int64_t, int64_t, int64_t))progress
             shouldCancel:(BOOL (^)(void))shouldCancel
                   error:(NSError **)error {
    NSURL *u = [NSURL URLWithString:url];
    if (!u) {
        if (error) *error = [NSError errorWithDomain:@"TSHTTPDownload" code:1
                                           userInfo:@{NSLocalizedDescriptionKey: @"URL 无效"}];
        return NO;
    }
    if (localPath.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"TSHTTPDownload" code:2
                                           userInfo:@{NSLocalizedDescriptionKey: @"保存路径不能为空"}];
        return NO;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                   timeoutInterval:timeoutSec];
    req.HTTPMethod = @"GET";

    TSHTTPDownloadDelegate *del = [TSHTTPDownloadDelegate new];
    [del openLocalFile:localPath];
    if (!del->_fileHandle) {
        if (error) *error = [NSError errorWithDomain:@"TSHTTPDownload" code:3
                                           userInfo:@{NSLocalizedDescriptionKey:
                                                       [NSString stringWithFormat:@"无法写入本地文件: %@", localPath]}];
        return NO;
    }
    NSOperationQueue *q = [NSOperationQueue new];
    q.maxConcurrentOperationCount = 1;
    q.name = @"TSHTTPDownload";

    // 主调用线程 (Lua 后台线程) 阻塞等待; 同时通过 NSRunLoop 轮询进度。
    // NSURLSession 委托回调在自己的 OperationQueue 上跑(与 Lua 线程独立),
    // 累加 _currentLength; 进度调度由 Lua 线程上 NSTimer 触发, 保证 Lua
    // 进度回调在调用线程执行(避免跨线程访问 lua_State)。
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                          delegate:del
                                                     delegateQueue:q];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req];
    del->_dataTask = task;     // fireProgress 通过 cancel 它实现"用户中止下载"
    [task resume];

    // 进度采样上下文 (主线程 = Lua 调用线程上)
    __block int64_t lastSampleBytes = 0;
    __block NSTimeInterval lastSampleTime = [NSDate timeIntervalSinceReferenceDate];
    __block BOOL aborted = NO;
    __weak TSHTTPDownloadDelegate *weakDel = del;

    void (^fireProgress)(void) = ^{
        TSHTTPDownloadDelegate *d = weakDel;
        if (!d || d.finished || aborted) return;
        int64_t cur = d.currentLength;
        int64_t total = d.totalLength;
        int64_t speed = 0;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval dt = now - lastSampleTime;
        if (dt > 0) {
            speed = (int64_t)((double)(cur - lastSampleBytes) / dt);
        }
        lastSampleTime = now;
        lastSampleBytes = cur;
        if (progress) progress(total, cur, speed);
        // shouldCancel 在 progress 之后调用, 让"中止判断"在拿到最新进度后进行
        if (!aborted && shouldCancel && shouldCancel()) {
            aborted = YES;
            NSError *cancelErr = [NSError errorWithDomain:@"TSHTTPDownload" code:4
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                             @"下载被取消 (shouldCancel 返回 true)"}];
            d->_lastError = cancelErr;
            d->_success = NO;
            [d->_dataTask cancel];
        }
    };

    // 200ms 周期 NSTimer, 加到当前线程 RunLoop(Lua 线程)的 CommonModes
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                     repeats:YES
                                                        block:^(NSTimer *t) { fireProgress(); }];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];

    // 立即触发一次进度回调 (让调用方拿到首帧 total)
    fireProgress();

    // 主调用线程: 通过 RunLoop 短轮询, 同时让 timer 周期性触发进度回调
    while (!del.finished && !aborted) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }

    [timer invalidate];
    [session invalidateAndCancel];

    if (aborted) {
        if (error) *error = del.lastError ?: [NSError errorWithDomain:@"TSHTTPDownload" code:4
                                                          userInfo:@{NSLocalizedDescriptionKey: @"下载被取消"}];
        return NO;
    }
    if (!del.success) {
        if (error) *error = del.lastError ?: [NSError errorWithDomain:@"TSHTTPDownload" code:99
                                                                userInfo:@{NSLocalizedDescriptionKey: @"下载失败"}];
        return NO;
    }
    // 最终回调: 让 Lua 拿到 100% 与最终速率
    if (progress) progress(del.totalLength, del.currentLength, 0);
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
