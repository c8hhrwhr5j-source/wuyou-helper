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

        // iOS 13+ scene-based app: 手动创建的 UIWindow 必须挂到某个
        // UIWindowScene, 否则不会参与渲染, layer 拿不到 CAContext
        // (contextId=0), SBS 系统级托管将永远失败。
        if (@available(iOS 13.0, *)) {
            UIWindowScene *scene = [self _anyWindowScene];
            if (scene) {
                _window.windowScene = scene;
            } else {
                HUDLog(@"TSHUDHost start: no windowScene yet, will retry on active");
            }
        }

        _rootVC = [[UIViewController alloc] init];
        _rootVC.view.backgroundColor = [UIColor clearColor];
        _window.rootViewController = _rootVC;

        // 渲染锚点: 窗口内容必须真正参与离屏渲染, layer 才会被分配
        // CAContext (contextId≠0)。纯 clearColor 的空内容会被系统优化掉,
        // 导致 contextId 一直是 0 (ctxId=0 → SBS 托管永远失败)。
        // 用 alpha=0.01 的近透明色: 肉眼不可见, 但强制窗口渲染。
        UIView *anchor = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
        anchor.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.01];
        anchor.hidden = NO;
        [_rootVC.view addSubview:anchor];

        // ★ 关键: iOS 13+ 手动创建的 UIWindow 必须 makeKeyAndVisible
        // 才会被 scene 纳入渲染管线并分配 CAContext。
        // 只设 hidden=NO 的窗口不参与渲染, layer.contextId=0,
        // 即使 app 在前台, 加在窗口上的视图也永远不会显示。
        // (逆向自原版 HUDServices: BLUIWindow + makeKeyAndVisible)
        _window.hidden = NO;
        [_window makeKeyAndVisible];
        // makeKeyAndVisible 会让本窗口成为 keyWindow (windowLevel 更高),
        // 必须把 key 交还给主窗口, 否则主界面状态栏样式/键盘行为受影响,
        // 且 keyWindow 判断会被降级逻辑误用 (见 _foregroundWindow 注释)。
        UIWindow *mainW = [self _foregroundWindow];
        if (mainW && mainW != _window) {
            [mainW makeKeyWindow];
        }
        HUDLog(@"TSHUDHost start: window ok (key=%d)",
               (_window.isKeyWindow ? 1 : 0));

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

// 取任意可用的 UIWindowScene。
// 本 App 是旧式 UIWindow (非 scene-based), iOS 13+ 下手动创建的窗口必须
// 挂到主窗口所在的 scene 才会参与渲染并拿到 CAContext (contextId≠0)。
// 优先从主窗口取 windowScene (最可靠), 其次遍历 connectedScenes。
- (UIWindowScene *)_anyWindowScene {
    if (@available(iOS 13.0, *)) {
        // ① 主窗口 (AppDelegate 的 window) 的 scene —— 主界面能正常显示,
        //    说明它已挂到兼容 scene, 直接复用它的 scene 最稳妥
        NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
        for (UIWindow *w in windows) {
            if (w.windowScene) return w.windowScene;
        }
        // ② connectedScenes 兜底
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                return (UIWindowScene *)scene;
            }
        }
    }
    return nil;
}

// 前台降级窗口: SBS 未托管成功且 app 在前台时,
// 弹窗直接显示在主窗口上, 保证用户一定能看到 (前台可见, 后台仍不可见)。
//
// ★ 关键: 不能依赖 keyWindow! 本类自建的 HUD 窗口在 start 里
// makeKeyAndVisible 后会成为 keyWindow (windowLevel 高于主窗口),
// 若把 keyWindow 当作降级目标, toast 会被加回"从不渲染的 HUD 窗口"上,
// 前台依然看不到 (逆向结论: 原版前台 toast 挂在自己的视图层级, 不依赖 SBS)。
// 正确做法: 只找 windowLevel == UIWindowLevelNormal 的主窗口。
- (UIWindow *)_foregroundWindow {
    NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *w in windows) {
        if (w.windowLevel == UIWindowLevelNormal && w.rootViewController) {
            return w;
        }
    }
    UIWindow *key = [UIApplication sharedApplication].keyWindow;
    if (key && key.windowLevel == UIWindowLevelNormal) return key;
    if (windows.count) return windows.firstObject;
    return nil;
}

// 弹窗内容应挂载的视图:
//  - SBS 托管成功 → HUD 窗口根视图 (系统级, 任意 app 之上)
//  - 否则           → 主窗口内容 (前台可见; 后台不可见)
// 避免"托管失败时把视图加在从不渲染的窗口上 → 前台也看不到"的坑。
- (UIView *)_displayContentView {
    if (_registeredContextId != 0) {
        return _rootVC.view;
    }
    UIWindow *fg = [self _foregroundWindow];
    if (fg) {
        if (fg.rootViewController.view) return fg.rootViewController.view;
        return fg;
    }
    return _rootVC.view;
}

- (void)_appDidBecomeActive:(NSNotification *)note {
    BOOL sceneAttached = NO;
    // 启动早期没有 scene 时, 现在补挂到窗口并重新 makeKeyAndVisible
    if (@available(iOS 13.0, *)) {
        if (_window && !_window.windowScene) {
            UIWindowScene *scene = [self _anyWindowScene];
            if (scene) {
                _window.windowScene = scene;
                [_window makeKeyAndVisible];
                // 同样交还 key 给主窗口 (见 start 注释)
                UIWindow *mainW = [self _foregroundWindow];
                if (mainW && mainW != _window) {
                    [mainW makeKeyWindow];
                }
                sceneAttached = YES;
                HUDLog(@"TSHUDHost window attached to scene + key on active");
            }
        }
    }
    // 之前因没有 scene / 重试耗尽而标记失败时, 补挂 scene 后重置标记再试一次
    if (_startupFailedSBS && !sceneAttached) return;
    _startupFailedSBS = NO;
    [self _registerAccessibilityHostingWithRetryCount:10];
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

// UIWindow/UIView 必须主线程创建; start 可能被 Lua 后台线程首次触发,
// 统一保证 start 在主线程执行 (已启动则立即返回)。
- (void)ensureStartedOnMainThread {
    if (_started) return;
    if ([NSThread isMainThread]) {
        [self start];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self start];
        });
    }
}

- (nullable NSString *)presentAlertWithTitle:(nullable NSString *)title
                                     message:(nullable NSString *)message
                                     buttons:(nullable NSArray<NSString *> *)buttons
                                     timeout:(NSTimeInterval)timeout {
    [self ensureStartedOnMainThread];

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
            UIView *host = [self _displayContentView];
            HUDCustomAlertView *alert = [[HUDCustomAlertView alloc] initWithTitle:title
                                                                          message:message
                                                                          buttons:buttons
                                                                          timeout:timeout
                                                                         onResult:^(NSString *r) {
                result = r;
                dispatch_semaphore_signal(sem);
            }];
            [host addSubview:alert];
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
    [self ensureStartedOnMainThread];
    if (text.length == 0) return;
    if (duration <= 0) duration = 1.0;

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 可见性检查: 与 presentAlert 一致。SBS 未托管成功 且 app 不在前台时,
            // toast 加在窗口上也看不到, 记日志便于排查 (不再静默失败)。
            if (_registeredContextId == 0 &&
                [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
                HUDLog(@"showToast skipped (not foreground & SBS not registered): %@", text);
                return;
            }
            UIView *host = [self _displayContentView];
            HUDToastView *toast = [[HUDToastView alloc] initWithText:text
                                                            duration:duration
                                                              hidden:hidden];
            [host addSubview:toast];
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
