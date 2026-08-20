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
// 透明内容容器 (所有弹窗/toast 的父视图)。
// 命中容器本身(空白处)时穿透给下层窗口, 只有命中实际弹窗/toast 才消费触摸。
@property (nonatomic, weak) UIView *contentContainer;
@end

@implementation TSHUDHostWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // 命中窗口自身或根视图(透明背景, 无弹窗) → 穿透给下层窗口
    if (hit == self || hit == self.rootViewController.view) {
        return nil;
    }
    // 命中透明内容容器本身(未命中任何弹窗/toast 子视图) → 穿透给下层窗口。
    // 否则全屏透明的 _contentView 会吞掉主界面所有触摸 (点击无反应)。
    if (hit == self.contentContainer) {
        return nil;
    }
    return hit;
}
@end

@implementation TSHUDHost {
    TSHUDHostWindow *_window;
    UIViewController *_rootVC;
    UIView *_contentView;
    // iOS 15+: 通过 SBSAccessibilityWindowHostingController 把本进程窗口的
    // CAContext 注册到 SpringBoard 的 accessibility 窗口层, 实现
    // "不依赖 app 前台" 的系统级弹窗 (逆向自 AutoGoRunner/agoverlayd)。
    id _sbsHostingCtrl;
    // 显式创建的 CAContext (Go 版模式, 逆向自 __fbInstallCAContextOverlay):
    // remoteContextWithOptions: 显式创建 → contextId 一定非零,
    // 再 setLayer: 把 HUD 窗口 layer 挂进远程上下文供 SBS 托管。
    // 不依赖 window.layer.contextId (透明窗口下可能为 0 → SBS 托管永远失败)。
    id _sbsCAContext;
    unsigned _registeredContextId;
    BOOL _startupFailedSBS;
    BOOL _started;
    // 脚本坐标系方向 (对应 Lua screen.init): 0=home在下(竖屏) 1=home在右 2=home在左。
    // 用于旋转 HUD 内容层, 使 toast/弹窗在横屏游戏中横屏显示 (与脚本坐标系一致)。
    NSInteger _scriptOrientation;
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

        // 内容容器: 所有弹窗/toast 挂载在此, 脚本方向旋转只作用于容器,
        // rootVC.view 保持系统管理 (frame 始终跟随 window.bounds, 不受旋转影响)。
        _contentView = [[UIView alloc] initWithFrame:_rootVC.view.bounds];
        _contentView.backgroundColor = [UIColor clearColor];
        _contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_rootVC.view addSubview:_contentView];
        // 窗口 hitTest 依据该容器做空白穿透 (命中容器本身 → 不消费触摸)
        _window.contentContainer = _contentView;

        // 渲染锚点: 窗口内容必须真正参与离屏渲染, layer 才会被分配
        // CAContext (contextId≠0)。纯 clearColor 的空内容会被系统优化掉,
        // 导致 contextId 一直是 0 (ctxId=0 → SBS 托管永远失败)。
        // 用 alpha=0.01 的近透明色: 肉眼不可见, 但强制窗口渲染。
        UIView *anchor = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
        anchor.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.01];
        anchor.hidden = NO;
        anchor.userInteractionEnabled = NO; // 渲染锚点不参与触摸, 避免吞掉 (0,0) 处点击
        [_contentView addSubview:anchor];

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

        // 应用脚本方向 (可能在 start 之前已由 screen.init 设置)
        [self _applyScriptOrientation];
        HUDLog(@"TSHUDHost start done (orientation=%ld)", (long)_scriptOrientation);
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
//  - SBS 托管成功 → HUD 窗口内容层 _contentView (系统级, 任意 app 之上;
//                   脚本方向旋转只作用于它, toast/弹窗自动横屏)
//  - 否则           → 主窗口内容 (前台可见; 后台不可见)
// 避免"托管失败时把视图加在从不渲染的窗口上 → 前台也看不到"的坑。
- (UIView *)_displayContentView {
    if (_registeredContextId != 0) {
        return _contentView ?: _rootVC.view;
    }
    UIWindow *fg = [self _foregroundWindow];
    if (fg) {
        if (fg.rootViewController.view) return fg.rootViewController.view;
        return fg;
    }
    return _contentView ?: _rootVC.view;
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

// 获取用于 SBS 托管的 contextId (逆向自 Go 版 __fbInstallCAContextOverlay):
//   cls = NSClassFromString("CAContext")
//   ctx = [cls remoteContextWithOptions:@{@"kCAContextIgnoresHitTest": @YES}]
//   [ctx setLayer:_window.layer]      // 把 HUD 窗口 layer 挂进远程上下文
//   ctxId = [ctx contextId]           // 显式创建 → contextId 一定非零
//   [CATransaction flush]             // 提交渲染, 内容进入 context
// 显式创建不依赖"窗口 layer 是否被系统分配 CAContext"(透明窗口下 layer.contextId
// 可能为 0 → SBS 托管永远失败, 这是旧实现 toast 不显示的根本原因)。
- (unsigned)_acquireContextId {
    // 复用已创建的显式 CAContext (窗口 layer 可能重建, 重新 setLayer 挂上)
    if (_sbsCAContext) {
        SEL ctxIdSel = NSSelectorFromString(@"contextId");
        unsigned ctxId = 0;
        if (ctxIdSel && [_sbsCAContext respondsToSelector:ctxIdSel]) {
            unsigned (*ctxIdFn)(id, SEL) = (unsigned (*)(id, SEL))[_sbsCAContext methodForSelector:ctxIdSel];
            if (ctxIdFn) ctxId = ctxIdFn(_sbsCAContext, ctxIdSel);
        }
        if (ctxId != 0) {
            SEL setLayerSel = NSSelectorFromString(@"setLayer:");
            if (setLayerSel && [_sbsCAContext respondsToSelector:setLayerSel] && _window.layer) {
                void (*setLayerFn)(id, SEL, CALayer *) = (void (*)(id, SEL, CALayer *))[_sbsCAContext methodForSelector:setLayerSel];
                if (setLayerFn) setLayerFn(_sbsCAContext, setLayerSel, _window.layer);
            }
            return ctxId;
        }
        _sbsCAContext = nil; // context 失效, 重建
    }

    @try {
        Class caContextClass = NSClassFromString(@"CAContext");
        if (!caContextClass) {
            // QuartzCore 框架已链接, 但保险起见 dlopen 兜底
            static void *s_quartzHandle = NULL;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                s_quartzHandle = dlopen("/System/Library/Frameworks/"
                                        "QuartzCore.framework/QuartzCore", RTLD_LAZY);
            });
            if (s_quartzHandle) {
                caContextClass = NSClassFromString(@"CAContext");
            }
        }
        if (caContextClass) {
            // [CAContext remoteContextWithOptions:@{@"kCAContextIgnoresHitTest": @YES}]
            SEL remoteSel = NSSelectorFromString(@"remoteContextWithOptions:");
            if (remoteSel && [caContextClass respondsToSelector:remoteSel]) {
                NSDictionary *opts = @{@"kCAContextIgnoresHitTest": @YES};
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id ctx = [caContextClass performSelector:remoteSel withObject:opts];
#pragma clang diagnostic pop
                if (ctx) {
                    // [ctx setLayer:_window.layer]
                    SEL setLayerSel = NSSelectorFromString(@"setLayer:");
                    if (setLayerSel && [ctx respondsToSelector:setLayerSel] && _window.layer) {
                        void (*setLayerFn)(id, SEL, CALayer *) = (void (*)(id, SEL, CALayer *))[ctx methodForSelector:setLayerSel];
                        if (setLayerFn) setLayerFn(ctx, setLayerSel, _window.layer);
                    }
                    // unsigned ctxId = [ctx contextId]
                    SEL ctxIdSel = NSSelectorFromString(@"contextId");
                    unsigned ctxId = 0;
                    if (ctxIdSel && [ctx respondsToSelector:ctxIdSel]) {
                        unsigned (*ctxIdFn)(id, SEL) = (unsigned (*)(id, SEL))[ctx methodForSelector:ctxIdSel];
                        if (ctxIdFn) ctxId = ctxIdFn(ctx, ctxIdSel);
                    }
                    if (ctxId != 0) {
                        _sbsCAContext = ctx;
                        // [CATransaction flush] 提交渲染, 确保内容进入 context
                        Class txClass = NSClassFromString(@"CATransaction");
                        if (txClass && [txClass respondsToSelector:@selector(flush)]) {
                            [txClass flush];
                        }
                        HUDLog(@"CAContext created explicitly: ctxId=%u", ctxId);
                        return ctxId;
                    }
                    _sbsCAContext = nil;
                }
            }
        }
    } @catch (NSException *e) {
        _sbsCAContext = nil;
        HUDLog(@"CAContext explicit create exception: %@", e);
    }

    // 兜底: window.layer.contextId (旧逻辑, 仅 CAContext 显式创建不可用时)
    CALayer *layer = _window.layer;
    if (layer && [layer respondsToSelector:@selector(contextId)]) {
        return (unsigned)[layer contextId];
    }
    return 0;
}

- (BOOL)_registerAccessibilityHostingWithRetryCount:(NSInteger)retryCount {
    if (retryCount <= 0) {
        HUDLog(@"accessibility hosting: retry exhausted, fallback to foreground");
        _startupFailedSBS = YES;
        return NO;
    }

    @try {
        // 优先显式创建 CAContext, 失败再退回 window.layer.contextId
        unsigned ctxId = [self _acquireContextId];
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

#pragma mark - 脚本方向 (screen.init)

// 设置脚本坐标系方向并旋转 HUD 内容层。
// 方向语义与 Lua screen.init 一致: 0=home在下(竖屏) 1=home在右 2=home在左。
// 旋转规则与 TSLuaBridge 的 tsTransformPoint 严格一致 (portrait→home右/左),
// 确保 HUD 内容坐标系与脚本/取色坐标一致, 横屏游戏里 toast/弹窗横屏显示。
- (void)setScriptOrientation:(NSInteger)orientation {
    if (orientation < 0 || orientation > 2) return;
    _scriptOrientation = orientation;
    if ([NSThread isMainThread]) {
        [self _applyScriptOrientation];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _applyScriptOrientation];
        });
    }
}

// 应用旋转: 旋转 _contentView (HUD 内容层)。
// 只旋转内容视图而不是窗口本身: 窗口 layer 需保持全屏尺寸供 SBS 托管
// (上下文尺寸固定), 旋转内容层即可让 toast/弹窗在横屏坐标系下布局显示。
// 与 TSLuaBridge 坐标变换严格一致: 竖屏为基准, home右/左 旋转 ±90°。
- (void)_applyScriptOrientation {
    if (!_window) return;
    UIView *content = _contentView;
    if (!content) return;

    CGRect winBounds = _window.bounds;
    CGFloat w = CGRectGetWidth(winBounds);
    CGFloat h = CGRectGetHeight(winBounds);

    [UIView performWithoutAnimation:^{
        switch (_scriptOrientation) {
            case 1: // home 在右: 顺时针旋转 90° (portrait→home右: (X,Y)→(Y,Wp-1-X))
                content.transform = CGAffineTransformMakeRotation(M_PI_2);
                content.bounds = CGRectMake(0, 0, h, w);
                content.center = CGPointMake(w / 2.0, h / 2.0);
                break;
            case 2: // home 在左: 逆时针旋转 90° (portrait→home左: (X,Y)→(Hp-1-Y,X))
                content.transform = CGAffineTransformMakeRotation(-M_PI_2);
                content.bounds = CGRectMake(0, 0, h, w);
                content.center = CGPointMake(w / 2.0, h / 2.0);
                break;
            default: // 竖屏
                content.transform = CGAffineTransformIdentity;
                content.bounds = CGRectMake(0, 0, w, h);
                content.center = CGPointMake(w / 2.0, h / 2.0);
                break;
        }
    }];
    HUDLog(@"TSHUDHost script orientation applied: %ld", (long)_scriptOrientation);
}

// 弹窗/toast 布局参考尺寸: 旋转后内容层的 bounds (横屏时宽高已交换),
// 供 HUDCustomAlertView/HUDToastView 在旋转坐标系下布局。
- (CGSize)scriptContentSize {
    if (_contentView) return _contentView.bounds.size;
    if (_scriptOrientation != 0) {
        CGRect winBounds = _window ? _window.bounds : [UIScreen mainScreen].bounds;
        return CGSizeMake(CGRectGetHeight(winBounds), CGRectGetWidth(winBounds));
    }
    return _window ? _window.bounds.size : [UIScreen mainScreen].bounds.size;
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
            // 按旋转后的内容层尺寸布局 (横屏时卡片在横屏坐标系下居中)
            [alert layoutInContainerSize:[self scriptContentSize]];
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
            // 按旋转后的内容层尺寸布局 (横屏时 toast 在横屏坐标系下显示)
            [toast layoutInContainerSize:[self scriptContentSize]];
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
