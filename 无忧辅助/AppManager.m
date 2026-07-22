//
//  AppManager.m
//  无忧辅助 - 应用管理（通过动态加载私有框架实现）
//

#import "AppManager.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <signal.h>

// ---- SpringBoardServices 函数指针 ----
static void *_sbsHandle = NULL;
static NSString * (*_SBFrontmostAppDisplayId)(void) = NULL;
static int (*_SBSLaunchApp)(void *bundleId, bool suspended) = NULL;
static int (*_SBSTerminateApp)(void *bundleId) = NULL;

// ---- LaunchServices 函数指针 ----
static void *_lsHandle = NULL;
extern CFTypeRef _LSCopyApplicationInformationItem(int, CFTypeRef, CFTypeRef, CFTypeRef, CFTypeRef, CFTypeRef);
static CFTypeRef (*_LSCopyAppInfo)(int, CFTypeRef, CFTypeRef, CFTypeRef, CFTypeRef, CFTypeRef) = NULL;

static BOOL _sbsLoaded = NO;
static BOOL _lsLoaded  = NO;

@implementation AppManager

+ (instancetype)sharedInstance {
    static AppManager *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[AppManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        [self _loadSBS];
        [self _loadLS];
    }
    return self;
}

// ---- 加载 SpringBoardServices ----
- (void)_loadSBS {
    if (_sbsLoaded) return;
    _sbsHandle = dlopen(
        "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
        RTLD_NOW);
    if (!_sbsHandle) return;

    _SBFrontmostAppDisplayId = (NSString *(*)(void))dlsym(_sbsHandle, "SBFrontmostApplicationDisplayIdentifier");
    if (!_SBFrontmostAppDisplayId) {
        // iOS 15+ 可能改名，尝试另一个符号
        _SBFrontmostAppDisplayId = (NSString *(*)(void))dlsym(_sbsHandle, "SBSCopyFrontmostApplicationDisplayIdentifier");
    }
    _SBSLaunchApp = (int (*)(void*, bool))dlsym(_sbsHandle, "SBSLaunchApplicationWithIdentifier");
    _SBSTerminateApp = (int (*)(void*))dlsym(_sbsHandle, "SBSTerminateApplicationWithIdentifier");

    _sbsLoaded = YES;
}

// ---- 加载 LaunchServices ----
- (void)_loadLS {
    if (_lsLoaded) return;
    _lsHandle = dlopen(
        "/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
        RTLD_NOW);
    if (_lsHandle) {
        _LSCopyAppInfo = (CFTypeRef (*)(int, CFTypeRef, CFTypeRef, CFTypeRef, CFTypeRef, CFTypeRef))
            dlsym(_lsHandle, "_LSCopyApplicationInformationItem");
    }
    _lsLoaded = YES;
}

// ---- 通过 RunningBoard 获取前台 App Bundle ID ----
- (NSString *)frontBid {
    // 方案 A：SpringBoardServices（有对应 entitlement 时可用，否则可能闪退）
    // 安全调用：先检查函数指针是否可调用
    if (_SBFrontmostAppDisplayId) {
        @try {
            NSString *bid = _SBFrontmostAppDisplayId();
            if (bid && [bid length] > 0) return bid;
        } @catch (NSException *e) {
            NSLog(@"[AppManager] SBFrontmostAppDisplayId threw: %@", e);
        }
    }

    // 方案 B：通过 RunningBoard 遍历进程找前台应用
    return [self _frontBidViaRB];
}

- (NSString *)_frontBidViaRB {
    // 动态加载 RunningBoardServices
    static dispatch_once_t rbOnce;
    static Class RBSProcessMonitorClass = nil;
    dispatch_once(&rbOnce, ^{
        void *rb = dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices", RTLD_NOW);
        if (rb) {
            RBSProcessMonitorClass = NSClassFromString(@"RBSProcessMonitor");
        }
    });

    if (!RBSProcessMonitorClass) return @"";

    // RBSProcessMonitor +[sharedInstance]
    id monitor = [RBSProcessMonitorClass performSelector:NSSelectorFromString(@"sharedInstance")];
    if (!monitor) return @"";

    // [monitor statesForPredicate:error:] 或 [monitor trackedAssertion] 不行的话
    // 直接调用私有方法：_RBGetProcessInfo 或 RBSProcessHandle allProcesses
    static Class RBSProcessHandleClass = nil;
    static dispatch_once_t hOnce;
    dispatch_once(&hOnce, ^{
        RBSProcessHandleClass = NSClassFromString(@"RBSProcessHandle");
    });

    if (!RBSProcessHandleClass) return @"";

    // 尝试 [RBSProcessHandle allProcesses]
    NSArray *processes = nil;
    SEL allProcSel = NSSelectorFromString(@"allProcesses");
    if ([RBSProcessHandleClass respondsToSelector:allProcSel]) {
        processes = [RBSProcessHandleClass performSelector:allProcSel];
    }
    // fallback: [RBSProcessHandle processes]
    if (!processes) {
        SEL processesSel = NSSelectorFromString(@"processes");
        if ([monitor respondsToSelector:processesSel]) {
            processes = [monitor performSelector:processesSel];
        }
    }

    if (!processes || [processes count] == 0) return @"";

    for (id process in processes) {
        // 获取进程状态
        id state = nil;
        if ([process respondsToSelector:NSSelectorFromString(@"currentState")]) {
            state = [process performSelector:NSSelectorFromString(@"currentState")];
        }
        if (!state) continue;

        // 检查是否是 Application 且在前台
        // taskState 或 applicationState 有 foreground 标记
        NSNumber *isApp = nil;
        NSNumber *fg = nil;

        // 尝试 getter: isApplication, isForeground
        if ([state respondsToSelector:NSSelectorFromString(@"isApplication")]) {
            isApp = [state valueForKey:@"isApplication"];
        }
        if ([state respondsToSelector:NSSelectorFromString(@"isForeground")]) {
            fg = [state valueForKey:@"isForeground"];
        }

        // fallback: 读 descriptor 或者 applicationState
        if (!fg) {
            id descriptor = nil;
            if ([process respondsToSelector:NSSelectorFromString(@"descriptor")]) {
                descriptor = [process performSelector:NSSelectorFromString(@"descriptor")];
            }
            if (descriptor) {
                // RBSProcessStateDescriptor has foreground flag
                if ([descriptor respondsToSelector:NSSelectorFromString(@"isForeground")]) {
                    fg = [descriptor valueForKey:@"isForeground"];
                }
            }
        }

        // 不是应用或不在前台就跳过
        if (isApp && ![isApp boolValue]) continue;
        if (!fg || ![fg boolValue]) continue;

        // 获取 bundle identifier
        id identity = nil;
        if ([process respondsToSelector:NSSelectorFromString(@"identity")]) {
            identity = [process performSelector:NSSelectorFromString(@"identity")];
        }
        if (!identity && [process respondsToSelector:NSSelectorFromString(@"descriptor")]) {
            identity = [process performSelector:NSSelectorFromString(@"descriptor")];
        }

        NSString *bid = nil;
        // 尝试从 identity/descriptor 中提取 bundle identifier
        if ([identity respondsToSelector:NSSelectorFromString(@"bundleIdentifier")]) {
            bid = [identity valueForKey:@"bundleIdentifier"];
        } else if ([identity respondsToSelector:NSSelectorFromString(@"bundleID")]) {
            bid = [identity valueForKey:@"bundleID"];
        } else if ([identity isKindOfClass:[NSString class]]) {
            bid = (NSString *)identity;
        }

        if (bid && [bid length] > 0) return bid;
    }

    return @"";
}

// ---- 启动应用 ----
- (BOOL)runApp:(NSString *)bundleId {
    if (!_SBSLaunchApp || !bundleId) return NO;
    int ret = _SBSLaunchApp((__bridge void *)bundleId, false);
    return ret == 0;
}

// ---- 关闭应用 ----
- (BOOL)killApp:(NSString *)bundleId {
    if (!bundleId) return NO;

    // 优先用 SpringBoardServices
    if (_SBSTerminateApp) {
        int ret = _SBSTerminateApp((__bridge void *)bundleId);
        if (ret == 0) return YES;
    }

    // 回退：用 runningBoard 的 RBSProcessHandle
    return [self _killViaRunningBoard:bundleId];
}

// ---- 通过 RunningBoard 关闭（回退方案） ----
- (BOOL)_killViaRunningBoard:(NSString *)bundleId {
    RBSProcessPair pair = _getRBSProcessPair();
    if (!pair.handleClass || !pair.predicateClass) return NO;

    id predicate = [pair.predicateClass performSelector:NSSelectorFromString(@"predicateMatchingBundleIdentifier:")
                                                  withObject:bundleId];
    if (!predicate) return NO;

    id handle = [pair.handleClass performSelector:NSSelectorFromString(@"handleForPredicate:error:")
                                            withObject:predicate
                                            withObject:nil];
    if (!handle) return NO;

    NSNumber *pidObj = [handle valueForKey:@"pid"];
    if (!pidObj) return NO;

    int pid = [pidObj intValue];
    if (pid <= 0) return NO;

    kill(pid, SIGKILL);
    return YES;
}

// ---- 共享 RunningBoard 类加载 ----
typedef struct { Class handleClass; Class predicateClass; } RBSProcessPair;
static RBSProcessPair _getRBSProcessPair(void) {
    static dispatch_once_t once;
    static Class hc = nil, pc = nil;
    dispatch_once(&once, ^{
        void *rb = dlopen(
            "/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices",
            RTLD_NOW);
        if (rb) {
            hc = NSClassFromString(@"RBSProcessHandle");
            pc = NSClassFromString(@"RBSProcessPredicate");
        }
    });
    return (RBSProcessPair){hc, pc};
}

// ---- 检测是否运行 ----
- (BOOL)isAppRunning:(NSString *)bundleId {
    if (!bundleId) return NO;

    RBSProcessPair pair = _getRBSProcessPair();
    if (!pair.handleClass || !pair.predicateClass) return NO;

    id predicate = [pair.predicateClass performSelector:NSSelectorFromString(@"predicateMatchingBundleIdentifier:")
                                                  withObject:bundleId];
    if (!predicate) return NO;

    id handle = [pair.handleClass performSelector:NSSelectorFromString(@"handleForPredicate:error:")
                                            withObject:predicate
                                            withObject:nil];
    if (!handle) return NO;

    NSNumber *pidObj = [handle valueForKey:@"pid"];
    return pidObj && [pidObj intValue] > 0;
}

// ---- 获取 Bundle 路径 ----
- (NSString *)bundlePath:(NSString *)bundleId {
    if (!bundleId) return @"";

    // 方法1: 用 MobileCoreServices _LSCopyApplicationInformationItem
    if (_LSCopyAppInfo) {
        // key 传 NULL 表示获取全部信息
        CFTypeRef info = _LSCopyAppInfo(0, (__bridge CFTypeRef)bundleId, NULL, NULL, NULL, NULL);
        if (info && CFGetTypeID(info) == CFDictionaryGetTypeID()) {
            CFDictionaryRef dict = (CFDictionaryRef)info;
            CFTypeRef path = CFDictionaryGetValue(dict, CFSTR("BundlePath"));
            if (path && CFGetTypeID(path) == CFStringGetTypeID()) {
                NSString *result = (__bridge NSString *)path;
                CFRelease(info);
                return result;
            }
            CFRelease(info);
        } else if (info) {
            CFRelease(info);
        }
    }

    // 方法2: 硬编码路径（iOS 应用都在 /var/containers/Bundle/Application/UUID/）
    // 遍历查找
    NSString *appsDir = @"/var/containers/Bundle/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:appsDir error:nil];
    for (NSString *uuid in contents) {
        NSString *appDir = [appsDir stringByAppendingPathComponent:uuid];
        NSArray *appContents = [fm contentsOfDirectoryAtPath:appDir error:nil];
        for (NSString *item in appContents) {
            if ([item hasSuffix:@".app"]) {
                NSString *infoPath = [[[appDir stringByAppendingPathComponent:item]
                    stringByAppendingPathComponent:@"Info.plist"] stringByResolvingSymlinksInPath];
                NSDictionary *infoDict = [NSDictionary dictionaryWithContentsOfFile:infoPath];
                if ([infoDict[@"CFBundleIdentifier"] isEqualToString:bundleId]) {
                    return [appDir stringByAppendingPathComponent:item];
                }
            }
        }
    }

    return @"";
}

@end
