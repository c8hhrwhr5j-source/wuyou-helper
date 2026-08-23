//
//  TSHUDWindow.m
//  TrollAutoTouch
//
//  悬浮窗实现: 悬浮球 + 向左展开的快捷按钮组 (暂停/恢复、启动/停止、关闭)
//  所有按钮仅图标, 不显示文字。点击悬浮球本体: 未展开则展开, 已展开则收回(取消)。
//

#import "TSHUDWindow.h"
#import "../Script/TSLuaBridge.h"
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

// 悬浮球尺寸
static const CGFloat kBallSize    = 44.0;
// 展开按钮尺寸
static const CGFloat kBtnSize     = 44.0;
// 按钮间距
static const CGFloat kGap         = 8.0;
// 展开按钮数量 (关闭/启停/暂停)
static const NSInteger kExtCount  = 3;
// 悬浮球在窗口内的 X 坐标 (窗口右侧, 按钮组向左展开)
static const CGFloat kBallX       = kBallSize + kGap + kBtnSize * 2 + kGap * 2; // 44+8+44*2+8*2=156
// 展开后的窗口宽度
static const CGFloat kExpandedW   = kBallX + kBallSize; // 200

@interface TSHUDWindow ()

@property (nonatomic, strong) UIViewController *rootVC;
@property (nonatomic, strong) UIButton *mainBtn;      // 悬浮球本体
@property (nonatomic, strong) UIButton *pauseBtn;     // 暂停/恢复
@property (nonatomic, strong) UIButton *toggleBtn;    // 启动/停止
@property (nonatomic, strong) UIButton *closeBtn;     // 关闭

@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) BOOL paused;

@property (nonatomic, strong) UIPanGestureRecognizer *pan;

@end

// 脚本运行状态 (通过 setScriptRunning: 更新, 用 ivar 避免与自定义访问器冲突)
@implementation TSHUDWindow {
    BOOL _scriptRunning;
    // 跨应用显示 (SBS accessibility window hosting, 逆向自 AutoGoRunner/agoverlayd):
    // app 退到后台时把悬浮球窗口的 CAContext 托管到 SpringBoard 的 accessibility
    // 窗口层, 使悬浮球在其它 app / 主屏幕之上保持可见。触摸穿透 (不拦截下层 app)。
    id _sbsHostingCtrl;      // SBSAccessibilityWindowHostingController
    id _sbsCAContext;        // 显式 CAContext (remoteContextWithOptions:)
    unsigned _registeredCtxId;
    BOOL _sbsFailed;
}

+ (instancetype)shared {
    static dispatch_once_t once;
    static TSHUDWindow *instance = nil;
    dispatch_once(&once, ^{
        // 全屏透明悬浮窗 (高 level)
        instance = [[TSHUDWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        instance.windowLevel = UIWindowLevelStatusBar + 1;
        instance.backgroundColor = [UIColor clearColor];
        instance.hidden = YES;
    });
    return instance;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _expanded = NO;
        _scriptRunning = NO;
        _paused = NO;

        _rootVC = [[UIViewController alloc] init];
        _rootVC.view.backgroundColor = [UIColor clearColor];
        self.rootViewController = _rootVC;

        [self _buildButtons];
        [self _layoutBall];
        [self _refreshButtons];

        // 监听脚本运行状态, 自动刷新按钮图标/禁用状态
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_onLuaStateChanged:)
                                                     name:TSLuaRunningStateChangedNotification
                                                   object:nil];
        // app 前后台切换: 后台时把悬浮球托管到系统层(跨应用可见), 前台时交还 app 内
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

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 构建 UI

- (void)_buildButtons {
    _mainBtn = [self _makeRoundButton:nil action:@selector(_tapMain:)];
    _mainBtn.frame = CGRectMake(kBallX, 0, kBallSize, kBallSize);
    [self _applyIcon:[self _hudIcon:@"bolt.fill"] to:_mainBtn];
    // 悬浮球带拖拽
    _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_panMain:)];
    [_mainBtn addGestureRecognizer:_pan];

    _pauseBtn  = [self _makeRoundButton:nil action:@selector(_tapPause:)];
    _toggleBtn = [self _makeRoundButton:nil action:@selector(_tapToggle:)];
    _closeBtn  = [self _makeRoundButton:nil action:@selector(_tapClose:)];
    // 明显的 X 关闭图标 (之前从未设置图标, 显示为一团深色圆)
    [self _applyIcon:[self _hudIcon:@"xmark"] to:_closeBtn];

    _pauseBtn.frame  = CGRectMake(kBallX - (kBtnSize + kGap) * 1, 0, kBtnSize, kBtnSize);
    _toggleBtn.frame = CGRectMake(kBallX - (kBtnSize + kGap) * 2, 0, kBtnSize, kBtnSize);
    _closeBtn.frame  = CGRectMake(kBallX - (kBtnSize + kGap) * 3, 0, kBtnSize, kBtnSize);

    // 初始隐藏扩展按钮 (位于悬浮球左侧, 未展开):
    // 收起状态由 alpha=0 + userInteractionEnabled=NO 控制 (alpha<0.01 不参与命中测试),
    // 不再用 hidden, 避免展开/收起动画 completion 的 hidden 竞态导致收起后无法再展开。
    _pauseBtn.alpha  = 0;
    _toggleBtn.alpha = 0;
    _closeBtn.alpha  = 0;
    _pauseBtn.userInteractionEnabled  = NO;
    _toggleBtn.userInteractionEnabled = NO;
    _closeBtn.userInteractionEnabled  = NO;

    [_rootVC.view addSubview:_closeBtn];
    [_rootVC.view addSubview:_toggleBtn];
    [_rootVC.view addSubview:_pauseBtn];
    [_rootVC.view addSubview:_mainBtn];
}

- (UIButton *)_makeRoundButton:(UIImage *)image action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(0, 0, kBtnSize, kBtnSize);
    b.layer.cornerRadius = kBtnSize / 2.0;
    b.layer.masksToBounds = YES;
    b.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.88];
    if (image) [b setImage:image forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// 初始悬浮球位置: 屏幕右侧中部
- (void)_layoutBall {
    CGRect f = self.frame;
    f.size = CGSizeMake(kExpandedW, kBallSize);
    f.origin.x = [UIScreen mainScreen].bounds.size.width - kExpandedW - 12;
    f.origin.y = [UIScreen mainScreen].bounds.size.height * 0.5;
    self.frame = f;
}

- (UIImage *)_hudIcon:(NSString *)name {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:17
                                                                                         weight:UIImageSymbolWeightSemibold];
        UIImage *img = [[UIImage systemImageNamed:name] imageByApplyingSymbolConfiguration:cfg];
        return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return nil;
}

- (void)_applyIcon:(UIImage *)img to:(UIButton *)b {
    [b setImage:img forState:UIControlStateNormal];
    b.tintColor = [UIColor whiteColor];
}

#pragma mark - 状态刷新

- (void)_refreshButtons {
    // 注意: 按钮 alpha 完全由展开/收起动画管理, 这里只更新图标与可用状态。
    // 之前无条件写 _pauseBtn.alpha=1.0, 收起状态收到 Lua 状态通知会把按钮
    // alpha 拉回 1.0, 导致"收起后按钮仍可见/状态错乱"。
    // 暂停/恢复: 脚本未运行时灰色禁用
    if (_scriptRunning) {
        _pauseBtn.enabled = YES;
        _pauseBtn.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.88];
        [self _applyIcon:[self _hudIcon:(_paused ? @"play.fill" : @"pause.fill")] to:_pauseBtn];
    } else {
        _pauseBtn.enabled = NO;
        _pauseBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.5];
        [self _applyIcon:[self _hudIcon:@"pause.fill"] to:_pauseBtn];
    }
    // 启动/停止: 未运行显示 play, 运行中显示 stop
    if (_scriptRunning) {
        [self _applyIcon:[self _hudIcon:@"stop.fill"] to:_toggleBtn];
    } else {
        [self _applyIcon:[self _hudIcon:@"play.fill"] to:_toggleBtn];
    }
    // 后台且已系统级托管时, CA 提交被节流; 强制 flush 让图标变化立即同步到远程上下文
    [CATransaction flush];
}

- (void)setScriptRunning:(BOOL)running {
    _scriptRunning = running;
    if (!running) _paused = NO;
    [self _refreshButtons];
}

- (void)_onLuaStateChanged:(NSNotification *)note {
    NSDictionary *ui = note.userInfo;
    BOOL running = [ui[@"running"] boolValue];
    if (!running) {
        _scriptRunning = NO;
        _paused = NO;
    }
    [self _refreshButtons];
}

#pragma mark - 展开 / 收回

- (void)_tapMain:(id)sender {
    if (_expanded) {
        [self _collapseAnimated:YES]; // 展开状态点击本体 = 取消
    } else {
        [self _expandAnimated:YES];
    }
}

- (void)_expandAnimated:(BOOL)animated {
    _expanded = YES;
    UIButton *buttons[] = {_closeBtn, _toggleBtn, _pauseBtn};
    for (int i = 0; i < kExtCount; i++) {
        UIButton *b = buttons[i];
        b.hidden = NO;
        b.userInteractionEnabled = YES;
        CGPoint target = b.frame.origin;
        if (animated) {
            b.frame = CGRectMake(kBallX, 0, kBtnSize, kBtnSize); // 从悬浮球位置出发
            b.alpha = 0;
        }
        [UIView animateWithDuration:animated ? 0.22 : 0.0
                              delay:animated ? (i * 0.04) : 0.0
             usingSpringWithDamping:0.85 initialSpringVelocity:0.6
                            options:UIViewAnimationOptionCurveEaseOut
                                 | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
                             b.frame = CGRectMake(target.x, target.y, kBtnSize, kBtnSize);
                             b.alpha = 1.0;
                         }
                         completion:nil];
    }
}

- (void)_collapseAnimated:(BOOL)animated {
    _expanded = NO;
    UIButton *buttons[] = {_closeBtn, _toggleBtn, _pauseBtn};
    for (int i = 0; i < kExtCount; i++) {
        UIButton *b = buttons[i];
        [UIView animateWithDuration:animated ? 0.18 : 0.0
                              delay:0
                            options:UIViewAnimationOptionCurveEaseIn
                                 | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
                             b.frame = CGRectMake(kBallX, 0, kBtnSize, kBtnSize);
                             b.alpha = 0;
                         }
                         completion:^(BOOL finished) {
                             // 收起完成才禁用交互; 若期间又被展开(动画被打断)则保持显示。
                             // 不再设置 hidden —— 收起状态由 alpha=0 + userInteractionEnabled=NO
                             // 控制, 彻底避免"收起后再点本体无法展开"的 hidden 竞态。
                             if (!_expanded) {
                                 b.userInteractionEnabled = NO;
                                 b.alpha = 0;
                             }
                         }];
    }
}

#pragma mark - 按钮动作

- (void)_tapPause:(id)sender {
    [self _collapseAnimated:YES];
    // 乐观翻转图标: 暂停 ↔ 恢复 (脚本未运行时按钮已禁用, 不会走到这里)
    if (_scriptRunning) {
        _paused = !_paused;
        [self _refreshButtons];
    }
    if (_actionHandler) _actionHandler(TSHUDActionPause);
}

- (void)_tapToggle:(id)sender {
    [self _collapseAnimated:YES];
    if (_actionHandler) _actionHandler(TSHUDActionToggleScript);
}

- (void)_tapClose:(id)sender {
    [self _collapseAnimated:YES];
    if (_actionHandler) _actionHandler(TSHUDActionClose);
}

#pragma mark - 拖拽

- (void)_panMain:(UIPanGestureRecognizer *)g {
    if (_expanded) return; // 展开时禁止拖拽
    CGPoint t = [g translationInView:self];
    CGRect frame = self.frame;
    frame.origin.x += t.x;
    frame.origin.y += t.y;
    // 限制在屏幕内
    CGFloat maxX = [UIScreen mainScreen].bounds.size.width  - frame.size.width;
    CGFloat maxY = [UIScreen mainScreen].bounds.size.height - frame.size.height;
    frame.origin.x = MAX(0, MIN(frame.origin.x, maxX));
    frame.origin.y = MAX(0, MIN(frame.origin.y, maxY));
    self.frame = frame;
    [g setTranslation:CGPointZero inView:self];
}

#pragma mark - 命中测试

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!_expanded) {
        // 未展开: 只响应悬浮球本体, 其余区域穿透
        if (CGRectContainsPoint(_mainBtn.frame, point)) return _mainBtn;
        return nil;
    }
    UIView *hit = [super hitTest:point withEvent:event];
    BOOL onButtons = (hit == _mainBtn || hit == _pauseBtn || hit == _toggleBtn || hit == _closeBtn);
    if (!onButtons) {
        // 展开状态下点击空白区域 = 收回
        if (_expanded) [self _collapseAnimated:YES];
        return nil;
    }
    return hit;
}

#pragma mark - 显隐

- (void)show {
    self.hidden = NO;
    [self _refreshButtons];
    // app 不在前台时同步托管到系统层 (跨应用显示)
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        [self _registerSBSHosting];
    }
}

- (void)hide {
    if (_expanded) [self _collapseAnimated:NO];
    [self _unregisterSBSHosting];
    self.hidden = YES;
}

#pragma mark - 系统级托管 (跨应用显示)

// app 进入后台: 把悬浮球窗口的 layer 通过 SBSAccessibilityWindowHostingController
// 托管到 SpringBoard 的 accessibility 窗口层 (level 10000), 使悬浮球在其它 app /
// 主屏幕之上保持可见。触摸穿透 (kCAContextIgnoresHitTest), 不拦截下层 app 的触摸。
// 机制逆向自 AutoGoRunner/agoverlayd (CAContext remoteContextWithOptions: + setLayer:
// + SBS registerWindowWithContextID:atLevel:), 与 TSHUDHost 的弹窗托管一致,
// 在 iOS 15.8 + TrollStore 环境已验证可用。
- (void)_registerSBSHosting {
    if (_registeredCtxId != 0 || _sbsFailed || self.hidden) return;
    @try {
        unsigned ctxId = [self _acquireSBSContextId];
        if (ctxId == 0) { _sbsFailed = YES; return; }
        Class sbsClass = NSClassFromString(@"SBSAccessibilityWindowHostingController");
        if (!sbsClass) {
            static dispatch_once_t onceToken;
            static void *sbsHandle = NULL;
            dispatch_once(&onceToken, ^{
                sbsHandle = dlopen("/System/Library/PrivateFrameworks/"
                                   "SpringBoardServices.framework/SpringBoardServices",
                                   RTLD_LAZY);
            });
            if (sbsHandle) {
                sbsClass = NSClassFromString(@"SBSAccessibilityWindowHostingController");
            }
        }
        if (!sbsClass) { _sbsFailed = YES; return; }
        if (!_sbsHostingCtrl) _sbsHostingCtrl = [[sbsClass alloc] init];
        SEL regSel = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
        if (![_sbsHostingCtrl respondsToSelector:regSel]) { _sbsFailed = YES; return; }
        void (*regFn)(id, SEL, unsigned, double) =
            (void (*)(id, SEL, unsigned, double))[_sbsHostingCtrl methodForSelector:regSel];
        if (regFn) regFn(_sbsHostingCtrl, regSel, ctxId, 10000.0);
        _registeredCtxId = ctxId;
        // 后台时 CA 提交被节流, 显式 flush 确保悬浮球内容立即同步到远程上下文
        [CATransaction flush];
    } @catch (NSException *e) {
        _sbsFailed = YES;
    }
}

- (void)_unregisterSBSHosting {
    if (_registeredCtxId == 0) return;
    unsigned ctxId = _registeredCtxId;
    _registeredCtxId = 0;
    @try {
        if (_sbsHostingCtrl) {
            SEL unregSel = NSSelectorFromString(@"unregisterWindowWithContextID:");
            if ([_sbsHostingCtrl respondsToSelector:unregSel]) {
                void (*unregFn)(id, SEL, unsigned) =
                    (void (*)(id, SEL, unsigned))[_sbsHostingCtrl methodForSelector:unregSel];
                if (unregFn) unregFn(_sbsHostingCtrl, unregSel, ctxId);
            }
        }
    } @catch (NSException *e) {
    }
}

// 获取用于 SBS 托管的 contextId: 显式创建 CAContext (remoteContextWithOptions:),
// 再把悬浮球窗口 layer 挂进远程上下文。显式创建保证 contextId 非零 (透明窗口
// layer 可能不被分配 CAContext → contextId 为 0 → 托管永远失败, 弹窗已踩过此坑)。
- (unsigned)_acquireSBSContextId {
    if (_sbsCAContext) {
        SEL ctxIdSel = NSSelectorFromString(@"contextId");
        unsigned ctxId = 0;
        if (ctxIdSel && [_sbsCAContext respondsToSelector:ctxIdSel]) {
            unsigned (*ctxIdFn)(id, SEL) = (unsigned (*)(id, SEL))[_sbsCAContext methodForSelector:ctxIdSel];
            if (ctxIdFn) ctxId = ctxIdFn(_sbsCAContext, ctxIdSel);
        }
        if (ctxId != 0) {
            // 窗口 layer 可能重建: 重新 setLayer 挂上
            SEL setLayerSel = NSSelectorFromString(@"setLayer:");
            if (setLayerSel && [_sbsCAContext respondsToSelector:setLayerSel] && self.layer) {
                void (*setLayerFn)(id, SEL, CALayer *) =
                    (void (*)(id, SEL, CALayer *))[_sbsCAContext methodForSelector:setLayerSel];
                if (setLayerFn) setLayerFn(_sbsCAContext, setLayerSel, self.layer);
            }
            return ctxId;
        }
        _sbsCAContext = nil; // context 已失效, 重建
    }

    @try {
        Class caClass = NSClassFromString(@"CAContext");
        if (!caClass) {
            static dispatch_once_t onceToken;
            static void *quartzHandle = NULL;
            dispatch_once(&onceToken, ^{
                quartzHandle = dlopen("/System/Library/Frameworks/"
                                      "QuartzCore.framework/QuartzCore", RTLD_LAZY);
            });
            if (quartzHandle) caClass = NSClassFromString(@"CAContext");
        }
        if (!caClass) return 0;
        SEL remoteSel = NSSelectorFromString(@"remoteContextWithOptions:");
        if (![caClass respondsToSelector:remoteSel]) return 0;
        NSDictionary *opts = @{
            @"kCAContextIgnoresHitTest": @YES,  // 触摸穿透, 不拦截下层 app
            @"kCAContextUseAlpha": @YES,        // 带 alpha 通道的 surface
        };
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id ctx = [caClass performSelector:remoteSel withObject:opts];
#pragma clang diagnostic pop
        if (!ctx) return 0;
        SEL setLayerSel = NSSelectorFromString(@"setLayer:");
        if (setLayerSel && [ctx respondsToSelector:setLayerSel] && self.layer) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [ctx performSelector:setLayerSel withObject:self.layer];
#pragma clang diagnostic pop
        }
        SEL ctxIdSel = NSSelectorFromString(@"contextId");
        unsigned ctxId = 0;
        if (ctxIdSel && [ctx respondsToSelector:ctxIdSel]) {
            unsigned (*ctxIdFn)(id, SEL) = (unsigned (*)(id, SEL))[ctx methodForSelector:ctxIdSel];
            if (ctxIdFn) ctxId = ctxIdFn(ctx, ctxIdSel);
        }
        if (ctxId != 0) {
            _sbsCAContext = ctx;
            [CATransaction flush];
            return ctxId;
        }
    } @catch (NSException *e) {
        _sbsCAContext = nil;
    }
    return 0;
}

- (void)_appDidEnterBackground:(NSNotification *)note {
    if (self.hidden) return;      // 悬浮球已关闭, 无需托管
    [self _registerSBSHosting];   // 跨应用保持显示
}

- (void)_appDidBecomeActive:(NSNotification *)note {
    // app 回到前台: 悬浮球由 app 内 window 正常渲染, 注销系统级托管
    [self _unregisterSBSHosting];
}

@end
