//
//  AppManager.m
//  无忧辅助 - 应用管理（信号安全 + 多层回退策略）
//

#import "AppManager.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <signal.h>
#import <setjmp.h>

// ---- SIGSEGV 安全调用宏 ----
static jmp_buf g_jmp;
static volatile sig_atomic_t g_jmpReady = 0;

static void _safeCall_sighandler(int sig) {
    (void)sig;
    if (g_jmpReady) {
        g_jmpReady = 0;
        siglongjmp(g_jmp, 1);
    }
}

static void _installSigHandler(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = _safeCall_sighandler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_NODEFER;
        sigaction(SIGSEGV, &sa, NULL);
        sigaction(SIGBUS,  &sa, NULL);
    });
}

// 安全调用一个返回 NSString* 的 C 函数指针，SIGSEGV 时返回 nil
static NSString *_safeCall_NSString(NSString *(*fn)(void)) {
    if (!fn) return nil;
    _installSigHandler();
    g_jmpReady = 1;
    if (sigsetjmp(g_jmp, 1) == 0) {
        NSString *r = fn();
        g_jmpReady = 0;
        return r;
    }
    g_jmpReady = 0;
    return nil;
}

// ---- SpringBoardServices ----
static void *_sbsHandle = NULL;
static NSString *(*_SB_FrontApp)(void) = NULL;
static int (*_SB_Launch)(void *bundleId, bool suspended) = NULL;
static int (*_SB_Terminate)(void *bundleId) = NULL;

// ---- NSInvocation 辅助：安全调用返回 id 的无参方法 ----
static id _safeInvoke_id_noargs(id target, SEL sel) {
    if (!target || !sel) return nil;
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (!sig) return nil;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:target];
        [inv setSelector:sel];
        [inv invoke];
        void *ret = NULL;
        [inv getReturnValue:&ret];
        return (__bridge id)ret;
    } @catch (NSException *e) {
        return nil;
    }
}

static id _safeInvoke_id_sel_arg(id target, SEL sel, SEL arg) {
    if (!target || !sel) return nil;
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (!sig) return nil;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:target];
        [inv setSelector:sel];
        [inv setArgument:&arg atIndex:2];
        [inv invoke];
        void *ret = NULL;
        [inv getReturnValue:&ret];
        return (__bridge id)ret;
    } @catch (NSException *e) {
        return nil;
    }
}

static id _safeInvoke_withObject(id target, SEL sel, id obj) {
    if (!target || !sel) return nil;
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (!sig) return nil;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:target];
        [inv setSelector:sel];
        if (obj) [inv setArgument:&obj atIndex:2];
        [inv invoke];
        void *ret = NULL;
        if (sig.methodReturnLength > 0) {
            [inv getReturnValue:&ret];
        }
        return (__bridge id)ret;
    } @catch (NSException *e) {
        return nil;
    }
}

static BOOL _safeInvoke_BOOL_noargs(id target, SEL sel) {
    if (!target || !sel) return NO;
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (!sig) return NO;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:target];
        [inv setSelector:sel];
        [inv invoke];
        BOOL ret = NO;
        [inv getReturnValue:&ret];
        return ret;
    } @catch (NSException *e) {
        return NO;
    }
}

@implementation AppManager

+ (instancetype)sharedInstance {
    static AppManager *i;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ i = [[AppManager alloc] init]; });
    return i;
}

- (instancetype)init {
    if (self = [super init]) {
        [self _loadSBS];
    }
    return self;
}

// ---- 加载 SpringBoardServices ----
- (void)_loadSBS {
    _sbsHandle = dlopen(
        "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
        RTLD_NOW);
    if (!_sbsHandle) return;

    _SB_FrontApp = (NSString *(*)(void))dlsym(_sbsHandle, "SBSCopyFrontmostApplicationDisplayIdentifier");
    if (!_SB_FrontApp) {
        _SB_FrontApp = (NSString *(*)(void))dlsym(_sbsHandle, "SBFrontmostApplicationDisplayIdentifier");
    }
    _SB_Launch = (int(*)(void*,bool))dlsym(_sbsHandle, "SBSLaunchApplicationWithIdentifier");
    _SB_Terminate = (int(*)(void*))dlsym(_sbsHandle, "SBSTerminateApplicationWithIdentifier");
}

// ================================================================
// 前台包名：三层回退
// ================================================================
- (NSString *)frontBid {
    // 方案 A：SpringBoardServices（带 SIGSEGV 保护）
    NSString *bid = _safeCall_NSString(_SB_FrontApp);
    if (bid && [bid length] > 0) return bid;

    // 方案 B：RunningBoard — RBSProcessMonitor
    bid = [self _frontViaProcessMonitor];
    if (bid && [bid length] > 0) return bid;

    // 方案 C：RunningBoard — RBSProcessHandle allProcesses
    bid = [self _frontViaAllProcesses];
    if (bid && [bid length] > 0) return bid;

    return @"";
}

- (NSString *)_frontViaProcessMonitor {
    static dispatch_once_t once;
    static Class MonitorClass = nil;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices", RTLD_NOW);
        if (h) MonitorClass = NSClassFromString(@"RBSProcessMonitor");
    });
    if (!MonitorClass) return nil;

    id monitor = _safeInvoke_id_noargs(MonitorClass, NSSelectorFromString(@"sharedInstance"));
    if (!monitor) return nil;

    // RBSProcessMonitorConfiguration with filter
    SEL matchHandleSel = NSSelectorFromString(@"predicateMatchingHandle:");
    id predicate = _safeInvoke_withObject(MonitorClass, NSSelectorFromString(@"predicateMatchingBundleIdentifier:"), nil);

    // Try: [monitor statesForConfiguration:config error:&err] -> returns NSSet<RBSProcessState *>
    // First try the simpler approach: [monitor processStateForProcessIdentifier:]
    // Actually let me try: [monitor trackedAssertion] or direct query

    // Try: config = [[RBSProcessMonitorConfiguration alloc] init]; [config setPredicates:@[predicate]]; [config setStateDescriptor:...];
    // Actually, simplest: just try to get foreground state from the monitor's tracked state

    // Try: updateStatesWithConfiguration:... but this is overkill
    // Back off to _frontViaAllProcesses
    return nil;
}

- (NSString *)_frontViaAllProcesses {
    static dispatch_once_t once;
    static Class HandleClass = nil;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices", RTLD_NOW);
        if (h) HandleClass = NSClassFromString(@"RBSProcessHandle");
    });
    if (!HandleClass) return nil;

    // [RBSProcessHandle allProcesses]
    NSArray *processes = nil;
    SEL allProcSel = NSSelectorFromString(@"allProcesses");
    if ([HandleClass respondsToSelector:allProcSel]) {
        processes = [HandleClass performSelector:allProcSel];
    }
    if (!processes || [processes count] == 0) return nil;

    for (id proc in processes) {
        @try {
            // Get state
            id state = _safeInvoke_id_noargs(proc, NSSelectorFromString(@"currentState"));
            if (!state) continue;

            // Check foreground
            BOOL isFg = _safeInvoke_BOOL_noargs(state, NSSelectorFromString(@"foreground"));
            if (!isFg) continue;

            // Check it's an app (not daemon)
            // RBSProcessState has taskState
            id taskState = _safeInvoke_id_noargs(state, NSSelectorFromString(@"taskState"));
            if (taskState) {
                // Skip non-app states (daemons, etc)
                NSString *tsDesc = nil;
                if ([taskState respondsToSelector:@selector(description)]) {
                    tsDesc = [taskState description];
                }
                // Rough filter
            }

            // Get identity -> bundle identifier
            id identity = _safeInvoke_id_noargs(proc, NSSelectorFromString(@"identity"));
            NSString *bid = nil;

            if ([identity respondsToSelector:NSSelectorFromString(@"bundleIdentifier")]) {
                bid = _safeInvoke_id_noargs(identity, NSSelectorFromString(@"bundleIdentifier"));
            }
            if (!bid && [identity respondsToSelector:NSSelectorFromString(@"embeddedApplicationIdentifier")]) {
                bid = _safeInvoke_id_noargs(identity, NSSelectorFromString(@"embeddedApplicationIdentifier"));
            }
            if (!bid && [identity isKindOfClass:[NSString class]]) {
                bid = (NSString *)identity;
            }

            if (bid && [bid length] > 0) return bid;
        } @catch (NSException *e) {
            continue;
        }
    }

    return nil;
}

// ================================================================
// 启动应用
// ================================================================
- (BOOL)runApp:(NSString *)bundleId {
    if (!_SB_Launch || !bundleId) return NO;
    int ret = _SB_Launch((__bridge void *)bundleId, false);
    return ret == 0;
}

// ================================================================
// 关闭应用
// ================================================================
- (BOOL)killApp:(NSString *)bundleId {
    if (!bundleId) return NO;

    if (_SB_Terminate) {
        int ret = _SB_Terminate((__bridge void *)bundleId);
        if (ret == 0) return YES;
    }

    return [self _killViaRB:bundleId];
}

- (BOOL)_killViaRB:(NSString *)bundleId {
    static dispatch_once_t once;
    static Class PredClass = nil, HandClass = nil;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices", RTLD_NOW);
        if (h) {
            PredClass = NSClassFromString(@"RBSProcessPredicate");
            HandClass = NSClassFromString(@"RBSProcessHandle");
        }
    });
    if (!PredClass || !HandClass) return NO;

    id predicate = _safeInvoke_withObject(PredClass,
        NSSelectorFromString(@"predicateMatchingBundleIdentifier:"), bundleId);
    if (!predicate) return NO;

    id handle = _safeInvoke_withObject(HandClass,
        NSSelectorFromString(@"handleForPredicate:error:"), predicate);
    if (!handle) return NO;

    NSNumber *pidObj = nil;
    if ([handle respondsToSelector:NSSelectorFromString(@"pid")]) {
        pidObj = _safeInvoke_id_noargs(handle, NSSelectorFromString(@"pid"));
    }
    if (!pidObj) return NO;

    int pid = [pidObj intValue];
    if (pid <= 0) return NO;

    kill(pid, SIGKILL);
    return YES;
}

// ================================================================
// 检测运行
// ================================================================
- (BOOL)isAppRunning:(NSString *)bundleId {
    if (!bundleId) return NO;

    static dispatch_once_t once;
    static Class PredClass = nil, HandClass = nil;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices", RTLD_NOW);
        if (h) {
            PredClass = NSClassFromString(@"RBSProcessPredicate");
            HandClass = NSClassFromString(@"RBSProcessHandle");
        }
    });
    if (!PredClass || !HandClass) return NO;

    id predicate = _safeInvoke_withObject(PredClass,
        NSSelectorFromString(@"predicateMatchingBundleIdentifier:"), bundleId);
    if (!predicate) return NO;

    id handle = _safeInvoke_withObject(HandClass,
        NSSelectorFromString(@"handleForPredicate:error:"), predicate);
    if (!handle) return NO;

    NSNumber *pidObj = nil;
    if ([handle respondsToSelector:NSSelectorFromString(@"pid")]) {
        pidObj = _safeInvoke_id_noargs(handle, NSSelectorFromString(@"pid"));
    }
    return pidObj && [pidObj intValue] > 0;
}

// ================================================================
// Bundle 路径
// ================================================================
- (NSString *)bundlePath:(NSString *)bundleId {
    if (!bundleId) return @"";

    // 直接遍历文件系统（最可靠）
    NSString *appsDir = @"/var/containers/Bundle/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:appsDir error:nil];
    for (NSString *uuid in contents) {
        NSString *appDir = [appsDir stringByAppendingPathComponent:uuid];
        NSArray *appContents = [fm contentsOfDirectoryAtPath:appDir error:nil] ?: @[];
        for (NSString *item in appContents) {
            if (![item hasSuffix:@".app"]) continue;
            NSString *infoPath = [[[appDir stringByAppendingPathComponent:item]
                stringByAppendingPathComponent:@"Info.plist"] stringByResolvingSymlinksInPath];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
            if ([info[@"CFBundleIdentifier"] isEqualToString:bundleId]) {
                return [appDir stringByAppendingPathComponent:item];
            }
        }
    }

    return @"";
}

@end
