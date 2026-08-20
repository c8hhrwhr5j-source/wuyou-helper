//
//  TSHUDHost.m
//  TrollAutoTouch
//
//  进程内 HUD 宿主: 在 TrollAutoTouch 主 App 进程内自建全屏透明窗口,
//  通过 SBSAccessibilityWindowHostingController 注册到 SpringBoard 的
//  accessibility 窗口层, 实现"不依赖 app 前台"的系统级弹窗。
//
//  单 App 架构 (合并自旧版独立 HUDServices.app):
//  - 不再需要独立 HUDServices target / CPDistributedMessagingCenter 跨进程消息
//  - 弹窗视图直接加到本进程窗口上, 由 SBS 托管到系统级
//  - 桌面只显示 TrollAutoTouch 一个图标
//
//  线程模型: presentAlertWithTitle: 为阻塞式调用 (可后台线程调用),
//  内部把视图展示派发到主线程, 用信号量等待用户点击/超时后返回按钮文本。

#import "TSHUDHost.h"
#import "HUDCustomAlertView.h"
#import "HUDToastView.h"
#import "TSHUDPrivate.h"
#import <QuartzCore/QuartzCore.h>
#import <sys/time.h>
#import <dlfcn.h>

// 系统级窗口托管层级: 高于普通 app 内容(UIWindowLevelAlert 为 2000),
// 足以盖住所有前台 app 的窗口。
static const double kSBSHostingWindowLevel = 10000.0;

// SBSAccessibilityWindowHostingController 属于私有框架
// SpringBoardServices.framework。TrollAutoTouch 作为 TrollStore app
// 默认不会链接该私有框架, 直接 NSClassFromString 会返回 nil
// (→ "SBS class missing" → 系统级托管注册失败 → 后台 HUD 弹窗不可用)。
// 这里在运行时 dlopen 该框架后再查一次类。
static Class TSHUDHostingClass(void) {
    Class cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (!cls) {
        static dispatch_once_t once;
        static void *s_sbHandle = NULL;
        dispatch_once(&once, ^{
            s_sbHandle = dlopen("/System/Library/PrivateFrameworks/"
                                "SpringBoardServices.framework/SpringBoardServices",
                                RTLD_LAZY);
        });
        if (s_sbHandle) {
            cls = NSClassFromString(@"SBSAccessibilityWindowHostingController");
        }
    }
    return cls;
}

// 全屏透明宿主窗口子类:
// 透明区域必须穿透到下层窗口 (hitTest 返回 nil),
// 否则这个 windowLevel 高于主 UI 的透明全屏窗口会吞掉所有触摸,
// 导致主 App 界面"点击任何地方都无反应"。
// 仅当命中弹窗内容 (HUDCustomAlertView 及其子视图) 时才消费触摸,
// 与 TSHUDWindow (悬浮窗) 的 hitTest 穿透逻辑保持一致。
@interface TSHUDHostWindow : UIWindow
@end

@implementation TSHUDHostWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // 命中窗口自身或根视图(透明背景, 无弹窗) → 穿透给下层窗口
    if (hit == self || hit == self.rootViewController.view) {
        return nil;
    }
    return hit;
}
@end

@implementation TSHUDHost {
    UIWindow *_window;
    UIViewController *_rootVC;
    // iOS 15+: 通过 SBSAccessibilityWindowHostingController 把本进程窗口的
    // CAContext 注册到 SpringBoard 的 accessibility 窗口层, 实现
    // "不依赖 app 前台" 的系统级弹窗 (逆向自 AutoGoRunner/agoverlayd)。
    id _sbsHostingCtrl;
    unsigned _registeredContextId;
    BOOL _startupFailedSBS;
    BOOL _started;
}

// 启动日志落盘到 /tmp/hud_startup.log, 便于在无 Xcode 环境下排查启动/崩溃路径。
static void HUDLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    struct timeval tv;
    gettimeofday(&tv, NULL);
    NSString *line = [NSString stringWithFormat:@"[%.3f] %@\n",
                      tv.tv_sec + tv.tv_usec / 1000000.0, msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/hud_startup.log"];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:@"/tmp/hud_startup.log"
                                               contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/hud_startup.log"];
    }
    if (fh) {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {
            // 日志写失败不影响主流程
        }
    }
    NSLog(@"%@", msg);
}

+ (instancetype)shared {
    static TSHUDHost *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TSHUDHost alloc] init];
    });
    return instance;
}

- (void)start {
    if (_started) return;
    _started = YES;

    @try {
        // 全屏透明窗口 (windowLevel 抬高, 确保可见; 不抢主 App 的 key window)
        // 使用 TSHUDHostWindow 子类: 透明区域 hitTest 穿透, 不拦截主界面触摸
        _window = [[TSHUDHostWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        _window.windowLevel = UIWindowLevelStatusBar + 100;
        _window.backgroundColor = [UIColor clearColor];

        _rootVC = [[UIViewController alloc] init];
        _rootVC.view.backgroundColor = [UIColor clearColor];
        _window.rootViewController = _rootVC;
        _window.hidden = NO;
        HUDLog(@"TSHUDHost start: window ok");

        // iOS 15+: 把窗口注册到 SpringBoard 的 accessibility 窗口层。
        // 延迟到首轮 runloop 之后执行 (窗口显示后 layer 需一轮
        // runloop 才绑定 CAContext)。整个调用链都 try-catch 保护, 失败只降级
        // (弹窗仅在 app 前台时可见), 绝不让主 App 崩溃。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self _registerAccessibilityHostingWithRetryCount:10];
        });

        // app 激活后 window 的 CAContext 可能重建 (contextId 变化), 重新注册
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_appDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        HUDLog(@"TSHUDHost start done");
    } @catch (NSException *e) {
        HUDLog(@"TSHUDHost start exception: %@", e);
    }
}

- (void)_appDidBecomeActive:(NSNotification *)note {
    if (_startupFailedSBS) return;
    [self _registerAccessibilityHostingWithRetryCount:5];
}

#pragma mark - 系统级窗口托管 (SBSAccessibilityWindowHostingController)

- (BOOL)_registerAccessibilityHostingWithRetryCount:(NSInteger)retryCount {
    if (retryCount <= 0) {
        HUDLog(@"accessibility hosting: retry exhausted, fallback to foreground");
        _startupFailedSBS = YES;
        return NO;
    }

    @try {
        // 类型检查: contextId 是 CALayer 私有属性, 用 respondsToSelector 兜底
        CALayer *layer = _window.layer;
        if (!layer) return NO;
        unsigned ctxId = 0;
        if ([layer respondsToSelector:@selector(contextId)]) {
            ctxId = (unsigned)[layer contextId];
        }
        if (ctxId == 0) {
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                __strong typeof(self) self = weakSelf;
                if (self && !self->_startupFailedSBS) {
                    [self _registerAccessibilityHostingWithRetryCount:retryCount - 1];
                }
            });
            return NO;
        }

        if (_registeredContextId == ctxId) return YES; // 已注册

        // 类属于私有框架 SpringBoardServices, app 未链接时先 dlopen 兜底
        Class sbsClass = TSHUDHostingClass();
        if (!sbsClass) {
            HUDLog(@"accessibility hosting: SBS class missing "
                   "(NSClassFromString + dlopen SpringBoardServices both failed)");
            _startupFailedSBS = YES;
            return NO;
        }

        if (!_sbsHostingCtrl) {
            _sbsHostingCtrl = [[sbsClass alloc] init];
        }
        if (_registeredContextId != 0) {
            SEL unregSel = NSSelectorFromString(@"unregisterWindowWithContextID:");
            if ([_sbsHostingCtrl respondsToSelector:unregSel]) {
                void (*fn)(id, SEL, unsigned) = (void (*)(id, SEL, unsigned))[_sbsHostingCtrl methodForSelector:unregSel];
                if (fn) fn(_sbsHostingCtrl, unregSel, _registeredContextId);
            }
        }
        SEL regSel = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
        if ([_sbsHostingCtrl respondsToSelector:regSel]) {
            void (*fn)(id, SEL, unsigned, double) = (void (*)(id, SEL, unsigned, double))[_sbsHostingCtrl methodForSelector:regSel];
            if (fn) fn(_sbsHostingCtrl, regSel, ctxId, kSBSHostingWindowLevel);
            _registeredContextId = ctxId;
            HUDLog(@"accessibility window hosting registered: contextId=%u", ctxId);
        } else {
            HUDLog(@"accessibility hosting: register selector missing");
            _startupFailedSBS = YES;
        }
        return YES;
    } @catch (NSException *e) {
        HUDLog(@"accessibility hosting exception: %@", e);
        _startupFailedSBS = YES;
        return NO;
    }
}

#pragma mark - 阻塞式弹窗 (可后台线程调用)

- (nullable NSString *)presentAlertWithTitle:(nullable NSString *)title
                                     message:(nullable NSString *)message
                                     buttons:(nullable NSArray<NSString *> *)buttons
                                     timeout:(NSTimeInterval)timeout {
    if (!_started) [self start];

    // 若窗口未成功托管到系统级 且 app 不在前台, 弹窗不可见,
    // 直接返回 nil (脚本继续执行, 不永久阻塞)。
    if (_registeredContextId == 0 &&
        [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        HUDLog(@"presentAlert skipped: not foreground & SBS not registered");
        return nil;
    }

    __block NSString *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            _window.hidden = NO;
            HUDCustomAlertView *alert = [[HUDCustomAlertView alloc] initWithTitle:title
                                                                          message:message
                                                                          buttons:buttons
                                                                          timeout:timeout
                                                                         onResult:^(NSString *r) {
                result = r;
                dispatch_semaphore_signal(sem);
            }];
            [_rootVC.view addSubview:alert];
            [alert show];
        } @catch (NSException *e) {
            HUDLog(@"presentAlert exception: %@", e);
            dispatch_semaphore_signal(sem);
        }
    });

    // 超时兜底: 防 SBS 托管失败导致弹窗不可见时永久阻塞。
    // timeout>0 时 HUDCustomAlertView 内部超时会自动关闭; 此处额外保护。
    NSTimeInterval maxWait = (timeout > 0 ? timeout : 60.0) + 15.0;
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(maxWait * NSEC_PER_SEC)));
    return result;
}

#pragma mark - 非阻塞 toast (可任意线程调用)

- (void)showToast:(NSString *)text
         duration:(NSTimeInterval)duration
           hidden:(BOOL)hidden {
    if (!_started) [self start];
    if (text.length == 0) return;
    if (duration <= 0) duration = 1.0;

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            _window.hidden = NO;
            HUDToastView *toast = [[HUDToastView alloc] initWithText:text
                                                            duration:duration
                                                              hidden:hidden];
            [_rootVC.view addSubview:toast];
            [toast show];
        } @catch (NSException *e) {
            HUDLog(@"showToast exception: %@", e);
        }
    });
}

#pragma mark - 状态诊断

// 供脚本日志/诊断界面查询 HUD 宿主的真实注册状态。
// 线程安全: 只读共享变量(写都在主线程, 读在任意线程, 可接受)。
- (NSString *)registrationStatusDescription {
    NSString *clsState = TSHUDHostingClass()
        ? @"SBS class OK" : @"SBS class MISSING(dlopen also failed)";
    NSString *ctxState = (_registeredContextId != 0)
        ? [NSString stringWithFormat:@"registered ctxId=%u", _registeredContextId]
        : @"NOT registered(ctxId=0)";
    NSString *failState = _startupFailedSBS ? @"startupFailedSBS=YES" : @"startupFailedSBS=NO";
    NSString *fgState = ([UIApplication sharedApplication].applicationState == UIApplicationStateActive)
        ? @"app=foreground" : @"app=background";
    return [NSString stringWithFormat:@"HUD 宿主状态: %@ | %@ | %@ | %@",
            clsState, ctxState, failState, fgState];
}

@end
