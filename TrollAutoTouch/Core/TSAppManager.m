//
//  TSAppManager.m — 应用管理模块实现
//
//  使用私有框架：SpringBoardServices, MobileCoreServices,
//  MobileInstallation, LSApplicationWorkspace 等。
//

#import "TSAppManager.h"
#import "TSKeyboardInjector.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <signal.h>

// proc_pidpath 是 macOS 私有 API，iOS SDK 无对应头文件，手动声明
#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 4096
#endif
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

// ────────────────────────────────────────────────────────────
#pragma mark - TSAppInfo
// ────────────────────────────────────────────────────────────

@implementation TSAppInfo
- (NSString *)description {
    return [NSString stringWithFormat:@"<App %@ v%@ pid=%d>", self.bundleId, self.version, self.pid];
}
@end

// ────────────────────────────────────────────────────────────
#pragma mark - 私有 API 函数指针
// ────────────────────────────────────────────────────────────

// ---- SpringBoardServices ----
static mach_port_t (*_SBSSpringBoardServerPort)(void) = NULL;
static CFStringRef (*_SBSCopyFrontmostApplicationDisplayIdentifier)(mach_port_t) = NULL;
static CFStringRef (*_SBSCopyDisplayIdentifierForProcessID)(mach_port_t, pid_t) = NULL;
static int (*_SBSLaunchApplicationWithIdentifier)(mach_port_t, CFStringRef, Boolean) = NULL;

// ---- LSApplicationWorkspace ----
static id _workspace = nil;
static BOOL (*_LSApplicationWorkspace_isInstalled)(id, SEL, NSString *) = NULL;
static BOOL (*_LSApplicationWorkspace_openApp)(id, SEL, NSString *) = NULL;
static BOOL (*_LSApplicationWorkspace_uninstall)(id, SEL, NSString *, id) = NULL;
static BOOL (*_LSApplicationWorkspace_install)(id, SEL, NSString *, id) = NULL;
static NSArray *(*_LSApplicationWorkspace_allApps)(id, SEL) = NULL;

// ---- MobileInstallation (可选) ----
static int (*_MobileInstallationLookup)(CFDictionaryRef, CFDictionaryRef *) = NULL;
static int (*_MobileInstallationUninstall)(CFStringRef, CFDictionaryRef, void *) = NULL;
static int (*_MobileInstallationInstall)(CFStringRef, CFDictionaryRef, void *, void *) = NULL;

// ────────────────────────────────────────────────────────────
#pragma mark - 符号初始化
// ────────────────────────────────────────────────────────────

static void _loadSpringBoardServices(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        if (h) {
            _SBSSpringBoardServerPort = dlsym(h, "SBSSpringBoardServerPort");
            _SBSCopyFrontmostApplicationDisplayIdentifier = dlsym(h, "SBSCopyFrontmostApplicationDisplayIdentifier");
            _SBSCopyDisplayIdentifierForProcessID = dlsym(h, "SBSCopyDisplayIdentifierForProcessID");
            _SBSLaunchApplicationWithIdentifier = dlsym(h, "SBSLaunchApplicationWithIdentifier");
        }
    });
}

static void _loadLSApplicationWorkspace(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"LSApplicationWorkspace");
        if (cls && [cls respondsToSelector:@selector(defaultWorkspace)]) {
            _workspace = [cls performSelector:@selector(defaultWorkspace)];
            if (_workspace) {
                _LSApplicationWorkspace_isInstalled = (BOOL(*)(id,SEL,NSString*))
                    [_workspace methodForSelector:NSSelectorFromString(@"applicationIsInstalled:")];
                _LSApplicationWorkspace_openApp = (BOOL(*)(id,SEL,NSString*))
                    [_workspace methodForSelector:NSSelectorFromString(@"openApplicationWithBundleID:")];
                _LSApplicationWorkspace_uninstall = (BOOL(*)(id,SEL,NSString*,id))
                    [_workspace methodForSelector:NSSelectorFromString(@"uninstallApplication:withOptions:")];
                _LSApplicationWorkspace_install = (BOOL(*)(id,SEL,NSString*,id))
                    [_workspace methodForSelector:NSSelectorFromString(@"installApplication:withOptions:")];
                _LSApplicationWorkspace_allApps = (NSArray*(*)(id,SEL))
                    [_workspace methodForSelector:NSSelectorFromString(@"allInstalledApplications")];
            }
        }
    });
}

static void _loadMobileInstallation(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY);
        if (h) {
            _MobileInstallationLookup = dlsym(h, "MobileInstallationLookup");
            _MobileInstallationUninstall = dlsym(h, "MobileInstallationUninstall");
            _MobileInstallationInstall = dlsym(h, "MobileInstallationInstall");
        }
    });
}

// ────────────────────────────────────────────────────────────
#pragma mark - TSAppManager
// ────────────────────────────────────────────────────────────

@implementation TSAppManager

+ (instancetype)shared {
    static TSAppManager *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [[self alloc] init]; });
    return m;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _loadSpringBoardServices();
        _loadLSApplicationWorkspace();
        _loadMobileInstallation();
    }
    return self;
}

// ────────────────────────────────────────────────────────────
#pragma mark 前台应用
// ────────────────────────────────────────────────────────────

- (pid_t)frontPid {
    // 通过 Accessibility 或进程枚举反查
    // 先尝试通过 SBS 获取 bundleId，再从进程列表匹配
    NSString *bid = [self frontBid];
    if (!bid) return -1;

    // 枚举进程找到匹配 bundleId 的
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) < 0) return -1;

    struct kinfo_proc *procs = malloc(size);
    if (!procs) return -1;
    if (sysctl(mib, 3, procs, &size, NULL, 0) < 0) { free(procs); return -1; }

    int count = (int)(size / sizeof(struct kinfo_proc));
    pid_t found = -1;
    for (int i = 0; i < count; i++) {
        pid_t p = procs[i].kp_proc.p_pid;
        if (p <= 0) continue;

        // 获取进程路径
        char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(p, pathbuf, sizeof(pathbuf)) <= 0) continue;

        NSString *path = [NSString stringWithUTF8String:pathbuf];
        // 检查路径是否包含该 bundleId
        if ([path containsString:[NSString stringWithFormat:@"/%@.app/", bid]] ||
            [path containsString:[NSString stringWithFormat:@"/%@/", bid]]) {
            found = p;
            break;
        }
    }
    free(procs);
    return found;
}

- (NSString *)frontBid {
    _loadSpringBoardServices();
    if (_SBSSpringBoardServerPort && _SBSCopyFrontmostApplicationDisplayIdentifier) {
        mach_port_t port = _SBSSpringBoardServerPort();
        CFStringRef bid = _SBSCopyFrontmostApplicationDisplayIdentifier(port);
        if (bid) {
            return CFBridgingRelease(bid);
        }
    }
    return nil;
}

// ────────────────────────────────────────────────────────────
#pragma mark 应用查询
// ────────────────────────────────────────────────────────────

- (BOOL)isInstalled:(NSString *)bundleId {
    _loadLSApplicationWorkspace();
    if (_LSApplicationWorkspace_isInstalled) {
        return _LSApplicationWorkspace_isInstalled(_workspace, @selector(applicationIsInstalled:), bundleId);
    }
    // 回退：检查文件系统
    NSString *possible1 = [NSString stringWithFormat:@"/var/containers/Bundle/Application/%@", bundleId];
    NSString *possible2 = [NSString stringWithFormat:@"/Applications/%@.app", bundleId];
    return [[NSFileManager defaultManager] fileExistsAtPath:possible1] ||
           [[NSFileManager defaultManager] fileExistsAtPath:possible2];
}

- (BOOL)isRunning:(NSString *)bundleId {
    return [self pidForBundleId:bundleId] > 0;
}

- (TSAppInfo *)appInfo:(NSString *)bundleId {
    TSAppInfo *info = [[TSAppInfo alloc] init];
    info.bundleId = bundleId;
    info.pid = [self pidForBundleId:bundleId];

    // 通过 MobileInstallation 获取详细信息
    _loadMobileInstallation();
    if (_MobileInstallationLookup) {
        CFDictionaryRef dict = NULL;
        CFStringRef bid = (__bridge CFStringRef)bundleId;
        CFDictionaryRef opts = (__bridge CFDictionaryRef)@{};
        int ret = _MobileInstallationLookup(bid, &dict);
        if (ret == 0 && dict) {
            NSDictionary *d = (__bridge NSDictionary *)dict;
            info.name    = d[@"CFBundleDisplayName"] ?: d[@"CFBundleName"] ?: bundleId;
            info.version = d[@"CFBundleShortVersionString"] ?: d[@"CFBundleVersion"] ?: @"?";
            info.bundlePath = d[@"BundleContainer"] ?: d[@"Path"];
            info.dataPath   = d[@"Container"];
            CFRelease(dict);
            return info;
        }
    }

    // 回退：通过 LSApplicationWorkspace 或文件系统
    info.name = bundleId;
    info.version = @"?";

    // 尝试找 .app 路径
    NSString *possible = [NSString stringWithFormat:@"/Applications/%@.app", bundleId];
    if ([[NSFileManager defaultManager] fileExistsAtPath:possible]) {
        info.bundlePath = possible;
        NSBundle *b = [NSBundle bundleWithPath:possible];
        info.name = [b objectForInfoDictionaryKey:@"CFBundleDisplayName"]
                  ?: [b objectForInfoDictionaryKey:@"CFBundleName"] ?: bundleId;
        info.version = [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
                    ?: [b objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
    }

    return info;
}

- (NSArray<TSAppInfo *> *)installedApps {
    _loadLSApplicationWorkspace();
    NSMutableArray *result = [NSMutableArray array];

    if (_LSApplicationWorkspace_allApps) {
        NSArray *apps = _LSApplicationWorkspace_allApps(_workspace, @selector(allInstalledApplications));
        for (id app in apps) {
            // LSApplicationProxy
            NSString *bid = [app valueForKey:@"applicationIdentifier"];
            if (!bid || [bid hasPrefix:@"com.apple."]) continue; // 跳过系统应用

            TSAppInfo *info = [[TSAppInfo alloc] init];
            info.bundleId = bid;
            info.name    = [app valueForKey:@"localizedName"] ?: bid;
            info.version = [[app valueForKey:@"bundleVersion"] description] ?: @"?";
            info.bundlePath = [app valueForKey:@"bundleURL"] ? [[app valueForKey:@"bundleURL"] path] : nil;
            info.dataPath   = [app valueForKey:@"containerURL"] ? [[app valueForKey:@"containerURL"] path] : nil;
            info.pid = [self pidForBundleId:bid];
            [result addObject:info];
        }
    }
    return result;
}

// ────────────────────────────────────────────────────────────
#pragma mark 应用管理
// ────────────────────────────────────────────────────────────

- (BOOL)openApp:(NSString *)bundleId {
    // 方式1: LSApplicationWorkspace
    _loadLSApplicationWorkspace();
    if (_LSApplicationWorkspace_openApp) {
        return _LSApplicationWorkspace_openApp(_workspace, @selector(openApplicationWithBundleID:), bundleId);
    }

    // 方式2: SpringBoardServices
    _loadSpringBoardServices();
    if (_SBSLaunchApplicationWithIdentifier && _SBSSpringBoardServerPort) {
        mach_port_t port = _SBSSpringBoardServerPort();
        return _SBSLaunchApplicationWithIdentifier(port, (__bridge CFStringRef)bundleId, false) == 0;
    }

    return NO;
}

- (BOOL)closeApp:(NSString *)bundleId {
    pid_t pid = [self pidForBundleId:bundleId];
    if (pid <= 0) return NO;
    // 先发送 SIGTERM
    if (kill(pid, SIGTERM) == 0) {
        // 等待一小段时间
        usleep(500000); // 500ms
        // 如果还没死，发 SIGKILL
        if (kill(pid, 0) == 0) {
            kill(pid, SIGKILL);
        }
        return YES;
    }
    return NO;
}

- (BOOL)uninstallApp:(NSString *)bundleId {
    // 优先用 LSApplicationWorkspace
    _loadLSApplicationWorkspace();
    if (_LSApplicationWorkspace_uninstall) {
        return _LSApplicationWorkspace_uninstall(_workspace,
            @selector(uninstallApplication:withOptions:), bundleId, nil);
    }

    // 回退：MobileInstallation
    _loadMobileInstallation();
    if (_MobileInstallationUninstall) {
        CFStringRef bid = (__bridge CFStringRef)bundleId;
        return _MobileInstallationUninstall(bid, (__bridge CFDictionaryRef)@{}, NULL) == 0;
    }

    return NO;
}

- (BOOL)installIPA:(NSString *)ipaPath {
    if (![[NSFileManager defaultManager] fileExistsAtPath:ipaPath]) return NO;

    // 优先用 MobileInstallation（更可靠）
    _loadMobileInstallation();
    if (_MobileInstallationInstall) {
        CFStringRef path = (__bridge CFStringRef)ipaPath;
        int ret = _MobileInstallationInstall(path, (__bridge CFDictionaryRef)@{}, NULL, NULL);
        return ret == 0;
    }

    // 回退：LSApplicationWorkspace
    _loadLSApplicationWorkspace();
    if (_LSApplicationWorkspace_install) {
        return _LSApplicationWorkspace_install(_workspace,
            @selector(installApplication:withOptions:), ipaPath, nil);
    }

    return NO;
}

// ────────────────────────────────────────────────────────────
#pragma mark 通用
// ────────────────────────────────────────────────────────────

- (BOOL)openURL:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return NO;

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block BOOL result = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];
        if ([app respondsToSelector:@selector(openURL:options:completionHandler:)]) {
            [app openURL:url options:@{} completionHandler:^(BOOL success) {
                result = success;
                dispatch_semaphore_signal(sema);
            }];
        } else {
            // 兼容旧版
            result = [app openURL:url];
            dispatch_semaphore_signal(sema);
        }
    });
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    return result;
}

- (BOOL)inputText:(NSString *)text {
    if (!text || text.length == 0) return NO;
    return [[TSKeyboardInjector shared] inputText:text];
}

// ────────────────────────────────────────────────────────────
#pragma mark 内部辅助
// ────────────────────────────────────────────────────────────

- (pid_t)pidForBundleId:(NSString *)bundleId {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) < 0) return -1;

    struct kinfo_proc *procs = malloc(size);
    if (!procs) return -1;
    if (sysctl(mib, 3, procs, &size, NULL, 0) < 0) {
        free(procs);
        return -1;
    }

    int count = (int)(size / sizeof(struct kinfo_proc));
    pid_t found = -1;
    for (int i = 0; i < count; i++) {
        pid_t p = procs[i].kp_proc.p_pid;
        if (p <= 0) continue;

        char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(p, pathbuf, sizeof(pathbuf)) <= 0) continue;

        NSString *path = [NSString stringWithUTF8String:pathbuf];
        if ([path containsString:[NSString stringWithFormat:@"/%@.app/", bundleId]] ||
            [path containsString:[NSString stringWithFormat:@"/%@/", bundleId]]) {
            found = p;
            break;
        }
    }
    free(procs);
    return found;
}

@end
