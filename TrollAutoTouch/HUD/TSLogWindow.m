//
//  TSLogWindow.m — 脚本日志浮动窗口实现
//
//  结构:
//      TSLogOverlayWindow (一个全屏透明 UIWindow, 触摸全穿透)
//          └─ rootViewController.view
//                  └─ _container (内容层, 截图时隐藏它)
//                          └─ TSLogPanel × N   (每个对应脚本里的一个 logWindow 对象)
//
//  三个关键难点(均已在本机的 iOS 15 / TrollStore 环境验证过同样的写法):
//   1) iOS 13+ 手动创建的 UIWindow 必须挂 windowScene 并 makeKeyAndVisible,
//      否则不参与渲染、layer.contextId 恒为 0, 跨应用托管必然失败
//      (逆向自原版 HUDServices, TSHUDHost.m:237-243 已验证)。
//   2) 跨应用可见靠 SBSAccessibilityWindowHostingController +
//      CAContext.remoteContextWithOptions:  (kCAContextIgnoresHitTest /
//      kCAContextUseAlpha), 每个 window 一个 context, level = 10000
//      (同 TSHUDWindow / TSHUDHost)。
//   3) 截图排除不能用 window.hidden —— 部分截屏路径以本 App 的 UIWindow 为
//      receiver 去 createScreenIOSurface, 全隐藏会破坏 surface 创建; 因此这里只
//      隐藏内容层 (root view 的子视图), 窗口本身始终存在。
//

#import "TSLogWindow.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <unistd.h>

#pragma mark - 小工具

/// CATransaction flush: 后台时 CA 提交会被节流, 显式 flush 保证内容立即同步到
/// 远程上下文 / 下一帧合成。
static void TSLogWindowFlushCA(void) {
    if (![NSThread isMainThread]) return;
    Class txClass = NSClassFromString(@"CATransaction");
    if (!txClass) return;
    SEL flushSel = NSSelectorFromString(@"flush");
    if (![txClass respondsToSelector:flushSel]) return;
    void (*flushFn)(id, SEL) = (void (*)(id, SEL))[txClass methodForSelector:flushSel];
    if (flushFn) flushFn(txClass, flushSel);
}

static UIColor *TSLogColorFromHex(int hex) {
    return [UIColor colorWithRed:(CGFloat)(((hex >> 16) & 0xFF)) / 255.0f
                           green:(CGFloat)(((hex >> 8) & 0xFF)) / 255.0f
                            blue:(CGFloat)(hex & 0xFF) / 255.0f
                           alpha:1.0f];
}

#pragma mark - 覆盖窗口 (永不消费触摸)

@interface TSLogOverlayWindow : UIWindow
@end

@implementation TSLogOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;   // 完全穿透: 日志窗口绝不影响任何触摸/脚本点击
}
@end

#pragma mark - 单个日志面板

@interface TSLogPanel : UIView
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) NSMutableAttributedString *content;
@property (nonatomic, strong) UIColor *textColor;
@property (nonatomic, assign) CGFloat fontSize;
@end

@implementation TSLogPanel

- (instancetype)initWithFrame:(CGRect)frame
                        alpha:(CGFloat)alpha
                        bgHex:(int)bgHex
                        fgHex:(int)fgHex
                     fontSize:(CGFloat)size {
    self = [super initWithFrame:frame];
    if (self) {
        CGFloat a = MIN(1.0f, MAX(0.0f, (float)alpha));
        self.backgroundColor = [TSLogColorFromHex(bgHex) colorWithAlphaComponent:a];
        self.opaque = NO;
        self.clipsToBounds = YES;
        self.layer.cornerRadius = 4.0;
        self.userInteractionEnabled = NO;   // 面板不参与触摸
        _textColor = TSLogColorFromHex(fgHex);
        _fontSize = size > 0 ? size : 12.0;
        _content = [[NSMutableAttributedString alloc] init];

        UITextView *tv = [[UITextView alloc] initWithFrame:self.bounds];
        tv.backgroundColor = [UIColor clearColor];
        tv.opaque = NO;
        tv.editable = NO;
        tv.selectable = NO;
        tv.scrollEnabled = YES;
        tv.userInteractionEnabled = NO;    // 不可滚动/选择, 纯展示
        tv.textContainerInset = UIEdgeInsetsMake(2, 4, 2, 4);
        tv.textContainer.lineBreakMode = NSLineBreakByCharWrapping;
        tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _textView = tv;
        [self addSubview:tv];
    }
    return self;
}

- (void)appendLine:(NSString *)line hex:(int)hex size:(CGFloat)size {
    UIColor *color = hex >= 0 ? TSLogColorFromHex(hex) : self.textColor;
    CGFloat fs = size > 0 ? size : self.fontSize;
    UIFont *font = [UIFont systemFontOfSize:fs];
    NSAttributedString *attr = [[NSAttributedString alloc] initWithString:line
                                                               attributes:@{NSForegroundColorAttributeName: color,
                                                                            NSFontAttributeName: font}];
    if (!attr) return;

    if (_content.length > 0) {
        [_content appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    }
    [_content appendAttributedString:attr];

    // 上限保护: 只保留最后 400 行, 避免挂机脚本长时间写入把内存吃光
    NSString *flat = _content.string;
    NSUInteger cut = 0;
    NSUInteger lines = 0;
    for (NSUInteger i = flat.length; i > 0; i--) {
        if ([flat characterAtIndex:i - 1] == '\n') {
            lines++;
            if (lines >= 400) { cut = i; break; }
        }
    }
    if (cut > 0) [_content deleteCharactersInRange:NSMakeRange(0, cut)];

    _textView.attributedText = _content;
    [_textView scrollRangeToVisible:NSMakeRange(_content.length, 0)];
    TSLogWindowFlushCA();
}

@end

#pragma mark - 管理器

@implementation TSLogWindowManager {
    TSLogOverlayWindow *_window;
    UIView *_container;
    NSMutableDictionary<NSNumber *, TSLogPanel *> *_panels;
    NSInteger _nextId;
    BOOL _capturing;
    // 跨应用显示 (SBS 托管, 每个 window 一个 CAContext)
    id _sbsHostingCtrl;
    id _sbsCAContext;
    unsigned _registeredCtxId;
    BOOL _sbsFailed;
}

+ (instancetype)shared {
    static TSLogWindowManager *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[TSLogWindowManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _panels = [NSMutableDictionary dictionary];
        _nextId = 0;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_appDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_appDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
    }
    return self;
}

#pragma mark 主线程执行器

/// UIKit 操作必须在主线程。Lua 脚本跑在后台串行队列, 这里同步等待但带超时,
/// 杜绝与主线程互相等待导致的死锁(与项目其它 HUD 类一致的策略)。
- (void)_onMainSync:(void (^)(void))block {
    if ([NSThread isMainThread]) {
        block();
        return;
    }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { block(); } @catch (NSException *e) { }
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)));
}

#pragma mark 窗口创建 / 销毁

- (UIWindowScene *)_anyWindowScene {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.windowScene) return w.windowScene;
    }
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)scene;
    }
    return nil;
}

- (void)_destroyWindowOnMain {
    [self _unregisterSBSHosting];
    [_container removeFromSuperview];
    _container = nil;
    _window.hidden = YES;
    if (@available(iOS 13.0, *)) { _window.windowScene = nil; }
    _window = nil;
}

- (void)_ensureWindowOnMain {
    if (_window) return;
    CGRect bounds = [UIScreen mainScreen].bounds;
    TSLogOverlayWindow *w = [[TSLogOverlayWindow alloc] initWithFrame:bounds];
    w.windowLevel = UIWindowLevelStatusBar + 100;   // 高于一切普通界面
    w.backgroundColor = [UIColor clearColor];
    w.opaque = NO;
    w.userInteractionEnabled = NO;                  // 触摸穿透
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [self _anyWindowScene];
        if (scene) w.windowScene = scene;
    }
    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    rootVC.view.opaque = NO;
    rootVC.view.userInteractionEnabled = NO;
    w.rootViewController = rootVC;

    UIView *container = [[UIView alloc] initWithFrame:rootVC.view.bounds];
    container.backgroundColor = [UIColor clearColor];
    container.opaque = NO;
    container.userInteractionEnabled = NO;
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [rootVC.view addSubview:container];

    // iOS 13+ 必须 makeKeyAndVisible 才会被 scene 纳入渲染管线并分配 CAContext
    // (contextId≠0), 否则即使 app 在前台也永远不显示。
    w.hidden = NO;
    [w makeKeyAndVisible];
    // 把 key 交还主窗口, 避免影响主界面状态栏样式/键盘行为
    for (UIWindow *mainW in [UIApplication sharedApplication].windows) {
        if (mainW != w && mainW.windowLevel == UIWindowLevelNormal) {
            [mainW makeKeyWindow];
            break;
        }
    }
    _window = w;
    _container = container;
    TSLogWindowFlushCA();
}

#pragma mark 对外 API

- (NSInteger)openAt:(CGPoint)origin
               size:(CGSize)size
              alpha:(CGFloat)alpha
              bgHex:(int)bgHex
              fgHex:(int)fgHex
           fontSize:(CGFloat)fontSize {
    __block NSInteger wid = 0;
    [self _onMainSync:^{
        @try {
            [self _ensureWindowOnMain];
            if (!_window) return;
            CGSize sz = size;
            if (sz.width <= 0)  sz.width = 500;    // 文档默认: 500 × 35
            if (sz.height <= 0) sz.height = 35;
            CGRect frame = CGRectMake(origin.x, origin.y, sz.width, sz.height);
            TSLogPanel *panel = [[TSLogPanel alloc] initWithFrame:frame
                                                            alpha:(alpha > 0 ? alpha : 0.5)
                                                            bgHex:bgHex
                                                            fgHex:fgHex
                                                         fontSize:fontSize];
            if (!panel) return;
            [_container addSubview:panel];
            _nextId += 1;
            wid = _nextId;
            _panels[@(wid)] = panel;
            TSLogWindowFlushCA();
        } @catch (NSException *e) {
            wid = 0;
        }
    }];
    // app 已在后台(脚本跑在别的 app 上): 立即挂系统级托管, 保证肉眼可见
    if (wid > 0 && [UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        [self _registerSBSHosting];
    }
    return wid;
}

- (void)appendText:(NSString *)text hex:(int)hex size:(CGFloat)size windowId:(NSInteger)wid {
    if (wid <= 0) return;
    NSString *copy = [text copy] ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            TSLogPanel *panel = _panels[@(wid)];
            if (!panel) return;
            [panel appendLine:copy hex:hex size:size];
        } @catch (NSException *e) { }
    });
}

- (void)closeWindow:(NSInteger)wid {
    if (wid <= 0) return;
    [self _onMainSync:^{
        @try {
            TSLogPanel *panel = _panels[@(wid)];
            if (panel) {
                [panel removeFromSuperview];
                [_panels removeObjectForKey:@(wid)];
                TSLogWindowFlushCA();
            }
            if (_panels.count == 0) [self _destroyWindowOnMain];
        } @catch (NSException *e) { }
    }];
}

- (void)closeAll {
    [self _onMainSync:^{
        @try {
            for (TSLogPanel *panel in _panels.allValues) [panel removeFromSuperview];
            [_panels removeAllObjects];
            if (_window) [self _destroyWindowOnMain];
        } @catch (NSException *e) { }
    }];
}

#pragma mark 截图排除

- (void)setExcludedFromCapture:(BOOL)excluded {
    if (!self.hideWindowMode) return;                  // 未开隐藏模式: 面板本就允许被截进画面
    if (_panels.count == 0 && !_container) return;     // 没有任何面板: 零开销
    _capturing = excluded;
    [self _onMainSync:^{
        @try {
            // 只隐藏内容层, 窗口本身保持存在 —— 部分截屏路径以本 App 的 UIWindow
            // 为 receiver 创建 IOSurface, 把 window 整个隐藏会破坏 surface 创建。
            _container.hidden = excluded ? YES : NO;
            TSLogWindowFlushCA();
        } @catch (NSException *e) { }
    }];
    // 给合成器一帧时间把隐藏后的画面提交上去, 否则可能截到"还没消失"的旧帧
    if (excluded) usleep(30 * 1000);
}

#pragma mark 跨应用显示 (SBS 系统级托管)

- (void)_registerSBSHosting {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self _registerSBSHosting]; });
        return;
    }
    if (_registeredCtxId != 0 || _sbsFailed || !_window || _window.hidden) return;
    if (_panels.count == 0) return;
    @try {
        unsigned ctxId = [self _acquireSBSContextId];
        if (ctxId == 0) { _sbsFailed = YES; return; }
        Class sbsClass = NSClassFromString(@"SBSAccessibilityWindowHostingController");
        if (!sbsClass) {
            void *h = dlopen("/System/Library/PrivateFrameworks/"
                             "SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
            if (h) sbsClass = NSClassFromString(@"SBSAccessibilityWindowHostingController");
        }
        if (!sbsClass) { _sbsFailed = YES; return; }
        if (!_sbsHostingCtrl) _sbsHostingCtrl = [[sbsClass alloc] init];
        SEL regSel = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
        if (![_sbsHostingCtrl respondsToSelector:regSel]) { _sbsFailed = YES; return; }
        void (*regFn)(id, SEL, unsigned, double) =
            (void (*)(id, SEL, unsigned, double))[_sbsHostingCtrl methodForSelector:regSel];
        if (regFn) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            regFn(_sbsHostingCtrl, regSel, ctxId, 10000.0);
#pragma clang diagnostic pop
        }
        _registeredCtxId = ctxId;
        TSLogWindowFlushCA();
    } @catch (NSException *e) {
        _sbsFailed = YES;
    }
}

- (void)_unregisterSBSHosting {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self _unregisterSBSHosting]; });
        return;
    }
    if (_registeredCtxId == 0) return;
    unsigned ctxId = _registeredCtxId;
    _registeredCtxId = 0;
    @try {
        if (_sbsHostingCtrl) {
            SEL unregSel = NSSelectorFromString(@"unregisterWindowWithContextID:");
            if ([_sbsHostingCtrl respondsToSelector:unregSel]) {
                void (*unregFn)(id, SEL, unsigned) =
                    (void (*)(id, SEL, unsigned))[_sbsHostingCtrl methodForSelector:unregSel];
                if (unregFn) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    unregFn(_sbsHostingCtrl, unregSel, ctxId);
#pragma clang diagnostic pop
                }
            }
        }
    } @catch (NSException *e) { }
}

- (unsigned)_acquireSBSContextId {
    if (_sbsCAContext) {
        SEL ctxIdSel = NSSelectorFromString(@"contextId");
        unsigned ctxId = 0;
        if ([_sbsCAContext respondsToSelector:ctxIdSel]) {
            unsigned (*ctxIdFn)(id, SEL) = (unsigned (*)(id, SEL))[_sbsCAContext methodForSelector:ctxIdSel];
            if (ctxIdFn) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                ctxId = ctxIdFn(_sbsCAContext, ctxIdSel);
#pragma clang diagnostic pop
            }
        }
        if (ctxId != 0) {
            SEL setLayerSel = NSSelectorFromString(@"setLayer:");
            if ([_sbsCAContext respondsToSelector:setLayerSel] && _window.layer) {
                void (*setLayerFn)(id, SEL, CALayer *) =
                    (void (*)(id, SEL, CALayer *))[_sbsCAContext methodForSelector:setLayerSel];
                if (setLayerFn) setLayerFn(_sbsCAContext, setLayerSel, _window.layer);
            }
            return ctxId;
        }
        _sbsCAContext = nil;
    }
    @try {
        Class caClass = NSClassFromString(@"CAContext");
        if (!caClass) {
            void *quartz = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
            if (quartz) caClass = NSClassFromString(@"CAContext");
        }
        if (!caClass) return 0;
        SEL remoteSel = NSSelectorFromString(@"remoteContextWithOptions:");
        if (![caClass respondsToSelector:remoteSel]) return 0;
        NSDictionary *opts = @{@"kCAContextIgnoresHitTest": @YES,   // 触摸穿透
                               @"kCAContextUseAlpha": @YES};        // 带 alpha 的 surface
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id ctx = [caClass performSelector:remoteSel withObject:opts];
        if (ctx && _window.layer) {
            SEL setLayerSel = NSSelectorFromString(@"setLayer:");
            if ([ctx respondsToSelector:setLayerSel]) {
                [ctx performSelector:setLayerSel withObject:_window.layer];
            }
        }
        unsigned ctxId = 0;
        SEL ctxIdSel = NSSelectorFromString(@"contextId");
        if (ctx && [ctx respondsToSelector:ctxIdSel]) {
            unsigned (*ctxIdFn)(id, SEL) = (unsigned (*)(id, SEL))[ctx methodForSelector:ctxIdSel];
            if (ctxIdFn) ctxId = ctxIdFn(ctx, ctxIdSel);
        }
#pragma clang diagnostic pop
        if (ctxId != 0) {
            _sbsCAContext = ctx;
            TSLogWindowFlushCA();
            return ctxId;
        }
    } @catch (NSException *e) {
        _sbsCAContext = nil;
    }
    return 0;
}

- (void)_appDidEnterBackground:(NSNotification *)note {
    if (_panels.count == 0) return;
    [self _registerSBSHosting];
}

- (void)_appDidBecomeActive:(NSNotification *)note {
    [self _unregisterSBSHosting];
}

@end
