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
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/thread_act.h>
#include <mach/arm/thread_status.h>
#include <mach/vm_map.h>

// mach_vm_* 不在 iOS 公共头文件中 (mach_vm.h 会 #error "unsupported"),
// 但函数在共享缓存中导出, 运行时可调用。手动声明原型即可。
extern kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t *address,
                                      mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_write(vm_map_t target_task, mach_vm_address_t address,
                                   vm_offset_t data, mach_msg_type_number_t data_count);
extern kern_return_t mach_vm_protect(vm_map_t target_task, mach_vm_address_t address,
                                     mach_vm_size_t size, boolean_t set_maximum,
                                     vm_prot_t new_protection);
extern kern_return_t mach_vm_deallocate(vm_map_t target_task, mach_vm_address_t address,
                                        mach_vm_size_t size);
extern kern_return_t mach_vm_read(vm_map_t target_task, mach_vm_address_t address,
                                  mach_vm_size_t size, vm_offset_t *data,
                                  mach_msg_type_number_t *data_count);

extern char **environ;

// ── arm_thread_state64_t 字段兼容层 ──
// Xcode 26+ / iOS 26 SDK 的 arm_thread_state64_t 使用 __opaque_pc/__opaque_lr/__opaque_sp/__opaque_fp (void*),
// 旧 SDK (Xcode 16 / iOS 18 等) 使用 __pc/__lr/__sp/__fp (__uint64_t)。
// mach/arm/_structs.h 的条件与 Apple 头文件完全一致:
//   #if __DARWIN_OPAQUE_ARM_THREAD_STATE64 || __DARWIN_PAC_ARM_THREAD_STATE64
// 用 #if (非 #ifdef) 因为宏可能被定义为 0; 未定义时预处理器视为 0。
#if __DARWIN_OPAQUE_ARM_THREAD_STATE64 || __DARWIN_PAC_ARM_THREAD_STATE64
    #define TS_SET_PC(s, v)   (s).__opaque_pc = (void *)(uintptr_t)(v)
    #define TS_SET_LR(s, v)   (s).__opaque_lr = (void *)(uintptr_t)(v)
    #define TS_SET_SP(s, v)   (s).__opaque_sp = (void *)(uintptr_t)(v)
    #define TS_SET_FP(s, v)   (s).__opaque_fp = (void *)(uintptr_t)(v)
    #define TS_GET_PC(s)      ((uint64_t)(uintptr_t)(s).__opaque_pc)
    #define TS_GET_LR(s)      ((uint64_t)(uintptr_t)(s).__opaque_lr)
#else
    #define TS_SET_PC(s, v)   (s).__pc = (uint64_t)(v)
    #define TS_SET_LR(s, v)   (s).__lr = (uint64_t)(v)
    #define TS_SET_SP(s, v)   (s).__sp = (uint64_t)(v)
    #define TS_SET_FP(s, v)   (s).__fp = (uint64_t)(0)
    #define TS_GET_PC(s)      ((s).__pc)
    #define TS_GET_LR(s)      ((s).__lr)
#endif

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
        // 重签阶段失败时读 resign.log (ldid 输出), opainject 此时根本没跑
        if (out.length == 0 && _lastErrorStage != nil && [_lastErrorStage hasPrefix:@"resign"]) {
            logPath = [docs stringByAppendingPathComponent:@"bin/resign.log"];
            out = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:NULL];
        }
        // dlopen-NULL: 读 SpringBoard 侧 dylib 日志 (AMFI 拒绝时会有 NSLog, 但 /tmp/ts_touch.log
        // 在 constructor 没跑起来时为空)。这是直接注入特有阶段, 必须单独提示用户。
        if ([_lastErrorStage isEqualToString:@"dlopen-NULL"]) {
            NSString *dylibLog = [NSString stringWithContentsOfFile:@"/tmp/ts_touch.log"
                                                          encoding:NSUTF8StringEncoding error:NULL];
            NSString *hint = @"dylib 被 AMFI 拒绝 (签名/entitlements 无效)";
            if (dylibLog.length > 0) {
                // constructor 跑了一部分 → 取最后 3 行
                NSArray<NSString *> *lines = [dylibLog componentsSeparatedByString:@"\n"];
                NSUInteger from = lines.count > 3 ? lines.count - 3 : 0;
                NSString *tail = [[[lines subarrayWithRange:NSMakeRange(from, lines.count - from)]
                                   componentsJoinedByString:@" | "]
                                  stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (tail.length > 0) hint = tail;
            }
            return [NSString stringWithFormat:@"注入失败(直接注入 dlopen 返回 NULL: %@)", hint];
        }
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
        // 直接注入失败的阶段 (task_for_pid / vm_alloc / thread_create 等) errno 是 kern_return_t
        // 用 mach_error_string 解析比裸数字更直观
        if (_lastErrorStage != nil && _lastErrorErrno != 0) {
            // 直接注入的阶段名以 task_for_pid / vm_ / thread_ 开头, errno 是 kern_return_t
            if ([_lastErrorStage hasPrefix:@"task_for_pid"] ||
                [_lastErrorStage hasPrefix:@"vm_"] ||
                [_lastErrorStage hasPrefix:@"thread_"]) {
                return [NSString stringWithFormat:@"注入失败(直接注入 [%@] kr=%d: %s)",
                        _lastErrorStage, _lastErrorErrno, mach_error_string((kern_return_t)_lastErrorErrno)];
            }
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

    // 重签工具链: ldid 用于运行时重签 opainject/dylib, 恢复 TrollStore 安装时被剥离的
    // entitlements (CI codesign 的签名会被 TrollStore 重签覆盖)。fastPathSign 为备用。
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
    // 重签工具链 + entitlements: 部署到 Documents/bin/ 供运行时 ldid 重签使用。
    // ent2.xml 在 bundle/bin/ 下; opainject/injector.entitlements.xml 在 Resources 根目录。
    NSArray<NSString *> *plists = @[@"ent2.xml", @"injector.entitlements.xml", @"opainject.entitlements.xml"];
    for (NSString *plist in plists) {
        NSString *src = [[NSBundle mainBundle] pathForResource:plist.stringByDeletingPathExtension ofType:plist.pathExtension inDirectory:@"bin"];
        if (!src) {
            // 不在 bin/ 下则回退到 Resources 根目录 (opainject/injector.entitlements.xml)
            src = [[NSBundle mainBundle] pathForResource:plist.stringByDeletingPathExtension ofType:plist.pathExtension];
        }
        if (src) {
            NSString *dst = [binDir stringByAppendingPathComponent:plist];
            [fm removeItemAtPath:dst error:NULL];
            [fm copyItemAtPath:src toPath:dst error:NULL];
        } else {
            NSLog(@"[TSInjectedTouch] bundle 中找不到 %@", plist);
        }
    }

    NSLog(@"[TSInjectedTouch] 部署完成: %@", dylibDst);
    return YES;
}

#pragma mark - 运行时重签 (ldid)

- (BOOL)resignBinaries {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *binDir = [docs stringByAppendingPathComponent:@"bin"];
    NSString *ldidPath = [binDir stringByAppendingPathComponent:@"ldid"];
    NSString *injectorPath = [binDir stringByAppendingPathComponent:@"opainject"];
    NSString *dylibPath = [binDir stringByAppendingPathComponent:@"TSInjectedTouchService.dylib"];
    NSString *opainjectEnt = [binDir stringByAppendingPathComponent:@"opainject.entitlements.xml"];
    NSString *injectorEnt = [binDir stringByAppendingPathComponent:@"injector.entitlements.xml"];
    NSString *resignLog = [binDir stringByAppendingPathComponent:@"resign.log"];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:ldidPath]) {
        NSLog(@"[TSInjectedTouch] 重签失败: ldid 不存在于 %@", ldidPath);
        _lastErrorStage = @"resign-noldid";
        _lastErrorErrno = ENOENT;
        return NO;
    }
    if (![fm fileExistsAtPath:opainjectEnt]) {
        NSLog(@"[TSInjectedTouch] 重签失败: opainject.entitlements.xml 不存在于 %@", opainjectEnt);
        _lastErrorStage = @"resign-noent";
        _lastErrorErrno = ENOENT;
        return NO;
    }

    // 重签 opainject: 恢复 no-sandbox + task_for_pid-allow + system-task-ports 等,
    // 否则被 app spawn 后继承沙箱, task_for_pid(SpringBoard) 被拦截。
    if (![self _resignBinary:injectorPath withEntitlements:opainjectEnt ldid:ldidPath log:resignLog]) {
        NSLog(@"[TSInjectedTouch] opainject 重签失败");
        _lastErrorStage = @"resign-opainject";
        return NO;
    }
    // 重签 dylib: 确保 AMFI 允许 dlopen (签名有效 + entitlements 完整)。失败不致命。
    if ([fm fileExistsAtPath:injectorEnt]) {
        if (![self _resignBinary:dylibPath withEntitlements:injectorEnt ldid:ldidPath log:resignLog]) {
            NSLog(@"[TSInjectedTouch] dylib 重签失败 (继续, dlopen 仍可能成功)");
        }
    }
    NSLog(@"[TSInjectedTouch] 运行时重签完成");
    return YES;
}

- (BOOL)_resignBinary:(NSString *)binaryPath
       withEntitlements:(NSString *)entPath
                  ldid:(NSString *)ldidPath
                   log:(NSString *)logPath {
    // ldid -S<entitlements> <binary>  (无空格: -S 紧跟 entitlements 文件路径)
    NSString *entFlag = [NSString stringWithFormat:@"-S%@", entPath];
    const char *args[] = {
        ldidPath.UTF8String,
        entFlag.UTF8String,
        binaryPath.UTF8String,
        NULL
    };

    int logFD = open(logPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    if (logFD >= 0) {
        posix_spawn_file_actions_adddup2(&actions, logFD, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, logFD);
    }

    pid_t child = -1;
    int rc = posix_spawn(&child, ldidPath.UTF8String, logFD >= 0 ? &actions : NULL, NULL,
                         (char *const *)args, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (rc != 0) {
        NSLog(@"[TSInjectedTouch] posix_spawn ldid 失败: %d (%s)", rc, strerror(rc));
        if (logFD >= 0) close(logFD);
        return NO;
    }

    int status = 0;
    waitpid(child, &status, 0);
    if (logFD >= 0) close(logFD);

    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    NSString *out = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:NULL];
    NSLog(@"[TSInjectedTouch] ldid 重签 %@ exit=%d 输出=%@", binaryPath.lastPathComponent, exitCode, out.length > 0 ? out : @"(无)");
    return (WIFEXITED(status) && exitCode == 0);
}

#pragma mark - 直接远程线程注入 (app 自身有 task_for_pid-allow + system-task-ports,
// 不需要 opainject。学原版 luaLib: task_for_pid → mach_vm_allocate → dlopen via
// thread_create_running。绕过 opainject 的 fat-binary ldid 重签问题。)

- (BOOL)injectDirectlyIntoSpringBoard {
    pid_t pid = [self findSpringBoardPid];
    if (pid <= 0) {
        NSLog(@"[TSInjectedTouch] 直接注入: 未找到 SpringBoard");
        _lastErrorStage = @"find-sb";
        _lastErrorErrno = ESRCH;
        return NO;
    }
    _springBoardPid = pid;

    // 1. task_for_pid — app 有 task_for_pid-allow + system-task-ports
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[TSInjectedTouch] task_for_pid(%d) 失败: %s (kr=%d)", pid, mach_error_string(kr), kr);
        _lastErrorStage = @"task_for_pid";
        _lastErrorErrno = (int)kr;
        return NO;
    }
    NSLog(@"[TSInjectedTouch] task_for_pid 成功: task=0x%x, pid=%d", task, pid);

    // 2. 准备 dylib 路径
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dylibPath = [docs stringByAppendingPathComponent:@"bin/TSInjectedTouchService.dylib"];
    const char *path = dylibPath.UTF8String;
    size_t pathLen = strlen(path) + 1;
    NSLog(@"[TSInjectedTouch] dylib 路径: %@", dylibPath);

    // 3. 分配 shellcode + path (一片连续内存)
    //    shellcode = "b loop" (0x14000000), 作为 dlopen 返回后的 LR, 让线程无限循环而非崩溃
    size_t shellcodeSize = 4;
    size_t allocSize = shellcodeSize + pathLen;
    allocSize = (allocSize + 0xFFF) & ~0xFFF;  // 4K 对齐
    mach_vm_address_t codeAddr = 0;
    kr = mach_vm_allocate(task, &codeAddr, allocSize, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[TSInjectedTouch] mach_vm_allocate(code) 失败: %s", mach_error_string(kr));
        _lastErrorStage = @"vm_alloc-code";
        _lastErrorErrno = (int)kr;
        return NO;
    }
    NSLog(@"[TSInjectedTouch] 分配 code 内存: 0x%llx (%zu bytes)", codeAddr, allocSize);

    // 4. 写入 shellcode (b #0 = 0x14000000, 无限循环)
    uint32_t shellcode = 0x14000000;  // ARM64: b #0 (跳转到自身)
    kr = mach_vm_write(task, codeAddr, (vm_offset_t)&shellcode, 4);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[TSInjectedTouch] mach_vm_write(shellcode) 失败: %s", mach_error_string(kr));
        _lastErrorStage = @"vm_write-shell";
        _lastErrorErrno = (int)kr;
        mach_vm_deallocate(task, codeAddr, allocSize);
        return NO;
    }
    // 写入 path (在 shellcode 之后)
    mach_vm_address_t pathAddr = codeAddr + shellcodeSize;
    kr = mach_vm_write(task, pathAddr, (vm_offset_t)path, (mach_msg_type_number_t)pathLen);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[TSInjectedTouch] mach_vm_write(path) 失败: %s", mach_error_string(kr));
        _lastErrorStage = @"vm_write-path";
        _lastErrorErrno = (int)kr;
        mach_vm_deallocate(task, codeAddr, allocSize);
        return NO;
    }
    NSLog(@"[TSInjectedTouch] 已写入 shellcode + path (pathAddr=0x%llx)", pathAddr);

    // 5. 设置内存保护: shellcode 可执行, path 可读
    kr = mach_vm_protect(task, codeAddr, shellcodeSize, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[TSInjectedTouch] mach_vm_protect(code, EXECUTE) 失败: %s (kr=%d) — 继续, 内核可能已默认 RX", mach_error_string(kr), kr);
        // 不致命: mach_vm_allocate 默认 RW, 某些 iOS 版本允许在 RW 页执行 (W^X 宽松)
    }
    kr = mach_vm_protect(task, pathAddr, pathLen, FALSE, VM_PROT_READ);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[TSInjectedTouch] mach_vm_protect(path, READ) 失败: %s — 继续", mach_error_string(kr));
    }

    // 6. 分配栈 (16KB, 对齐)
    size_t stackSize = 0x4000;  // 16KB
    mach_vm_address_t stackAddr = 0;
    kr = mach_vm_allocate(task, &stackAddr, stackSize, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[TSInjectedTouch] mach_vm_allocate(stack) 失败: %s", mach_error_string(kr));
        _lastErrorStage = @"vm_alloc-stack";
        _lastErrorErrno = (int)kr;
        mach_vm_deallocate(task, codeAddr, allocSize);
        return NO;
    }
    NSLog(@"[TSInjectedTouch] 分配 stack 内存: 0x%llx (%zu bytes)", stackAddr, stackSize);

    // 7. 获取 dlopen 地址 (共享缓存, 所有同架构进程地址相同)
    //    dlsym(RTLD_DEFAULT, ...) 返回原始地址 (无 PAC 签名), 可直接用于
    //    thread_create_running 的 PC 寄存器。比直接取 &dlopen 更安全
    //    (arm64e 上函数指针带 PAC, 直接 cast 会得到带签名位的值)。
    uint64_t dlopenAddr = (uint64_t)dlsym(RTLD_DEFAULT, "dlopen");
    if (dlopenAddr == 0) {
        NSLog(@"[TSInjectedTouch] dlsym(dlopen) 返回 NULL");
        _lastErrorStage = @"dlsym-dlopen";
        _lastErrorErrno = ENOENT;
        mach_vm_deallocate(task, codeAddr, allocSize);
        mach_vm_deallocate(task, stackAddr, stackSize);
        return NO;
    }
    NSLog(@"[TSInjectedTouch] dlopen 地址: 0x%llx", dlopenAddr);

    // 8. 创建远程线程: PC=dlopen, x0=path, x1=RTLD_NOW, LR=shellcode(b loop), SP=栈顶
    //    arm_thread_state64_t 字段通过 TS_SET_*/TS_GET_* 宏兼容新旧 SDK
    //    (新 SDK __opaque_*, 旧 SDK __pc/__lr/__sp/__fp)。__x[0..28] 两种 SDK 都一样。
    arm_thread_state64_t state;
    memset(&state, 0, sizeof(state));
    state.__x[0] = pathAddr;                    // arg1 = dylib path
    state.__x[1] = RTLD_NOW;                    // arg2 = mode
    TS_SET_SP(state, stackAddr + stackSize - 256);  // 栈顶
    TS_SET_LR(state, codeAddr);                 // dlopen 返回后跳到 shellcode (b loop)
    TS_SET_FP(state, 0);
    TS_SET_PC(state, dlopenAddr);               // 入口 = dlopen

    thread_act_t thread = MACH_PORT_NULL;
    kr = thread_create_running(task, ARM_THREAD_STATE64,
                               (thread_state_t)&state, ARM_THREAD_STATE64_COUNT,
                               &thread);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[TSInjectedTouch] thread_create_running 失败: %s (kr=%d)", mach_error_string(kr), kr);
        _lastErrorStage = @"thread_create";
        _lastErrorErrno = (int)kr;
        mach_vm_deallocate(task, codeAddr, allocSize);
        mach_vm_deallocate(task, stackAddr, stackSize);
        return NO;
    }
    NSLog(@"[TSInjectedTouch] 远程线程已创建: thread=0x%x", thread);

    // 9. 等待 dlopen 完成 (线程会停在 shellcode 的 b loop 循环)
    //    dlopen 触发 dylib 的 __attribute__((constructor)) → 启动 socket server
    usleep(800 * 1000);  // 800ms 应足够 dlopen + constructor

    // 检查线程状态 (PC 应在 shellcode 循环 = codeAddr, 表示 dlopen 已返回)
    // 若 x0 != 0: dlopen 成功 (handle); x0 == 0: dlopen 失败 (dylib 加载被拒)
    // — 必须把 dlopen NULL 当作失败, 否则 ensureInjected 会落到 opainject fallback,
    //   覆盖真实错误阶段, 用户看到的是 EBADEXEC 而非 dlopen 失败。
    arm_thread_state64_t curState;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kr = thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&curState, &count);
    BOOL dlopenOK = NO;
    if (kr == KERN_SUCCESS) {
        NSLog(@"[TSInjectedTouch] 线程状态: pc=0x%llx lr=0x%llx x0=0x%llx (dlopen 返回值)",
              TS_GET_PC(curState), TS_GET_LR(curState), curState.__x[0]);
        if (curState.__x[0] != 0) {
            NSLog(@"[TSInjectedTouch] dlopen 成功! handle=0x%llx", curState.__x[0]);
            dlopenOK = YES;
        } else {
            NSLog(@"[TSInjectedTouch] dlopen 返回 NULL — dylib 加载失败 (AMFI 拒绝 / 签名无效 / 路径错误)");
        }
    } else {
        NSLog(@"[TSInjectedTouch] thread_get_state 失败: %s — 线程可能已崩溃 (PAC/arm64e?), 乐观认为 dlopen 已完成", mach_error_string(kr));
        dlopenOK = YES;  // 无法确认时乐观继续, 让 socket 连接尝试给出最终结论
    }

    // 10. 终止远程线程 (b loop 循环浪费 CPU, dylib 已加载)
    kr = thread_terminate(thread);
    NSLog(@"[TSInjectedTouch] thread_terminate: %@",
          kr == KERN_SUCCESS ? @"成功" : [NSString stringWithUTF8String:mach_error_string(kr)]);

    // 读 dylib 日志 (constructor 在 dlopen 时已同步执行)
    NSString *dylibLog = [NSString stringWithContentsOfFile:@"/tmp/ts_touch.log"
                                                  encoding:NSUTF8StringEncoding error:NULL];
    if (dylibLog.length > 0) {
        NSLog(@"[TSInjectedTouch] SpringBoard dylib 日志:\n%@", dylibLog);
    } else {
        NSLog(@"[TSInjectedTouch] /tmp/ts_touch.log 为空 (dylib constructor 可能未执行)");
    }

    if (!dlopenOK) {
        _lastErrorStage = @"dlopen-NULL";
        _lastErrorErrno = ENOEXEC;  // "Exec format error" — AMFI 拒绝 dylib 加载
        return NO;
    }

    _lastErrorStage = nil;
    _lastErrorErrno = 0;
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

    // opainject/dylib 已在 ensureInjected 阶段由 resignBinaries 用 ldid 重签,
    // 恢复 TrollStore 安装时被剥离的 entitlements (no-sandbox / task_for_pid-allow /
    // system-task-ports / platform-application 等)。此处直接 spawn opainject 即可。

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

    // === 方案 A: app 直接远程线程注入 (首选) ===
    // app 自身有 task_for_pid-allow + system-task-ports + no-sandbox + platform-application,
    // 直接 task_for_pid(SpringBoard) + mach_vm_allocate + thread_create_running(dlopen).
    // 绕过 opainject, 不需要 ldid 重签 fat binary (ldid 重签会破坏 arm64e slice → EBADEXEC).
    NSLog(@"[TSInjectedTouch] === 尝试直接远程线程注入 ===");
    if ([self injectDirectlyIntoSpringBoard]) {
        // 等待 dylib 的 socket server 启动
        for (int i = 0; i < 10; i++) {
            usleep(200 * 1000);
            if ([self connectSocket]) {
                _injected = YES;
                NSLog(@"[TSInjectedTouch] 直接注入成功, socket 已连接");
                return YES;
            }
        }
        NSLog(@"[TSInjectedTouch] 直接注入完成但 socket 未连接, 尝试 opainject fallback");
    } else {
        NSLog(@"[TSInjectedTouch] 直接注入失败: [%@] errno=%d, 尝试 opainject fallback",
              _lastErrorStage, _lastErrorErrno);
    }

    // === 方案 B: opainject fallback ===
    // 先尝试 ldid 重签 (恢复 entitlements), 再 spawn opainject
    if (![self resignBinaries]) {
        NSLog(@"[TSInjectedTouch] resignBinaries 失败, 尝试不重签直接注入");
    }

    for (int attempt = 0; attempt < 3; attempt++) {
        if (![self injectSpringBoard]) {
            NSLog(@"[TSInjectedTouch] opainject fallback 第 %d 次失败", attempt + 1);
            continue;
        }
        for (int i = 0; i < 10; i++) {
            usleep(200 * 1000);
            if ([self connectSocket]) {
                _injected = YES;
                NSLog(@"[TSInjectedTouch] opainject fallback 成功, socket 已连接");
                return YES;
            }
        }
        NSLog(@"[TSInjectedTouch] opainject 第 %d 次注入后未连上服务, 重试", attempt + 1);
    }

    NSLog(@"[TSInjectedTouch] 所有注入方式均失败");
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
