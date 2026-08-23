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

// 主线程强制提交 Core Animation 事务: 非主线程直接返回。
// CA 提交不是线程安全的 —— TSLuaBridge 的脚本状态通知可能来自 Lua 后台线程,
// 悬浮球通过 _onLuaStateChanged: 收到通知后必须先派回主线程再刷新按钮,
// 否则 _refreshButtons 里的 UIKit 操作 + flush 会崩溃 (此前只有 UIKit 非主线程
// 操作属未定义行为未暴露; 新增 flush 后暴露为"运行/停止脚本时程序闪退")。
static void TSFlushCATransaction(void) {
    if (![NSThread isMainThread]) return;
    Class txClass = NSClassFromString(@"CATransaction");
    if (txClass && [txClass respondsToSelector:@selector(flush)]) {
        [txClass flush];
    }
}

// 悬浮球尺寸 (窗口高度 / 布局基准)
static const CGFloat kBallSize    = 44.0;
// 悬浮球本体视觉尺寸 (缩小一点: 在 44 高的窗口内居中显示 38 的球)
static const CGFloat kBallVisSize = 38.0;
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
    // 悬浮球贴边方向: YES=贴右(快捷按钮向左展开), NO=贴左(快捷按钮向右展开)。
    // 拖动松手后按窗口中心到左右边缘的距离自动贴边, 展开方向随之自适应。
    BOOL _dockRight;
    // 跨应用显示 (SBS accessibility window hosting, 逆向自 AutoGoRunner/agoverlayd):
    // app 退到后台时把悬浮球窗口的 CAContext 托管到 SpringBoard 的 accessibility
    // 窗口层, 使悬浮球在其它 app / 主屏幕之上保持可见。触摸穿透 (不拦截下层 app)。
    id _sbsHostingCtrl;      // SBSAccessibilityWindowHostingController
    id _sbsCAContext;        // 显式 CAContext (remoteContextWithOptions:)
    unsigned _registeredCtxId;
    BOOL _sbsFailed;
    // 全局方向监听 (FBSOrientationObserver, 逆向自 AutoGo floatball):
    // SpringBoard 侧的方向服务, 横屏/竖屏切换时即使 app 在后台
    // (SBS 托管悬浮球) 也能收到, 触发重新贴边与展开方向自适应。
    id _fbOrientationObserver;
    NSTimer *_orientationTimer;
    long long _lastOrientation;
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
        _dockRight = YES;

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
        // 屏幕方向变化(横屏/竖屏切换): 重新吸附贴边并限制在屏内,
        // 展开方向随贴边方向自适应 (照抄 AutoGo 的方向监听 + 重布局)。
        // iOS 8+ 此通知仅前台 app 会收到; 后台场景由 FBSOrientationObserver 兜底。
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_orientationDidChange:)
                                                     name:UIApplicationDidChangeStatusBarOrientationNotification
                                                   object:nil];
        // 全局方向监听: 横屏/竖屏切换 (含后台 SBS 托管场景) 都触发重新贴边。
        [self _startGlobalOrientationObserver];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_orientationTimer invalidate];
    _orientationTimer = nil;
    if (_fbOrientationObserver) {
        SEL sel = NSSelectorFromString(@"invalidate");
        if ([_fbOrientationObserver respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [_fbOrientationObserver performSelector:sel];
#pragma clang diagnostic pop
        }
        _fbOrientationObserver = nil;
    }
}

#pragma mark - 构建 UI

- (void)_buildButtons {
    _mainBtn = [self _makeRoundButton:nil action:@selector(_tapMain:)];
    _mainBtn.frame = CGRectMake([self _ballX] + (kBallSize - kBallVisSize) / 2,
                                (kBallSize - kBallVisSize) / 2,
                                kBallVisSize, kBallVisSize);
    // 悬浮球图标: 白色粗体 "T" (按需求替换原闪电 bolt.fill)
    [self _applyTLabelTo:_mainBtn];
    // 悬浮球带拖拽
    _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_panMain:)];
    [_mainBtn addGestureRecognizer:_pan];

    _pauseBtn  = [self _makeRoundButton:nil action:@selector(_tapPause:)];
    _toggleBtn = [self _makeRoundButton:nil action:@selector(_tapToggle:)];
    _closeBtn  = [self _makeRoundButton:nil action:@selector(_tapClose:)];
    // 明显的 X 关闭图标 (之前从未设置图标, 显示为一团深色圆)
    [self _applyIcon:[self _hudIcon:@"xmark"] to:_closeBtn];

    // 扩展按钮初始目标位置: 贴右时向左排, 贴左时向右排
    _pauseBtn.frame  = CGRectMake([self _extXForIndex:2], 0, kBtnSize, kBtnSize);
    _toggleBtn.frame = CGRectMake([self _extXForIndex:1], 0, kBtnSize, kBtnSize);
    _closeBtn.frame  = CGRectMake([self _extXForIndex:0], 0, kBtnSize, kBtnSize);

    // 初始隐藏扩展按钮 (位于悬浮球左侧, 未展开):
    // 用 hidden 隐藏初始状态 (与已验证版本一致)。收起状态由 collapse 动画置
    // alpha=0 (不再设置 hidden) —— 收起/展开的可见性由 alpha+交互开关控制,
    // 避免动画 completion 的 hidden 竞态导致收起后无法再展开。
    _pauseBtn.hidden  = YES;
    _toggleBtn.hidden = YES;
    _closeBtn.hidden  = YES;
    _pauseBtn.alpha  = 0;
    _toggleBtn.alpha = 0;
    _closeBtn.alpha  = 0;

    [_rootVC.view addSubview:_closeBtn];
    [_rootVC.view addSubview:_toggleBtn];
    [_rootVC.view addSubview:_pauseBtn];
    [_rootVC.view addSubview:_mainBtn];
}

- (UIButton *)_makeRoundButton:(UIImage *)image action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(0, 0, kBtnSize, kBtnSize);
    // 圆角矩形样式 (照抄 AutoGo 悬浮球: floaticon 为深灰圆角矩形 + 白色前景)
    b.layer.cornerRadius = 10.0;
    b.layer.masksToBounds = YES;
    b.backgroundColor = [UIColor colorWithWhite:0.20 alpha:0.92]; // #333333
    if (image) [b setImage:image forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// 初始悬浮球位置: 屏幕右侧中部 (默认贴右, 快捷按钮向左展开)
- (void)_layoutBall {
    _dockRight = YES;
    CGRect f = self.frame;
    f.size = CGSizeMake(kExpandedW, kBallSize);
    CGSize screen = [self _effectiveScreenSize];
    f.origin.x = screen.width - kExpandedW - 12;
    f.origin.y = screen.height * 0.5;
    self.frame = f;
    [self _relayoutForDock];
}

// 悬浮球在窗口内的 X: 贴右在窗口右侧, 贴左在窗口左侧
- (CGFloat)_ballX {
    return _dockRight ? kBallX : 0;
}

// 第 idx 个扩展按钮 (0=close 最远, 1=toggle, 2=pause 最近) 在窗口内的目标 X。
// 贴右: 悬浮球在右, 按钮向左依次排开; 贴左: 悬浮球在左, 按钮向右依次排开。
- (CGFloat)_extXForIndex:(NSInteger)idx {
    if (_dockRight) {
        return [self _ballX] - (kBtnSize + kGap) * (kExtCount - idx);
    }
    return kBallSize + kGap + (kBtnSize + kGap) * (kExtCount - 1 - idx);
}

// 按当前贴边方向重排悬浮球与扩展按钮的目标位置 (贴边方向变化后调用,
// 仅重设 frame, 可见性/alpha 仍由展开收起动画管理)
- (void)_relayoutForDock {
    _mainBtn.frame = CGRectMake([self _ballX] + (kBallSize - kBallVisSize) / 2,
                                (kBallSize - kBallVisSize) / 2,
                                kBallVisSize, kBallVisSize);
    _pauseBtn.frame  = CGRectMake([self _extXForIndex:2], 0, kBtnSize, kBtnSize);
    _toggleBtn.frame = CGRectMake([self _extXForIndex:1], 0, kBtnSize, kBtnSize);
    _closeBtn.frame  = CGRectMake([self _extXForIndex:0], 0, kBtnSize, kBtnSize);
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

// 悬浮球图标: 白色粗体 "T" (替换闪电 bolt.fill)。
// 按钮 frame 由 _relayoutForDock 调整, label 用 autoresizing 跟随按钮尺寸。
- (void)_applyTLabelTo:(UIButton *)b {
    UILabel *t = [[UILabel alloc] initWithFrame:b.bounds];
    t.text = @"T";
    t.textColor = [UIColor whiteColor];
    t.font = [UIFont boldSystemFontOfSize:22];
    t.textAlignment = NSTextAlignmentCenter;
    t.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    t.userInteractionEnabled = NO;
    [b addSubview:t];
}

#pragma mark - 状态刷新

- (void)_refreshButtons {
    // 注意: 按钮 alpha 完全由展开/收起动画管理, 这里只更新图标与可用状态。
    // 之前无条件写 _pauseBtn.alpha=1.0, 收起状态收到 Lua 状态通知会把按钮
    // alpha 拉回 1.0, 导致"收起后按钮仍可见/状态错乱"。
    // 悬浮球本体三态颜色 (照抄 AutoGo: floaticon 深灰 #333333 为停止色,
    // 运行 systemGreenColor, 暂停 systemOrangeColor), 图标保持白色。
    if (_scriptRunning && _paused) {
        // 暂停: systemOrangeColor (255,149,0)
        _mainBtn.backgroundColor = [UIColor colorWithRed:1.0 green:149.0/255.0 blue:0.0 alpha:1.0];
    } else if (_scriptRunning) {
        // 运行中: systemGreenColor (52,199,89)
        _mainBtn.backgroundColor = [UIColor colorWithRed:52.0/255.0 green:199.0/255.0 blue:89.0/255.0 alpha:1.0];
    } else {
        // 未运行: 深灰 #333333 (floaticon 同款)
        _mainBtn.backgroundColor = [UIColor colorWithWhite:0.20 alpha:1.0];
    }
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
    // 注意: 这里不做 [CATransaction flush] —— init 阶段(窗口未挂 scene)执行
    // CA 提交有崩溃风险(已见启动闪退), 后台图标同步靠 SBS 托管注册时的 flush
    // 与下一次 UI 交互自然提交, 延迟可接受。
}

// 脚本状态更新可能来自 Lua 后台线程 (TSLuaBridge setIsRunning: 直接 post 通知),
// _refreshButtons 含 UIKit + CATransaction 操作必须主线程, 统一派回主线程。
- (void)setScriptRunning:(BOOL)running {
    if ([NSThread isMainThread]) {
        [self _applyScriptRunning:running];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _applyScriptRunning:running];
        });
    }
}

- (void)_applyScriptRunning:(BOOL)running {
    _scriptRunning = running;
    if (!running) _paused = NO;
    [self _refreshButtons];
}

- (void)_onLuaStateChanged:(NSNotification *)note {
    NSDictionary *ui = note.userInfo;
    BOOL running = [ui[@"running"] boolValue];
    if ([NSThread isMainThread]) {
        [self _applyLuaStateChange:running];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _applyLuaStateChange:running];
        });
    }
}

- (void)_applyLuaStateChange:(BOOL)running {
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
        // 目标位置用固定坐标 (按贴边方向计算), 不能取 b.frame.origin:
        // 收起后按钮 frame 停在悬浮球位置, 取当前 frame 会导致再次展开时
        // "从原位动画到原位" → 侧边列表再也出不来 (只能点开一次的 bug)。
        CGPoint target = CGPointMake([self _extXForIndex:i], 0);
        if (animated) {
            b.frame = CGRectMake([self _ballX], 0, kBtnSize, kBtnSize); // 从悬浮球位置出发
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
                             b.frame = CGRectMake([self _ballX], 0, kBtnSize, kBtnSize);
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
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
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
    } else if (g.state == UIGestureRecognizerStateEnded
               || g.state == UIGestureRecognizerStateCancelled
               || g.state == UIGestureRecognizerStateFailed) {
        // 松手自动贴边: 离哪边近贴哪边, 展开方向随贴边方向自适应
        [self _snapToEdgeAnimated:YES];
    }
}

// 吸附到最近的屏幕边缘 (左右), 并同步悬浮球位置与展开方向
- (void)_snapToEdgeAnimated:(BOOL)animated {
    CGRect frame = self.frame;
    CGSize screen = [self _effectiveScreenSize];
    CGFloat midX = frame.origin.x + frame.size.width * 0.5;
    BOOL right = (midX >= screen.width * 0.5);
    if (right != _dockRight) {
        // 贴边方向改变: 重排悬浮球与快捷按钮 (悬浮球移到窗口对侧, 展开方向反转)
        _dockRight = right;
        [self _relayoutForDock];
    }
    const CGFloat margin = 12.0;
    frame.origin.x = right ? (screen.width - frame.size.width - margin) : margin;
    // y 限制在屏内 (横屏切换后屏幕高度变小, 防止悬浮球出屏)
    CGFloat maxY = MAX(0, screen.height - frame.size.height);
    frame.origin.y = MAX(0, MIN(frame.origin.y, maxY));
    if (animated) {
        [UIView animateWithDuration:0.25
                              delay:0
             usingSpringWithDamping:0.85 initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
                             self.frame = frame;
                         }
                         completion:nil];
    } else {
        self.frame = frame;
    }
}

// 屏幕方向变化 (横/竖屏切换): 屏幕尺寸改变, 按当前位置重新吸附到最近的
// 左右边缘 (离哪边近贴哪边), 展开方向随之自适应。照抄 AutoGo floatball 的
// updateFloatingBallForScene:interfaceOrientation: 思路。
- (void)_orientationDidChange:(NSNotification *)note {
    if (self.hidden) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _snapToEdgeAnimated:YES];
        });
        return;
    }
    [self _snapToEdgeAnimated:YES];
}

// 启动 SpringBoard 侧全局方向监听 (FBSOrientationObserver, 私有框架)。
// app 后台 SBS 托管悬浮球时收不到 UIApplication 方向通知, 必须用这个。
// 框架不保证一直存在, 动态 dlopen + 轮询 activeInterfaceOrientation。
- (void)_startGlobalOrientationObserver {
    if (_fbOrientationObserver) return;
    Class cls = NSClassFromString(@"FBSOrientationObserver");
    if (!cls) {
        void *h = dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
        if (h) cls = NSClassFromString(@"FBSOrientationObserver");
    }
    if (!cls) return;
    _fbOrientationObserver = [[cls alloc] init];
    if (!_fbOrientationObserver) return;
    _lastOrientation = [self _currentGlobalOrientation];
    _orientationTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                         target:self
                                                       selector:@selector(_pollGlobalOrientation:)
                                                       userInfo:nil
                                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_orientationTimer forMode:NSRunLoopCommonModes];
}

// 读取 FBSOrientationObserver 当前界面方向 (NSInvocation 精确取 long long 返回值,
// 避免 performSelector 的 id 截断)
- (long long)_currentGlobalOrientation {
    if (!_fbOrientationObserver) return _lastOrientation;
    SEL sel = NSSelectorFromString(@"activeInterfaceOrientation");
    if (![_fbOrientationObserver respondsToSelector:sel]) return _lastOrientation;
    NSMethodSignature *sig = [_fbOrientationObserver methodSignatureForSelector:sel];
    if (!sig) return _lastOrientation;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = _fbOrientationObserver;
    inv.selector = sel;
    [inv invoke];
    long long v = 0;
    [inv getReturnValue:&v];
    return v;
}

// 有效屏幕尺寸: 处理"app 只支持竖屏但设备已横屏"的情况。
// 此时 app 的 UIScreen.bounds 仍返回竖屏尺寸 (宽<高, app 未随设备旋转),
// 而悬浮球经 SBS 托管显示在横屏屏幕上 —— 若按竖屏尺寸贴边, 会把悬浮球
// 贴到"竖屏坐标的左右" = 横屏屏幕的上下边缘, 展开方向随之错乱。
// 按 FBSOrientationObserver 的界面方向判断, 横屏时交换宽高,
// 使贴边沿横屏的长边 (左右), 展开列表朝屏幕内侧排开。
// app 自身支持横屏时 bounds 已是横屏尺寸 (宽>高), 不交换, 行为不变。
- (CGSize)_effectiveScreenSize {
    CGSize s = [UIScreen mainScreen].bounds.size;
    long long o = [self _currentGlobalOrientation];
    BOOL landscape = (o == 3 || o == 4); // LandscapeLeft / LandscapeRight
    if (landscape && s.height > s.width) {
        s = CGSizeMake(s.height, s.width);
    }
    return s;
}

// 轮询方向: 变化时重新吸附贴边 (横屏 ↔ 竖屏切换)。
// 用非动画即时贴边: 后台 SBS 托管时 UIView 动画不渲染, 直接设 frame
// 才能立即在屏幕上生效。
- (void)_pollGlobalOrientation:(NSTimer *)timer {
    long long o = [self _currentGlobalOrientation];
    if (o == _lastOrientation) return;
    _lastOrientation = o;
    if (!self.hidden) [self _snapToEdgeAnimated:NO];
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
    // CAContext/SBS 私有 API 操作必须主线程 (防御性保护, 正常只从主线程路径调用)
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _registerSBSHosting];
        });
        return;
    }
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
        TSFlushCATransaction();
    } @catch (NSException *e) {
        _sbsFailed = YES;
    }
}

- (void)_unregisterSBSHosting {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _unregisterSBSHosting];
        });
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
            TSFlushCATransaction();
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
