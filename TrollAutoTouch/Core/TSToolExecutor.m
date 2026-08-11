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
#import <dirent.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/time.h>

// libproc / proc_info 声明(macOS 专用头文件，iOS SDK 中不存在)
// 这些函数在 iOS 运行时存在但头文件中未公开
#define PROC_PIDPATHINFO_MAXSIZE 4096
#define PROC_PIDTASKINFO         4

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

extern int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

#pragma mark - 结果类型

@implementation TSCmdResult
- (NSString *)description {
    return [NSString stringWithFormat:@"<TSCmdResult exit=%d elapsed=%.3fs out=\"%@\" err=\"%@\">",
            _exitCode, _elapsed,
            _stdout.length > 100 ? [[_stdout substringToIndex:100] stringByAppendingString:@"..."] : _stdout,
            _stderr.length > 100 ? [[_stderr substringToIndex:100] stringByAppendingString:@"..."] : _stderr];
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
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, outPipe[0]);
    posix_spawn_file_actions_addclose(&actions, errPipe[0]);

    int spawnErr = posix_spawn(&pid, "/bin/sh", &actions, NULL, argv, NULL);
    posix_spawn_file_actions_destroy(&actions);

    // 关闭写端
    close(outPipe[1]);
    close(errPipe[1]);

    if (spawnErr != 0) {
        close(outPipe[0]);
        close(errPipe[0]);
        result.exitCode = -1;
        result.stderr = [NSString stringWithFormat:@"spawn error: %s", strerror(spawnErr)];
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
            result.stderr = @"命令执行超时";
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

    result.stdout = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: @"";
    result.stderr = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: result.stderr ?: @"";
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
    return [TSDeviceInfo shared].wifiIPAddress; // 复用已有实现
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
    info[@"architecture"] = @(sizeof(void *) == 8 ? @"arm64" : @"armv7");

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
