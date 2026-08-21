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
    // 活跃内容计数: >0 表示 HUD 内容层有实际内容(弹窗/toast/承载VC)。
    // 只有有内容时才注册 SBS 系统级托管并保持窗口可见; 内容清空(计数=0)时
    // 注销托管 + 隐藏窗口, 避免后台时全屏托管窗口吞掉整个屏幕的触摸。
    NSInteger _activeContentCount;
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

// 全屏白屏的根因与修复策略 (重要):
// CAContext 是私有类, iOS/macOS 私有头均确认它没有任何 opaque/背景色属性,
// 也没有 setOpaque: 方法。因此旧实现"远程上下文默认 opaque=YES、运行时调用
// setOpaque:NO 置透明"的方案是无效的 (respondsToSelector 检查直接失败, 静默
// 无操作), 白屏问题并未被修复。
//
// 实际机制: remoteContextWithOptions: 创建的远程上下文在 WindowServer 端有
// 默认合成背景 (白色)。只要 context 内的 layer 树没有覆盖整个屏面的"已提交
// 内容", 未被内容覆盖的区域就会按白色合成。本宿主窗口本身全透明 (clearColor),
// 内容为空时 CA 不会把透明空 layer 提交成像素 → 整块区域保持默认白色。
// 该 context 被 SBS 托管在 level 10000 (高于 SpringBoard 全部 UI), 结果就是
// 全屏白屏 + 状态栏/HOME 手势区/锁屏全部被遮挡, 表现为"HOME 无响应"。
//
// 真正的修复在 start 里的"全屏透明垫层": 在窗口 layer 树底部永远挂一个覆盖
// 整个屏面的近透明视图 (alpha=0.01, 与旧渲染锚点同色), 让远程上下文任意时刻
// 都有覆盖全屏的已提交内容 → 整屏按 alpha≈0 合成, 游戏画面正常透出, 白屏
// 不再出现。这也是 Go 版参考实现 (__fbInstallCAContextOverlay) 能正常工作的
// 原因: 其 layer 树始终有全屏内容。

// 主线程强制提交 Core Animation 事务:
// App 处于后台时 (游戏在前台), CA 提交会被系统节流/跳过, 新添加的弹窗/toast
// layer 可能一直不同步到 SBS 托管的远程上下文, 表现为"UI 已显示(白底/首帧)
// 但按钮等控件不渲染"。显式 flush 绕过节流, 确保内容立即进入远程上下文。
static void TSHUDFlushCATransaction(void) {
    Class txClass = NSClassFromString(@"CATransaction");
    if (txClass && [txClass respondsToSelector:@selector(flush)]) {
        [txClass flush];
    }
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
        _window.opaque = NO; // 透明窗口: layer.opaque 必须为 NO, 否则整窗按不透明合成

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
        _rootVC.view.opaque = NO; // 透明合成前提: layer.opaque=NO
        _window.rootViewController = _rootVC;

        // 全屏透明垫层 (白屏修复的关键, 取代旧 1x1 渲染锚点):
        // ① 窗口 layer 树必须真正参与离屏渲染, layer 才会被分配 CAContext
        //    (contextId≠0)。纯 clearColor 的空内容会被系统优化掉 → contextId=0
        //    → SBS 托管永远失败。alpha=0.01 的近透明色: 肉眼不可见, 强制渲染。
        // ② 远程上下文 (remoteContextWithOptions:) 在 WindowServer 端默认白色
        //    合成背景, 若 context 内没有覆盖整个屏面的已提交内容, 未被覆盖的
        //    区域按白色合成 → 全屏白屏 (level 10000 盖住 SpringBoard 全部 UI,
        //    HOME 失效)。旧 1x1 锚点只能强制 context 存在, 1x1 之外仍是未渲染
        //    区域 → 依旧白屏。本垫层铺满整个屏面 (位于内容层之下, 不随脚本
        //    方向旋转), 保证 context 任意时刻都有覆盖全屏的已提交透明内容。
        // 代价: 全屏约 1% 的黑色着色 (alpha=0.01), 肉眼不可见; findColor 的
        // 相似度容差 (通常 ≥0.9) 完全覆盖该偏移, 不影响找色。
        // 注意: 必须加在 _contentView 之前 (位于其下); userInteractionEnabled=NO
        // 使 hitTest 返回 nil, 不拦截任何触摸。
        UIView *backdrop = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
        backdrop.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.01];
        backdrop.layer.opaque = NO;
        backdrop.userInteractionEnabled = NO;
        backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_rootVC.view addSubview:backdrop];

        // 内容容器: 所有弹窗/toast 挂载在此, 脚本方向旋转只作用于容器,
        // rootVC.view 保持系统管理 (frame 始终跟随 window.bounds, 不受旋转影响)。
        _contentView = [[UIView alloc] initWithFrame:_rootVC.view.bounds];
        _contentView.backgroundColor = [UIColor clearColor];
        _contentView.opaque = NO;
        // 关键: 内容层不随窗口缩放 (autoresizingMask = None)。
        // toast/alert 显示期间 _window.frame 会缩小到卡片实际区域 (见
        // _resizeHostWindowToContent), 若内容层跟随窗口压缩, 卡片绝对坐标
        // 全部错位/裁剪。保持全屏 frame 后, 卡片按"屏幕绝对坐标"定位,
        // 缩小后的窗口恰好包住卡片 → 显示完整, 窗口外触摸穿透到前台 app。
        _contentView.autoresizingMask = UIViewAutoresizingNone;
        [_rootVC.view addSubview:_contentView];
        // 窗口 hitTest 依据该容器做空白穿透 (命中容器本身 → 不消费触摸)
        _window.contentContainer = _contentView;

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

        // 系统级托管 (SBS) 改为惰性注册: 启动时不注册, 由 _bumpActiveContent
        // (有弹窗/toast/承载VC 内容时) 触发。理由: 全屏托管窗口只要注册在,
        // App 后台时就会吞掉整个屏幕的触摸 ("其他应用/主屏幕点击无反应"严重BUG)。
        // 窗口本身保持创建 (app 内透明, hitTest 穿透, 不托管时不影响任何触摸)。

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
    // 惰性托管: 仅当 HUD 内容层有实际内容时才注册系统级托管,
    // 无内容时保持未托管 (避免后台时全屏托管窗口吞掉整屏触摸)。
    if (_activeContentCount > 0) {
        [self _registerAccessibilityHostingWithRetryCount:10];
    }
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
            // app 激活后 context 可能重建: 重新 setLayer 挂上窗口 layer,
            // 并 flush 确保全屏透明垫层等已有内容进入重建后的上下文 (否则
            // 后台 CA 提交被节流, 上下文可能保持"无内容→白屏")。
            TSHUDFlushCATransaction();
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
            // [CAContext remoteContextWithOptions:@{...}]
            SEL remoteSel = NSSelectorFromString(@"remoteContextWithOptions:");
            if (remoteSel && [caContextClass respondsToSelector:remoteSel]) {
                // kCAContextIgnoresHitTest: 触摸穿透 (不拦截下层 app 的触摸)。
                // kCAContextUseAlpha: 请求带 alpha 通道的 surface (透明合成前提;
                // 该 key 在 iOS 运行时即使被忽略也无害, 全屏垫层仍兜底)。
                NSDictionary *opts = @{
                    @"kCAContextIgnoresHitTest": @YES,
                    @"kCAContextUseAlpha": @YES,
                };
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
                        // [CATransaction flush] 提交渲染: 把全屏透明垫层等已有
                        // 内容一次性提交进远程上下文。不 flush 的话后台时 CA
                        // 提交被节流, context 可能保持"无内容 → 白屏"。
                        // 透明性由①带 alpha 的 surface + ②全屏透明垫层共同保证
                        // (CAContext 没有 setOpaque: 方法, 无 API 可调)。
                        TSHUDFlushCATransaction();
                        HUDLog(@"CAContext created explicitly: ctxId=%u (alpha surface + fullscreen backdrop)", ctxId);
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

#pragma mark - 活跃内容计数 (有内容才托管, 无内容立即解除)

// 核心修复 (用户报告的严重BUG: 只能在本应用内触摸, 其他应用/主屏幕点击无反应):
// SBS 系统级托管窗口 (level 10000, 全屏) 只要注册在, App 后台时 (其他 app/
// 主屏幕在前台) SpringBoard 层的触摸命中就会落到这个全屏窗口并把事件吞掉
// (app 内的 hitTest 穿透只在本进程前台分发时生效, 跨进程时无效), 表现为
// "其他应用和主屏幕点击任何地方都没有反应, 只有本 App 内能触摸"。
// 因此托管必须"按需": 有弹窗/toast/承载VC 内容时才注册, 内容清空立即注销。
- (void)_bumpActiveContent {
    if (!_started) [self start];
    _activeContentCount++;
    if (_activeContentCount == 1) {
        // 首次出现内容: 确保窗口可见并注册系统级托管 (已注册/注册失败则跳过)
        _window.hidden = NO;
        if (_registeredContextId == 0 && !_startupFailedSBS) {
            [self _registerAccessibilityHostingWithRetryCount:10];
        }
    }
}

// 把 SBS 托管窗口缩小到内容实际区域 (toast/alert 卡片), 窗口外触摸穿透到前台 app。
//
// 背景: SBS 系统级托管窗口在 SpringBoard 进程内按 layer frame 做命中测试,
// app 内 hitTest 返回 nil 的"穿透"跨进程完全无效 → 全屏托管窗口必然吞掉
// 整个屏幕的触摸 (表现为 "toast 显示期间点击无效"、"关闭公告按钮点不了")。
// 这里把窗口 frame 缩到内容卡片区域, 只有卡片区域被系统级拦截:
//  - toast (纯展示, 无交互): 卡片区域吞触摸可接受
//  - alert (需点按钮): 卡片+按钮区域命中有效, 四周穿透到前台 app
//  - 全屏 VC 承载 (ui.open 网页设置页): union 结果为全屏 → 自动保持全屏交互
- (void)_resizeHostWindowToContent {
    if (!_window || !_contentView) return;
    // 未注册系统级托管 (前台降级模式): 窗口在 app 内, hitTest 已穿透, 无需缩小。
    if (_registeredContextId == 0) {
        [self _restoreHostWindowFrame];
        return;
    }
    CGRect full = [UIScreen mainScreen].bounds;
    // ★ 关键: 计算前先把窗口恢复为全屏。
    // convertRect:toView:_window 的结果是"窗口局部坐标" (相对窗口 bounds
    // 原点 (0,0))。若窗口正处在上次 toast/alert 缩小后的状态 (frame.origin
    // 非零), 直接用该结果设置 window.frame, 窗口会先移到"局部坐标"位置,
    // 内容再按 frame.origin 偏移一次 → 卡片整体偏移 (toast 被移到屏幕右侧)。
    // 从全屏状态计算时窗口局部坐标 == 屏幕绝对坐标, 结果唯一且正确。
    [self _restoreHostWindowFrame];

    CGRect unionRect = CGRectNull;
    for (UIView *sub in _contentView.subviews) {
        if (sub.hidden || sub.alpha <= 0.01) continue;
        CGRect subRect = [_contentView convertRect:sub.bounds fromView:sub];
        unionRect = CGRectIsNull(unionRect) ? subRect : CGRectUnion(unionRect, subRect);
    }
    if (CGRectIsNull(unionRect)) {
        [self _restoreHostWindowFrame];
        return;
    }
    // 内容坐标系 → 窗口坐标系 (contentView 可能带脚本方向旋转 transform)
    CGRect winRect = [_contentView convertRect:unionRect toView:_window];
    winRect = CGRectInset(winRect, -16.0, -16.0);       // 少量留白
    winRect = CGRectIntersection(winRect, full);         // 不出屏
    if (CGRectIsEmpty(winRect) ||
        CGRectGetWidth(winRect) < 24.0 || CGRectGetHeight(winRect) < 24.0) {
        // 计算异常时回退全屏, 保证内容一定可见
        [self _restoreHostWindowFrame];
        return;
    }
    [UIView performWithoutAnimation:^{
        if (!CGRectEqualToRect(_window.frame, winRect)) {
            _window.frame = winRect;
        }
        // ★ 关键: 窗口缩小后, 窗口局部坐标系原点 (bounds 原点) 在屏幕上的
        // 位置 = window.frame.origin。内容层 (contentView) 保持全屏 frame
        // 且不随窗口缩放, 卡片按屏幕绝对坐标定位, 但其窗口局部坐标 =
        // 绝对坐标 - frame.origin, 超出窗口 bounds (0,0,w,h) 的部分会被
        // 远程上下文裁剪/错位显示。把内容层整体平移到 (-frame.origin),
        // 卡片即落在窗口局部坐标内 (相对窗口左上角留白处), 无论 SBS 按
        // "窗口局部渲染"还是"frame 对齐"方式合成, 卡片都显示在原来的
        // 屏幕绝对坐标 (toast 保持左右居中), 同时 alert 按钮仍位于窗口
        // 触摸区域内 (可正常点击)。
        _contentView.center = CGPointMake(CGRectGetMidX(full) - CGRectGetMinX(winRect),
                                          CGRectGetMidY(full) - CGRectGetMinY(winRect));
    }];
}

// 恢复 SBS 托管窗口为全屏 (内容清空 / 旋转计算前)。
- (void)_restoreHostWindowFrame {
    if (!_window) return;
    CGRect full = [UIScreen mainScreen].bounds;
    if (!CGRectEqualToRect(_window.frame, full)) {
        _window.frame = full;
    }
    // 还原内容层平移: 窗口恢复全屏后, 内容层需回到全屏原点对齐
    // (center = 全屏中心), 否则下次 toast/alert 布局 (基于全屏坐标)
    // 会带着缩小窗口时的平移偏移, 显示错位。
    if (_contentView) {
        CGPoint homeCenter = CGPointMake(CGRectGetMidX(full), CGRectGetMidY(full));
        if (!CGPointEqualToPoint(_contentView.center, homeCenter)) {
            _contentView.center = homeCenter;
        }
    }
}

- (void)_dropActiveContent {
    if (_activeContentCount > 0) _activeContentCount--;
    if (_activeContentCount == 0) {
        // 内容清空: 恢复全屏 frame, 注销系统级托管并隐藏窗口,
        // 解除全屏触摸吞没。窗口隐藏后下次 _bumpActiveContent 会重新显示并重新注册。
        [self _restoreHostWindowFrame];
        [self _unregisterAccessibilityHosting];
        _window.hidden = YES;
    }
}

- (void)_unregisterAccessibilityHosting {
    if (_registeredContextId == 0) return;
    unsigned ctxId = _registeredContextId;
    _registeredContextId = 0;
    @try {
        if (!_sbsHostingCtrl) return;
        SEL unregSel = NSSelectorFromString(@"unregisterWindowWithContextID:");
        if ([_sbsHostingCtrl respondsToSelector:unregSel]) {
            void (*fn)(id, SEL, unsigned) = (void (*)(id, SEL, unsigned))[_sbsHostingCtrl methodForSelector:unregSel];
            if (fn) fn(_sbsHostingCtrl, unregSel, ctxId);
            HUDLog(@"accessibility window hosting unregistered: contextId=%u (no active content)", ctxId);
        }
    } @catch (NSException *e) {
        HUDLog(@"accessibility hosting unregister exception: %@", e);
    }
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
                // 内容可能已消失 (弹窗已关/toast 已移除): 无活跃内容时不再重试
                // 注册, 避免后台残留全屏托管窗口吞掉整个屏幕的触摸。
                if (self && !self->_startupFailedSBS && self->_activeContentCount > 0) {
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

#pragma mark - 预热 (冷启动时预创建 CAContext)

// 冷启动后首次按音量键弹窗的根因 (用户反馈"启动 App 后要按 4 次音量键
// 才弹出暂停/运行按钮, 之后每按一次正常; 杀进程重开后再次复现"):
// 首次弹窗才惰性注册 SBS 托管 (_bumpActiveContent → _register...),
// 而 _acquireContextId 在 app 刚启动(甚至已在后台)时首次创建
// CAContext remoteContextWithOptions: 常返回 ctxId=0 → 注册走 0.5s 重试;
// 但弹窗检查到"未注册且 app 不在前台"立即 _dropActiveContent (计数归零),
// 0.5s 后重试回调发现活跃内容已清空 → 重试中止 → 托管永远注册不上,
// 弹窗返回 nil 被静默跳过。用户连按多次, 直到某次 CAContext 创建成功
// (CA/WindowServer 管线就绪), 弹窗才出现。
// 修复①: App 启动(前台激活)时预创建 CAContext 缓存到 _sbsCAContext,
// 首次按键时 _acquireContextId 立即返回非零 ctxId → 托管注册即时完成。
// 只预创建 context, 不注册 SBS 托管 (惰性托管不变, 不残留全屏托管窗口)。
- (void)prepareOverlayContext {
    [self ensureStartedOnMainThread];
    if (_startupFailedSBS) return;

    // 主线程同步创建一次 (CAContext/窗口 layer 操作必须在主线程)
    __block unsigned cid = 0;
    if ([NSThread isMainThread]) {
        cid = [self _acquireContextId];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            cid = [self _acquireContextId];
        });
    }
    if (cid != 0) {
        HUDLog(@"prepareOverlayContext: ready (ctxId=%u)", cid);
        return;
    }

    // 首次创建失败 (启动早期 CA/WindowServer 连接未就绪):
    // 后台轮询重试, 直到 contextId 非零 (每 0.2s, 最多 40 次 ≈ 8s)。
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        for (int i = 0; i < 40; i++) {
            if (self->_startupFailedSBS) return;
            __block unsigned ctx = 0;
            dispatch_sync(dispatch_get_main_queue(), ^{
                ctx = [self _acquireContextId];
            });
            if (ctx != 0) {
                HUDLog(@"prepareOverlayContext: done (ctxId=%u, attempt=%d)", ctx, i + 1);
                return;
            }
            usleep(200 * 1000);
        }
        HUDLog(@"prepareOverlayContext: give up (ctxId still 0 after 8s)");
    });
}

// 等待 SBS 系统级托管注册完成 (弹窗路径兜底, 修复②)。
// 冷启动后首次按键时, 若预热未及时完成 (或直接走首次弹窗), 托管注册
// 需要时间 (CAContext 首次创建失败 → 0.5s 重试, 最多 10 次 ≈ 5s)。
// 等待期间调用方必须保持 _activeContentCount > 0 (不 drop),
// 否则注册重试会因无活跃内容而中止。
// 线程安全: _registeredContextId/_startupFailedSBS 主线程写, 本方法在
// 后台线程读 (标量读, 与弹窗主线程写无竞态窗口; 原代码多处同此模式)。
- (BOOL)waitForAccessibilityHostingWithTimeout:(NSTimeInterval)timeout {
    if (_registeredContextId != 0) return YES;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        if (_registeredContextId != 0) return YES;
        if (_startupFailedSBS) return NO;
        usleep(200 * 1000);
    }
    return _registeredContextId != 0;
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
    // 旋转计算基于全屏 bounds: 若窗口正被 toast/alert 缩小, 先恢复全屏
    // 再按全屏尺寸计算 contentView 的 bounds/center。
    [self _restoreHostWindowFrame];
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

    __block NSString *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    // 主线程显示弹窗 (前置条件已满足: 系统级托管已注册, 或 app 前台可见)。
    // 抽出为独立 block, 供"注册就绪后延迟显示"复用。
    void (^showOnMain)(void) = ^{
        @try {
            UIView *host = [self _displayContentView];
            HUDCustomAlertView *alert = [[HUDCustomAlertView alloc] initWithTitle:title
                                                                          message:message
                                                                          buttons:buttons
                                                                          timeout:timeout
                                                                         onResult:^(NSString *r) {
                result = r;
                // 弹窗关闭 (HUDCustomAlertView 已自动移除自身):
                // 活跃内容清空 → 注销系统级托管 + 隐藏窗口, 解除全屏触摸吞没。
                [self _dropActiveContent];
                dispatch_semaphore_signal(sem);
            }];
            // 按旋转后的内容层尺寸布局 (横屏时卡片在横屏坐标系下居中)
            [alert layoutInContainerSize:[self scriptContentSize]];
            [host addSubview:alert];
            [alert show];
            // 弹窗只占屏幕局部 → 把 SBS 托管窗口缩到卡片区域,
            // 卡片四周触摸穿透到前台 app (否则弹窗显示期间全屏点击无效)。
            [self _resizeHostWindowToContent];
            // 后台时 CA 提交会被节流/跳过, 显式 flush 确保弹窗内容
            // (卡片/按钮) 立即同步到 SBS 托管的远程上下文, 否则只显示白底不渲染控件。
            TSHUDFlushCATransaction();
        } @catch (NSException *e) {
            HUDLog(@"presentAlert exception: %@", e);
            [self _dropActiveContent];
            dispatch_semaphore_signal(sem);
        }
    };

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 先计入活跃内容并确保系统级托管注册 (惰性托管), 再判断可见性:
            // 首次后台弹窗此刻才注册 SBS, 注册成功则 contentView 可挂载。
            [self _bumpActiveContent];
            if (_registeredContextId == 0 &&
                [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
                // SBS 托管尚未注册 且 app 不在前台: 不能立即放弃——
                // 冷启动后首次按键时托管注册需要时间 (CAContext 首次创建
                // 可能失败 → 0.5s 重试), 若此刻 _dropActiveContent (计数归零),
                // 重试回调会发现活跃内容已清空而中止, 弹窗被静默跳过,
                // 表现为"要按多次音量键才出弹窗"。
                // 改为: 保持活跃内容 (不 drop), 后台等待注册完成 (最长 6s),
                // 注册成功后再显示; app 中途回前台也可直接显示 (前台降级路径)。
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    BOOL ready = [self waitForAccessibilityHostingWithTimeout:6.0];
                    BOOL appActive = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (ready || appActive) {
                            showOnMain();
                        } else {
                            // 注册彻底失败 (重试耗尽/类缺失) 且仍在后台:
                            // 补平计数, 返回 nil, 调用方回退静默切换/前台处理。
                            HUDLog(@"presentAlert skipped: SBS hosting not registered after wait");
                            [self _dropActiveContent];
                            dispatch_semaphore_signal(sem);
                        }
                    });
                });
                return;
            }
            showOnMain();
        } @catch (NSException *e) {
            HUDLog(@"presentAlert exception: %@", e);
            [self _dropActiveContent];
            dispatch_semaphore_signal(sem);
        }
    });

    // 超时兜底: 防 SBS 托管失败导致弹窗不可见时永久阻塞。
    // timeout>0 时 HUDCustomAlertView 内部超时会自动关闭; 此处额外保护。
    // +6s 覆盖注册等待 (最长 6s)。
    NSTimeInterval maxWait = (timeout > 0 ? timeout : 60.0) + 15.0 + 6.0;
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
            // 先计入活跃内容并确保系统级托管注册 (惰性托管), 再判断可见性:
            // 首次后台 toast 此刻才注册 SBS, 注册成功则 contentView 可挂载。
            [self _bumpActiveContent];
            if (_registeredContextId == 0 &&
                [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
                // SBS 托管注册失败 且 app 不在前台: toast 加在窗口上也看不到,
                // 补平计数后返回, 记日志便于排查 (不再静默失败)。
                [self _dropActiveContent];
                HUDLog(@"showToast skipped (not foreground & SBS not registered): %@", text);
                return;
            }
            UIView *host = [self _displayContentView];
            HUDToastView *toast = [[HUDToastView alloc] initWithText:text
                                                            duration:duration
                                                              hidden:hidden];
            // toast 自动消失时回调: 清空活跃内容 → 注销系统级托管 + 隐藏窗口
            __weak typeof(self) weakSelf = self;
            toast.onRemoved = ^{
                [weakSelf _dropActiveContent];
            };
            // 按旋转后的内容层尺寸布局 (横屏时 toast 在横屏坐标系下显示)
            [toast layoutInContainerSize:[self scriptContentSize]];
            [host addSubview:toast];
            [toast show];
            // toast 只占屏幕局部 → 把 SBS 托管窗口缩到 toast 区域,
            // toast 之外的触摸穿透到前台 app (否则 toast 显示期间全屏点击无效)。
            [self _resizeHostWindowToContent];
            // 后台时 CA 提交会被节流/跳过, 显式 flush 确保 toast 立即同步到远程上下文。
            TSHUDFlushCATransaction();
        } @catch (NSException *e) {
            HUDLog(@"showToast exception: %@", e);
            [self _dropActiveContent];
        }
    });
}

#pragma mark - 承载 UIViewController (App 后台时 ui.open 网页设置页)

- (BOOL)presentViewControllerInHUD:(UIViewController *)vc {
    if (!vc) return NO;
    [self ensureStartedOnMainThread];
    __block BOOL shown = NO;
    if ([NSThread isMainThread]) {
        shown = [self _attachVCToHUD:vc];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            shown = [self _attachVCToHUD:vc];
        });
    }
    return shown;
}

- (void)dismissViewControllerFromHUD:(UIViewController *)vc {
    if (!vc) return;
    if ([NSThread isMainThread]) {
        [self _detachVCFromHUD:vc];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _detachVCFromHUD:vc];
        });
    }
}

// 把 vc.view 全屏挂到 HUD 内容层, 并手动触发 appearance 回调。
// UIView 级承载不经过 UIKit 的 present 流程, viewWillAppear:/viewDidAppear:
// 不会自动调用, 需用 beginAppearanceTransition:/endAppearanceTransition: 补齐。
- (BOOL)_attachVCToHUD:(UIViewController *)vc {
    @try {
        // 先计入活跃内容并确保系统级托管注册 (惰性托管), 再判断可见性:
        // 首次后台承载 VC 此刻才注册 SBS, 注册成功则 contentView 可挂载。
        [self _bumpActiveContent];
        if (_registeredContextId == 0 &&
            [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            // SBS 托管注册失败 且 app 不在前台: 挂上去也看不到, 补平计数后
            // 返回 NO 让调用方立即结束阻塞等待。
            [self _dropActiveContent];
            HUDLog(@"presentViewControllerInHUD skipped: not foreground & SBS not registered");
            return NO;
        }
        UIView *host = [self _displayContentView];
        if (!host) {
            [self _dropActiveContent];
            return NO;
        }
        // 全屏铺满内容层; 内容层随脚本坐标系旋转, 网页设置页跟随 (横屏游戏时横屏显示)
        vc.view.frame = host.bounds;
        vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [vc beginAppearanceTransition:YES animated:NO];
        [host addSubview:vc.view];
        [vc endAppearanceTransition];
        // 后台时 CA 提交会被节流/跳过, 显式 flush 确保网页设置页立即同步到远程上下文。
        TSHUDFlushCATransaction();
        HUDLog(@"presentViewControllerInHUD attached: %@", NSStringFromClass([vc class]));
        return YES;
    } @catch (NSException *e) {
        HUDLog(@"presentViewControllerInHUD exception: %@", e);
        [self _dropActiveContent];
        return NO;
    }
}

- (void)_detachVCFromHUD:(UIViewController *)vc {
    @try {
        if (vc.view.superview == nil) return; // 未挂载: 未 bump, 无需 drop
        [vc beginAppearanceTransition:NO animated:NO];
        [vc.view removeFromSuperview];
        [vc endAppearanceTransition];
        // 活跃内容清空 → 注销系统级托管 + 隐藏窗口, 解除全屏触摸吞没
        [self _dropActiveContent];
        // 后台时 CA 提交会被节流/跳过, 显式 flush 确保移除立即同步。
        TSHUDFlushCATransaction();
    } @catch (NSException *e) {
        HUDLog(@"dismissViewControllerFromHUD exception: %@", e);
    }
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
    // 活跃内容计数: 无内容时必然未托管 (惰性托管), 有内容时才系统级托管
    NSString *activeState = [NSString stringWithFormat:@"activeContent=%ld", (long)_activeContentCount];
    return [NSString stringWithFormat:@"HUD 宿主状态: %@ | %@ | %@ | %@ | %@",
            clsState, ctxState, failState, fgState, activeState];
}

@end
