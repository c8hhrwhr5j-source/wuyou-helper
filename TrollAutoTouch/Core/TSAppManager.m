//
//  TSAppManager.m — 应用管理模块实现
//
//  使用私有框架：SpringBoardServices, MobileCoreServices,
//  MobileInstallation, LSApplicationWorkspace 等。
//

#import "TSAppManager.h"
#import "TSKeyboardInjector.h"
#import "../Common/TSLogStore.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <signal.h>
#import <errno.h>
#import <string.h>

// SecTask 是 iOS 私有 API (无公共头文件), 符号从 Security.framework 导出。
// 用于查询 App 实际生效的 entitlements —— 与签名数据无关, 反映内核真正授予
// 的权限。iOS 15.5+ 的 TrollStore 无法授予 platform 身份, 因此 com.apple.private.*
// 等私有权限即使写在签名里也不会生效, 直接调用 MobileInstallation 会崩溃。
typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

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

// ---- BackBoardServices (仅作 kill() 被拒时的退路) ----
// void BKSTerminateApplicationForReasonAndReportWithDescription(
//        CFStringRef bundleID, int reason, bool report, CFStringRef description);
// 直接向 backboardd 请求终止该 App(与"上滑关闭"同一条通路)。未授权时它会安静地什么都不做,
// 不会崩溃; 因此只在 kill() 返回 EPERM(本 App 无权给别的进程发信号)时才尝试。
static void (*_BKSTerminateApplication)(CFStringRef, int, bool, CFStringRef) = NULL;
static void _loadBackBoardServices(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
                         RTLD_LAZY);
        if (h) {
            _BKSTerminateApplication = dlsym(h, "BKSTerminateApplicationForReasonAndReportWithDescription");
        }
    });
}

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

// 查询某 entitlement 是否实际生效 (SecTask 反映内核真正授予的权限,
// 非 platform 进程的 com.apple.private.* 权限即使写在签名里也返回 NO)。
+ (BOOL)hasEffectiveEntitlement:(NSString *)entitlement {
    if (!entitlement.length) return NO;
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return NO;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, (__bridge CFStringRef)entitlement, NULL);
    BOOL has = (value != NULL);
    if (value) CFRelease(value);
    CFRelease(task);
    return has;
}

// MobileInstallation 私有 API (dlopen 的 C 函数) 要求调用者实际拥有
// MobileInstallationHelper 权限。非 platform 进程 (如 iOS 15.5+ TrollStore
// 安装的 app) 即使签名里写了该 entitlement 也不会生效, 直接调用会因 XPC
// 连接被拒而崩溃。调用前必须用本方法探测, 未生效时改用 LSApplicationWorkspace。
+ (BOOL)canUseMobileInstallation {
    return [self hasEffectiveEntitlement:@"platform-application"]
        && [self hasEffectiveEntitlement:@"com.apple.private.MobileInstallationHelperService.allowed"];
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
    // 前台 App 的 bundleId (SBS) → 再用 pid→bundleId 映射反查 pid
    NSString *bid = [self frontBid];
    if (!bid) return -1;
    return [self pidForBundleId:bid];
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

    // 通过 MobileInstallation 获取详细信息 (权限未生效时跳过, 避免崩溃)
    _loadMobileInstallation();
    if ([TSAppManager canUseMobileInstallation] && _MobileInstallationLookup) {
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
        // 进程表只扫一次: 每个 App 单独查一遍会让"应用列表"卡住(上百 App × 上百进程)
        NSDictionary<NSNumber *, NSString *> *map = [self pidBundleIdMap];
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
            info.pid = [self pidForBundleId:bid map:map];
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

- (BOOL)launchAppInBackground:(NSString *)bundleId {
    // SpringBoardServices: 第三个参数 suspended=YES, 进程启动但不激活到前台
    _loadSpringBoardServices();
    if (_SBSLaunchApplicationWithIdentifier && _SBSSpringBoardServerPort) {
        mach_port_t port = _SBSSpringBoardServerPort();
        return _SBSLaunchApplicationWithIdentifier(port, (__bridge CFStringRef)bundleId, true) == 0;
    }
    // 回退: 前台启动
    return [self openApp:bundleId];
}

- (BOOL)closeApp:(NSString *)bundleId {
    pid_t pid = [self pidForBundleId:bundleId];
    if (pid <= 0) {
        // 以前这里直接 return NO 且毫无提示 —— 用户只看到"点了没反应"。
        // 失败原因必须落进 touch.log(2026-09-12): 没找到进程 = 该 App 没在运行 / 未安装 /
        // bundle id 写错(注意: 不是 App 显示名)。
        [[TSLogStore shared] append:[NSString stringWithFormat:
            @"[App] ⚠ 关闭失败: 未找到 %@ 的运行进程(该 App 未在运行, 或 bundle id 不对)", bundleId]];
        return NO;
    }

    // ① 直接发信号: SIGTERM(优雅退出) → 等 500ms → 还在就 SIGKILL
    if (kill(pid, SIGTERM) == 0) {
        usleep(500000);                      // 500ms
        if (kill(pid, 0) != 0) return YES;   // 已退出
        kill(pid, SIGKILL);
        usleep(200000);
        if (kill(pid, 0) != 0) return YES;   // 已退出
    }
    int e = errno;   // EPERM = 本进程无权给别的进程发信号; ESRCH = 进程已经没了
    if (e == ESRCH) return YES;   // 查到 pid 之后进程自己退出了 —— 目标已达成

    // ② kill 被拒(EPERM)时的退路: 请 backboardd 代为终止(与上滑关闭同一条通路)。
    //    未获授权时该调用只是无效, 不会崩溃; 符号不存在也直接跳过。
    _loadBackBoardServices();
    if (_BKSTerminateApplication && e == EPERM) {
        _BKSTerminateApplication((__bridge CFStringRef)bundleId, 1, false, NULL);
        usleep(800000);
        if ([self pidForBundleId:bundleId] <= 0) return YES;
    }

    [[TSLogStore shared] append:[NSString stringWithFormat:
        @"[App] ⚠ 关闭失败: %@ (pid=%d) 仍在运行 —— kill 返回 %s(errno=%d)%@",
        bundleId, pid, strerror(e), e,
        (e == EPERM ? @", 本 App 无权给其他进程发信号(非越狱设备上的常见限制)"
                    : (e == ESRCH ? @", 进程已退出" : @""))]];
    return NO;
}

- (BOOL)uninstallApp:(NSString *)bundleId {
    // 优先用 LSApplicationWorkspace
    _loadLSApplicationWorkspace();
    if (_LSApplicationWorkspace_uninstall) {
        return _LSApplicationWorkspace_uninstall(_workspace,
            @selector(uninstallApplication:withOptions:), bundleId, nil);
    }

    // 回退：MobileInstallation (仅权限实际生效时可用, 否则会崩溃)
    _loadMobileInstallation();
    if ([TSAppManager canUseMobileInstallation] && _MobileInstallationUninstall) {
        CFStringRef bid = (__bridge CFStringRef)bundleId;
        return _MobileInstallationUninstall(bid, (__bridge CFDictionaryRef)@{}, NULL) == 0;
    }

    return NO;
}

- (BOOL)installIPA:(NSString *)ipaPath {
    if (![[NSFileManager defaultManager] fileExistsAtPath:ipaPath]) return NO;

    // 优先用 MobileInstallation（更可靠）。注意: 该私有 API 要求调用者实际
    // 拥有 MobileInstallationHelper 权限; 非 platform 进程 (TrollStore 2.x)
    // 直接调用会崩溃, 因此必须先经 canUseMobileInstallation 探测。
    _loadMobileInstallation();
    if ([TSAppManager canUseMobileInstallation] && _MobileInstallationInstall) {
        CFStringRef path = (__bridge CFStringRef)ipaPath;
        int ret = _MobileInstallationInstall(path, (__bridge CFDictionaryRef)@{}, NULL, NULL);
        if (ret == 0) return YES;
    }

    // 回退：LSApplicationWorkspace (不依赖 MobileInstallation 权限,
    // 失败仅返回 NO, 不会崩溃)
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
        [app openURL:url options:@{} completionHandler:^(BOOL success) {
            result = success;
            dispatch_semaphore_signal(sema);
        }];
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

/// 枚举当前所有进程 pid。
static NSArray<NSNumber *> *TSAllPids(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) < 0) return nil;
    struct kinfo_proc *procs = malloc(size);
    if (!procs) return nil;
    if (sysctl(mib, 3, procs, &size, NULL, 0) < 0) { free(procs); return nil; }

    int count = (int)(size / sizeof(struct kinfo_proc));
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (int i = 0; i < count; i++) {
        pid_t p = procs[i].kp_proc.p_pid;
        if (p > 0) [out addObject:@(p)];
    }
    free(procs);
    return out;
}

/// 一次性构建 "pid → bundleId" 映射(只遍历进程列表一次)。
///
/// 2026-09-12 修复: 旧实现靠"进程可执行文件路径里包含 /<bundleId>.app/"来匹配,
/// 这在 iOS 上几乎永远匹配不上 —— 用户 App 的 .app 目录名是 **App 显示名**, 不是
/// bundle id, 例如:
///    com.tencent.xin  → /private/var/containers/Bundle/Application/<UUID>/WeChat.app/WeChat
/// 于是 pidForBundleId 恒返回 -1 → closeApp/isRunning 全部失效(app.close 静默返回 NO)。
/// 正确做法是让 SpringBoardServices 把 pid 反查成 bundle id(SBSCopyDisplayIdentifierForProcessID)。
- (NSDictionary<NSNumber *, NSString *> *)pidBundleIdMap {
    _loadSpringBoardServices();
    NSMutableDictionary<NSNumber *, NSString *> *map = [NSMutableDictionary dictionary];
    if (!_SBSSpringBoardServerPort || !_SBSCopyDisplayIdentifierForProcessID) return map;

    mach_port_t port = _SBSSpringBoardServerPort();
    for (NSNumber *n in TSAllPids()) {
        pid_t p = (pid_t)n.intValue;
        CFStringRef bid = _SBSCopyDisplayIdentifierForProcessID(port, p);
        if (!bid) continue;
        map[n] = (__bridge_transfer NSString *)bid;   // 转移所有权, 无需 CFRelease
    }
    return map;
}

/// 该 App 的真实 .app 路径(来自 LSApplicationProxy.bundleURL), 供路径匹配回退使用。
- (nullable NSString *)bundlePathForBundleId:(NSString *)bundleId {
    _loadLSApplicationWorkspace();
    if (!_LSApplicationWorkspace_allApps || !bundleId.length) return nil;
    NSArray *apps = _LSApplicationWorkspace_allApps(_workspace, @selector(allInstalledApplications));
    for (id app in apps) {
        NSString *bid = [app valueForKey:@"applicationIdentifier"];
        if (![bid isEqualToString:bundleId]) continue;
        NSURL *u = [app valueForKey:@"bundleURL"];
        return u.path;
    }
    return nil;
}

- (pid_t)pidForBundleId:(NSString *)bundleId {
    return [self pidForBundleId:bundleId map:nil];
}

/// @param map 预先算好的 pid→bundleId 映射(批量查询时传入, 避免每个 App 都重扫一遍进程表);
///            传 nil 时内部现算一次。
- (pid_t)pidForBundleId:(NSString *)bundleId map:(nullable NSDictionary<NSNumber *, NSString *> *)map {
    if (!bundleId.length) return -1;

    // ① SpringBoardServices 反查(唯一可靠来源)
    NSDictionary<NSNumber *, NSString *> *m = map ?: [self pidBundleIdMap];
    for (NSNumber *n in m) {
        if ([m[n] isEqualToString:bundleId]) return (pid_t)n.intValue;
    }
    if (m.count > 0) return -1;   // 映射表非空却查不到 = 该 App 确实没在跑

    // ② 回退(SBS 不可用): 用 App 真实 .app 路径匹配进程路径
    NSString *bundlePath = [self bundlePathForBundleId:bundleId];
    if (!bundlePath.length) return -1;
    NSString *want = bundlePath.stringByResolvingSymlinksInPath;   // /var → /private/var
    for (NSNumber *n in TSAllPids()) {
        pid_t p = (pid_t)n.intValue;
        char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(p, pathbuf, sizeof(pathbuf)) <= 0) continue;
        NSString *path = [NSString stringWithUTF8String:pathbuf];
        if ([path.stringByResolvingSymlinksInPath hasPrefix:want] ||
            [path containsString:[NSString stringWithFormat:@"/%@.app/", bundleId]]) {
            return p;
        }
    }
    return -1;
}

@end
