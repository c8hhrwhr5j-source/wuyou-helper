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
// 悬浮球本体视觉尺寸 (28×28: 在 44 高的窗口内居中显示)
static const CGFloat kBallVisSize = 28.0;
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

// 悬浮球窗口的 rootVC: 固定竖屏, 禁止自动旋转。
// 否则 app 支持横屏时悬浮球 window 会随设备旋转 (bounds 交换), 与自绘的
// _landscape 竖直条布局冲突; 固定竖屏后窗口坐标系始终是竖屏基准,
// 横屏时统一走"窗口改 44×200 竖直条 + 内容旋转"的自绘方案。
@interface TSHUDPortraitVC : UIViewController
@end

@implementation TSHUDPortraitVC
- (BOOL)shouldAutorotate {
    return NO;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
}
@end

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
    // 当前界面是否为横屏 (SpringBoard 会把悬浮球窗口旋转 90° 显示)。
    // 横屏时窗口自身改为竖直条 (44×200, 按钮沿 y 轴排布、内容旋转 ±90°),
    // 旋转显示后屏幕上正好是水平 200×44、内容正立、贴边方向正确。
    BOOL _landscape;
    // 当前界面方向 (3=LandscapeLeft, 4=LandscapeRight), 用于区分旋转方向。
    long long _curOrientation;
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

        _rootVC = [[TSHUDPortraitVC alloc] init];
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
    // 悬浮球图标: QQ 音乐图标 (替换原白色 "T")
    [self _applyQQMusicIconTo:_mainBtn];
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

// 横屏: 悬浮球在窗口内的 Y (窗口为竖直条 44×200, 按钮沿 y 轴排布)。
// 贴右(屏幕右侧) → 悬浮球在窗口 y 大端, 旋转显示后位于屏幕右侧。
- (CGFloat)_ballY {
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

// 悬浮球本体原点 (窗口坐标)。横屏时窗口为竖直条, 坐标轴互换 (y 轴)。
- (CGPoint)_ballOrigin {
    if (_landscape) return CGPointMake(0, [self _ballY]);
    return CGPointMake([self _ballX], 0);
}

// 第 idx 个扩展按钮的目标原点 (窗口坐标)。横屏时沿 y 轴展开。
- (CGPoint)_extOriginForIndex:(NSInteger)idx {
    if (_landscape) return CGPointMake(0, [self _extXForIndex:idx]);
    return CGPointMake([self _extXForIndex:idx], 0);
}

// 按当前贴边方向重排悬浮球与扩展按钮的目标位置 (贴边方向变化后调用,
// 仅重设 frame, 可见性/alpha 仍由展开收起动画管理)。
// 横屏时窗口为竖直条 44×200, 按钮沿 y 轴排布 (x 轴同竖屏公式, 轴互换)。
- (void)_relayoutForDock {
    // 收起状态(setBallPoint 把窗口收缩为球本体 44×44): 球居中。
    // 依据窗口尺寸判断, 避免 200 宽展开窗口/方向布局走错分支。
    if (!_expanded && self.frame.size.width <= kBallSize + 0.5
                  && self.frame.size.height <= kBallSize + 0.5) {
        _mainBtn.frame = CGRectMake((kBallSize - kBallVisSize) / 2.0,
                                    (kBallSize - kBallVisSize) / 2.0,
                                    kBallVisSize, kBallVisSize);
        return;
    }
    if (_landscape) {
        CGFloat inset = (kBallSize - kBallVisSize) / 2;
        _mainBtn.frame = CGRectMake(inset, [self _ballY] + inset,
                                    kBallVisSize, kBallVisSize);
        _pauseBtn.frame  = CGRectMake(0, [self _extXForIndex:2], kBtnSize, kBtnSize);
        _toggleBtn.frame = CGRectMake(0, [self _extXForIndex:1], kBtnSize, kBtnSize);
        _closeBtn.frame  = CGRectMake(0, [self _extXForIndex:0], kBtnSize, kBtnSize);
        return;
    }
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

// 悬浮球图标: QQ 音乐图标 (替换白色粗体 "T")。
// 加载优先级:
//   1) [UIImage imageNamed:@"QQMusicIcon"] — 从 Assets.car 读取 (QQMusicIcon.imageset)
//   2) [[NSBundle mainBundle] pathForResource:@"QQMusicIcon" ofType:@"png"]
//      — 从 .app 根目录直接读取 (build-ipa.sh / CI 会放入 QQMusicIcon.png + @2x/@3x)
//   3) 兜底: 用绘图生成一个 "♪" 占位 (黄底绿色)
- (void)_applyQQMusicIconTo:(UIButton *)b {
    UIImage *icon = nil;

    // 1) Assets.car (QQMusicIcon.imageset)
    icon = [UIImage imageNamed:@"QQMusicIcon"];

    // 2) Fallback: .app 根目录的 PNG (支持 @2x/@3x scale 识别)
    if (!icon) {
        NSArray<NSString *> *cands = @[
            // 优先按屏幕 scale 精确匹配
            [NSString stringWithFormat:@"QQMusicIcon@%@x", @((int)[UIScreen mainScreen].scale)],
            @"QQMusicIcon@3x",
            @"QQMusicIcon@2x",
            @"QQMusicIcon"
        ];
        NSBundle *mb = [NSBundle mainBundle];
        for (NSString *cand in cands) {
            NSString *p = [mb pathForResource:cand ofType:@"png"];
            if (p) {
                icon = [UIImage imageWithContentsOfFile:p];
                if (icon) break;
            }
        }
    }

    // 3) Fallback: 找不到就用代码画一个 QQ 音乐风格占位 (黄底 + ♪)
    if (!icon) {
        CGSize sz = CGSizeMake(80, 80);
        UIGraphicsBeginImageContextWithOptions(sz, YES, 0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        // 黄底 (QQ 音乐黄)
        UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, sz.width, sz.height)
                                                      cornerRadius:sz.width * 0.22];
        [[UIColor colorWithRed:1.0 green:0.82 blue:0.0 alpha:1.0] setFill];
        [bg fill];
        // 绿色音符
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:50],
            NSForegroundColorAttributeName: [UIColor colorWithRed:0.07 green:0.5 blue:0.17 alpha:1.0]
        };
        NSString *glyph = @"♪";
        CGSize gsz = [glyph sizeWithAttributes:attrs];
        [glyph drawAtPoint:CGPointMake((sz.width - gsz.width) / 2, (sz.height - gsz.height) / 2 - 2)
            withAttributes:attrs];
        icon = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        (void)ctx;
    }

    if (icon) {
        // 强制原图渲染，避免 UIButtonTypeSystem 把图标模板化成蓝色
        icon = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        [b setImage:icon forState:UIControlStateNormal];
        b.tintColor = nil;
        b.imageView.contentMode = UIViewContentModeScaleAspectFit;
        b.imageView.clipsToBounds = YES;
    }
}

#pragma mark - 状态刷新

- (void)_refreshButtons {
    // 注意: 按钮 alpha 完全由展开/收起动画管理, 这里只更新图标与可用状态。
    // 主按钮使用 QQ 音乐图标 (黄底绿色音符), 背景改为白色让图标更清晰。
    // 状态通过边框颜色表示: 灰色=未运行, 绿色=运行中, 橙色=暂停
    _mainBtn.backgroundColor = [UIColor whiteColor];
    if (_scriptRunning && _paused) {
        // 暂停: systemOrangeColor (255,149,0)
        _mainBtn.layer.borderWidth = 2.0;
        _mainBtn.layer.borderColor = [UIColor colorWithRed:1.0 green:149.0/255.0 blue:0.0 alpha:1.0].CGColor;
    } else if (_scriptRunning) {
        // 运行中: systemGreenColor (52,199,89)
        _mainBtn.layer.borderWidth = 2.0;
        _mainBtn.layer.borderColor = [UIColor colorWithRed:52.0/255.0 green:199.0/255.0 blue:89.0/255.0 alpha:1.0].CGColor;
    } else {
        // 未运行: 灰色边框
        _mainBtn.layer.borderWidth = 1.5;
        _mainBtn.layer.borderColor = [UIColor colorWithWhite:0.6 alpha:1.0].CGColor;
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
    // setBallPoint 在收起状态把窗口收缩为球本体 44×44; 展开前恢复展开尺寸并
    // 重排, 否则按钮会排布到窗口外(球在 44 窗格内, 按钮需要展开面板宽度)
    CGSize want = _landscape ? CGSizeMake(kBallSize, kExpandedW) : CGSizeMake(kExpandedW, kBallSize);
    if (!CGSizeEqualToSize(self.frame.size, want)) {
        CGRect f = self.frame;
        f.size = want;
        // 展开后窗口尺寸变大, 必须重新 clamp 位置 (竖屏基准坐标)。
        // 收起贴边时窗口 44×44 (横屏贴右 y=623 / 竖屏贴右 x=331), 展开后若位置
        // 不变, 窗口会超出屏幕 (横屏 623+200=823 > 667), 按钮全排到屏幕外只露叉号。
        CGSize base = [self _portraitScreenSize];
        f.origin.x = MAX(0, MIN(f.origin.x, base.width  - want.width));
        f.origin.y = MAX(0, MIN(f.origin.y, base.height - want.height));
        self.frame = f;
        [self _relayoutForDock];
        TSFlushCATransaction();
    }
    UIButton *buttons[] = {_closeBtn, _toggleBtn, _pauseBtn};
    for (int i = 0; i < kExtCount; i++) {
        UIButton *b = buttons[i];
        b.hidden = NO;
        b.userInteractionEnabled = YES;
        // 目标位置用固定坐标 (按贴边方向计算), 不能取 b.frame.origin:
        // 收起后按钮 frame 停在悬浮球位置, 取当前 frame 会导致再次展开时
        // "从原位动画到原位" → 侧边列表再也出不来 (只能点开一次的 bug)。
        CGPoint target = [self _extOriginForIndex:i];
        if (animated) {
            CGPoint org = [self _ballOrigin];
            b.frame = CGRectMake(org.x, org.y, kBtnSize, kBtnSize); // 从悬浮球位置出发
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
                             CGPoint org = [self _ballOrigin];
                             b.frame = CGRectMake(org.x, org.y, kBtnSize, kBtnSize);
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
        // 窗口坐标始终基于竖屏基准 (rootVC 固定竖屏, 窗口不随 app/设备旋转):
        // 窗口 x 方向 → 屏幕竖直(375), 窗口 y 方向 → 屏幕水平(667)。
        // 横屏时窗口被系统旋转 90° 显示, 但 frame 仍在竖屏基准坐标,
        // 所以边界统一 = 竖屏基准尺寸 - 窗口尺寸, 横竖屏同一公式。
        // 注意: 不能用 _effectiveScreenSize —— app 已横屏时它返回 667×375,
        // 与窗口竖屏基准坐标不符, 会把窗口 y (屏幕水平) 错限到 331 (只能拖到横屏左边)。
        CGSize base = [self _portraitScreenSize];
        frame.origin.x = MAX(0, MIN(frame.origin.x, base.width  - frame.size.width));
        frame.origin.y = MAX(0, MIN(frame.origin.y, base.height - frame.size.height));
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
    // 窗口坐标始终基于竖屏基准: base.width(375)=屏幕竖直基准, base.height(667)=屏幕水平基准。
    // 竖屏时窗口不旋转, 贴边沿窗口 x; 横屏时窗口旋转 90° 显示, 贴边沿窗口 y。
    CGSize base = [self _portraitScreenSize];
    BOOL right;
    if (_landscape) {
        // 横屏: 屏幕水平由窗口 y 控制 (范围 base.height=667), 屏幕竖直由窗口 x 控制 (base.width=375)。
        // LandscapeLeft(3): 屏幕 px = wy,  贴右 wy=大, 贴左 wy=小;
        // LandscapeRight(4): 屏幕 px = 667-wy, 贴右 wy=小, 贴左 wy=大。
        CGFloat maxWY = base.height - frame.size.height; // 667-44=623 (收起) / 667-200=467 (展开)
        BOOL ll = (_curOrientation == 3);
        CGFloat centerPx;
        if (ll) centerPx = frame.origin.y + frame.size.height * 0.5;           // px = wy
        else    centerPx = (maxWY - frame.origin.y) + frame.size.height * 0.5; // px = 623-wy
        right = (centerPx >= base.height * 0.5); // 屏幕水平中线 333.5
        if (right != _dockRight) {
            _dockRight = right;
            [self _relayoutForDock];
        }
        const CGFloat margin = 0.0;
        frame.origin.y = (right == ll) ? (maxWY - margin) : margin;
        // 屏幕竖直: 限制在屏内
        CGFloat maxWX = MAX(0, base.width - frame.size.width); // 375-44=331
        frame.origin.x = MAX(margin, MIN(maxWX, frame.origin.x));
    } else {
        CGFloat midX = frame.origin.x + frame.size.width * 0.5;
        right = (midX >= base.width * 0.5);
        if (right != _dockRight) {
            // 贴边方向改变: 重排悬浮球与快捷按钮 (悬浮球移到窗口对侧, 展开方向反转)
            _dockRight = right;
            [self _relayoutForDock];
        }
        const CGFloat margin = 0.0;
        frame.origin.x = right ? (base.width - frame.size.width - margin) : margin;
        // y 限制在屏内 (横屏切换后屏幕高度变小, 防止悬浮球出屏)
        CGFloat maxY = MAX(0, base.height - frame.size.height);
        frame.origin.y = MAX(0, MIN(frame.origin.y, maxY));
    }
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

// 方向切换处理: 更新横屏标记、窗口尺寸 (横屏 44×200 竖直条 ↔ 竖屏 200×44),
// 换算窗口位置到新坐标系 (保持屏幕位置), 按钮内容旋转 (横屏时图标/T 字在
// 屏幕上正立)。无方向变化则直接返回。
- (void)_applyOrientationLayout {
    long long o = [self _currentGlobalOrientation];
    BOOL landscape = (o == 3 || o == 4);
    // _curOrientation==0 表示方向布局尚未初始化: 若横竖屏类型一致则无需任何
    // 换算 (避免竖屏初始化时对竖屏 frame 做"竖屏→竖屏"的误换算)。
    if (landscape == _landscape && (o == _curOrientation || _curOrientation == 0)) return;

    // 换算窗口位置: 竖屏 1:1; 横屏时窗口 x(宽44)→屏幕竖直, y(高200)→屏幕水平。
    // LandscapeLeft(3):  屏幕 px=wy,   py=331-wx
    // LandscapeRight(4): 屏幕 px=467-wy, py=wx
    CGRect f = self.frame;
    [self _convertFrame:&f toLandscape:landscape orientation:o];
    // 窗口尺寸跟随展开状态: 收起为球本体 44×44, 展开为面板宽度
    f.size = !_expanded ? CGSizeMake(kBallSize, kBallSize)
             : landscape ? CGSizeMake(kBallSize, kExpandedW) : CGSizeMake(kExpandedW, kBallSize);
    // 窗口坐标始终基于竖屏基准, 横竖屏同一公式 (横屏时窗口被系统旋转 90° 显示,
    // 但 frame 坐标轴不变: x→屏幕竖直 base.width, y→屏幕水平 base.height)。
    CGSize base = [self _portraitScreenSize];
    f.origin.x = MAX(0, MIN(f.origin.x, base.width  - f.size.width));
    f.origin.y = MAX(0, MIN(f.origin.y, base.height - f.size.height));
    self.frame = f;

    _landscape = landscape;
    _curOrientation = o;
    [self _relayoutForDock];
    [self _applyButtonOrientation];
}

// 竖屏基准屏幕尺寸 (375×667): 悬浮球窗口坐标始终基于竖屏基准,
// 不随 app 界面方向变化 (前台横屏时 UIScreen.bounds 已变 667×375)。
- (CGSize)_portraitScreenSize {
    CGSize s = [UIScreen mainScreen].bounds.size;
    if (s.width > s.height) s = CGSizeMake(s.height, s.width);
    return s;
}

// 把当前窗口位置换算到目标方向坐标系 (保持屏幕显示位置不变)。
// 竖屏位置 (x,y) 即屏幕位置; 横屏换算规则:
//   LandscapeLeft(3):  屏幕 px = wy,   py = 331-wx  → 横屏(wx,wy) = (331-y, x)
//   LandscapeRight(4): 屏幕 px = 467-wy, py = wx    → 横屏(wx,wy) = (y, 467-x)
// 反向同理。
- (void)_convertFrame:(CGRect *)fp toLandscape:(BOOL)landscape orientation:(long long)o {
    CGSize base = [self _portraitScreenSize];           // 竖屏基准 375×667
    // 横屏窗口: 宽 kBallSize(44) → 屏幕竖直(base.width=375), 高 kExpandedW(200) → 屏幕水平(base.height=667)
    CGFloat maxWX = base.width  - kBallSize;            // 375-44=331 (横屏窗口宽 → 屏幕竖直范围)
    CGFloat maxWY = base.height - kExpandedW;           // 667-200=467 (横屏窗口高 → 屏幕水平范围)
    CGRect f = *fp;
    if (landscape) {
        // 竖屏(x,y) → 横屏(wx,wy)
        CGFloat x = f.origin.x, y = f.origin.y;
        f.origin.x = (o == 3) ? (maxWX - y) : y;      // wx
        f.origin.y = (o == 3) ? x : (maxWY - x);      // wy
    } else {
        // 横屏(wx,wy) → 竖屏(x,y)
        CGFloat wx = f.origin.x, wy = f.origin.y;
        f.origin.x = (o == 3) ? wy : (maxWY - wy);    // x
        f.origin.y = (o == 3) ? (maxWX - wx) : wx;    // y
    }
    *fp = f;
}

// 横屏时按钮内容旋转 ±90°, 使图标/T 字在屏幕上正立 (旋转绕按钮中心)。
- (void)_applyButtonOrientation {
    CGAffineTransform t = CGAffineTransformIdentity;
    if (_landscape) {
        if (_curOrientation == 3) t = CGAffineTransformMakeRotation(M_PI / 2);   // LandscapeLeft
        else                      t = CGAffineTransformMakeRotation(-M_PI / 2);  // LandscapeRight
    }
    _mainBtn.transform = t;
    _pauseBtn.transform = t;
    _toggleBtn.transform = t;
    _closeBtn.transform = t;
}

// 屏幕方向变化 (横/竖屏切换): 屏幕尺寸改变, 按当前位置重新吸附到最近的
// 左右边缘 (离哪边近贴哪边), 展开方向随之自适应。照抄 AutoGo floatball 的
// updateFloatingBallForScene:interfaceOrientation: 思路。
- (void)_orientationDidChange:(NSNotification *)note {
    if (self.hidden) return;
    void (^update)(void) = ^{
        [self _applyOrientationLayout];
        [self _snapToEdgeAnimated:YES];
    };
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), update);
        return;
    }
    update();
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
    // app 冷启动时设备可能已横屏: 此刻 _lastOrientation 已等于当前横屏方向,
    // 之后轮询检测不到"方向变化"→ _landscape 将一直保持 NO。
    // 因此就绪后立即同步一次方向布局。竖屏时 guard (landscape 一致且
    // _curOrientation 未初始化) 直接返回, 不做换算, 与现有竖屏行为一致。
    [self _applyOrientationLayout];
    if (_landscape) {
        // 初始窗口位置是 _layoutBall 按竖屏屏幕尺寸算的, 方向初始化后
        // 位置未贴边, 立即按当前方向吸附一次。
        [self _snapToEdgeAnimated:NO];
    }
    _orientationTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                         target:self
                                                       selector:@selector(_pollGlobalOrientation:)
                                                       userInfo:nil
                                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_orientationTimer forMode:NSRunLoopCommonModes];
}

// 读取对象 selector 的 long long 返回值 (NSInvocation 精确取, 避免
// performSelector 把 long long 当 id 截断)
- (long long)_longLongFrom:(id)target selector:(SEL)sel {
    if (!target || !sel || ![target respondsToSelector:sel]) return 0;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return 0;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target;
    inv.selector = sel;
    [inv invoke];
    long long v = 0;
    [inv getReturnValue:&v];
    return v;
}

// 从 FrontBoard 显示布局读取系统当前界面方向 (UIInterfaceOrientation 码:
// 1=Portrait 2=PortraitUpsideDown 3=LandscapeLeft 4=LandscapeRight)。
// FBSDisplayLayoutMonitor 连接系统显示服务, 即使本 app 退到后台也能拿到主屏
// 当前布局 → 前台 app (游戏) 的界面方向。这是悬浮球 SBS 托管时唯一可靠的方向
// 来源: FBSOrientationObserver / UIDevice / statusBarOrientation 在后台都会
// 冻结为本 app 最后的界面方向 (竖屏 1), 设备转横屏时永远读不到 3/4。
- (long long)_systemInterfaceOrientation {
    Class cls = NSClassFromString(@"FBSDisplayLayoutMonitor");
    if (!cls) {
        void *h = dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
        if (h) cls = NSClassFromString(@"FBSDisplayLayoutMonitor");
    }
    if (!cls) return 0;
    SEL mainSel = NSSelectorFromString(@"mainDisplayInstance");
    if (![cls respondsToSelector:mainSel]) return 0;
    id monitor = [cls performSelector:mainSel];
    if (!monitor) return 0;
    SEL curSel = NSSelectorFromString(@"currentLayout");
    if (![monitor respondsToSelector:curSel]) return 0;
    id layout = [monitor performSelector:curSel];
    if (!layout) return 0;
    // 遍历布局元素, 取 UIApplication 元素 (前台 app) 的界面方向
    NSArray *elements = [layout valueForKey:@"elements"];
    if ([elements isKindOfClass:[NSArray class]]) {
        for (id el in elements) {
            id isApp = [el valueForKey:@"isUIApplicationElement"];
            if (![isApp boolValue]) continue;
            long long o = [self _longLongFrom:el selector:NSSelectorFromString(@"interfaceOrientation")];
            if (o >= 1 && o <= 4) return o;
        }
    }
    // 兜底: 布局级界面方向 (主屏当前方向)
    long long lo = [self _longLongFrom:layout selector:NSSelectorFromString(@"interfaceOrientation")];
    if (lo >= 1 && lo <= 4) return lo;
    return 0;
}

// 当前界面方向 (多源检测, 返回 UIInterfaceOrientation 码)。
// 来源优先级:
//   1) FBSDisplayLayoutMonitor 系统显示布局 —— app 后台 SBS 托管悬浮球时的
//      唯一可靠来源 (返回前台 app/游戏的当前方向, 横屏游戏即 3/4)。
//   2) FBSOrientationObserver —— 兜底。
//   3) _lastOrientation —— 上次有效方向兜底。
- (long long)_currentGlobalOrientation {
    long long sysO = [self _systemInterfaceOrientation];
    if (sysO >= 1 && sysO <= 4) return sysO;
    long long o = [self _longLongFrom:_fbOrientationObserver selector:NSSelectorFromString(@"activeInterfaceOrientation")];
    if (o >= 1 && o <= 4) return o;
    return _lastOrientation;
}

// 设备当前实际方向 -> 脚本方向码 (0=home在下 1=home在右 2=home在左)。
// 与 setBallPoint 的坐标系一致: setFloatBallPoint 需要它做转换目标方向。
- (NSInteger)currentScriptOrientation {
    long long o = [self _currentGlobalOrientation];
    // UIInterfaceOrientation: 1=Portrait 2=PortraitUpsideDown 3=LandscapeLeft(home右) 4=LandscapeRight(home左)
    switch (o) {
        case 3: return 1;   // home 在右
        case 4: return 2;   // home 在左
        default: return 0;  // 竖屏/未知
    }
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
    if (self.hidden) return;
    // 先切换窗口尺寸/按钮旋转 (方向布局), 再按新坐标系贴边。
    [self _applyOrientationLayout];
    [self _snapToEdgeAnimated:NO];
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

#pragma mark - 外部位置设置

// 把悬浮球本体中心移动到指定屏幕坐标 (物理屏幕坐标)。
// 直接修改窗口 frame, 不触发贴边动画 —— 用户主动指定位置时应保持该位置。
// 横屏时窗口为 44×200 竖直条, 屏幕坐标轴与窗口坐标轴互换, 需对应换算。
- (void)setBallPoint:(CGPoint)point {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setBallPoint:point];
        });
        return;
    }
    [self applyBallFrame:point collapsed:!_expanded portraitOnly:NO];
}

// 脚本 setFloatBallPoint 移动专用: 严格按竖屏窗口坐标系放置 (0 旋转)。
// 坐标 x/y 永远按竖屏坐标系解释, 不做脚本方向/设备方向旋转换算,
// 横屏时位置随窗口显示旋转。显示布局与 setBallPoint 完全一致。
- (void)setBallPointPortrait:(CGPoint)point {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setBallPointPortrait:point];
        });
        return;
    }
    [self applyBallFrame:point collapsed:!_expanded portraitOnly:YES];
}

// 统一的球体布局: portraitOnly=YES 表示 point 已是竖屏窗口坐标(竖屏分支放置),
// 否则按 setBallPoint 原有语义(横屏时 point 为设备显示坐标, 需旋转换算)。
- (void)applyBallFrame:(CGPoint)point collapsed:(BOOL)collapsed portraitOnly:(BOOL)portraitOnly {
    CGRect frame = self.frame;
    CGSize screen = [self _effectiveScreenSize];
    // 竖屏基准 375×667: portrait 模式(含横屏设备) clamp 恒用它,
    // 不能用 _effectiveScreenSize(横屏时交换为 667×375, 会把竖屏 y 压错)。
    CGSize base = [self _portraitScreenSize];

    if (_landscape && !portraitOnly) {
        // 横屏: 窗口坐标系为竖屏基准(窗口 x 范围 screen.height, y 范围 screen.width),
        // point 为设备显示坐标(px 沿屏幕水平, py 沿屏幕竖直)。显示坐标 -> 竖屏窗口坐标:
        //   LandscapeLeft(home右,3): px=wy, py=screen.height-wx -> wx=screen.height-py, wy=px
        //   LandscapeRight(home左,4): px=screen.width-wy, py=wx  -> wx=py, wy=screen.width-px
        // 与 _snapToEdgeAnimated 的方向判断一致; 缺失时 home右 设备 y 被镜像,
        // 目标右下角坐标会落到右上角。
        BOOL ll = ([self _currentGlobalOrientation] == 3);
        if (collapsed) {
            // 收起: 窗口收缩为球本体 44×44, 球居中, point 即球心, 可贴任意边缘
            frame.size = CGSizeMake(kBallSize, kBallSize);
            _mainBtn.frame = CGRectMake((kBallSize - kBallVisSize) / 2.0,
                                        (kBallSize - kBallVisSize) / 2.0,
                                        kBallVisSize, kBallVisSize);
            CGFloat half = kBallSize / 2.0;
            if (ll) {
                frame.origin.x = (screen.height - point.y) - half;
                frame.origin.y = point.x - half;
            } else {
                frame.origin.x = point.y - half;
                frame.origin.y = (screen.width - point.x) - half;
            }
            CGFloat maxX = MAX(0, screen.height - frame.size.width);   // 屏幕竖直
            CGFloat maxY = MAX(0, screen.width  - frame.size.height);  // 屏幕水平
            frame.origin.x = MAX(0, MIN(frame.origin.x, maxX));
            frame.origin.y = MAX(0, MIN(frame.origin.y, maxY));
        } else {
            // 展开: 窗口 44×200 竖直条, 球心在窗口内 (kBallSize/2, _ballY + kBallSize/2)
            frame.size = CGSizeMake(kBallSize, kExpandedW);
            CGFloat cx = kBallSize / 2.0;
            CGFloat cy = [self _ballY] + kBallSize / 2.0;
            if (ll) {
                frame.origin.x = (screen.height - point.y) - cx;
                frame.origin.y = point.x - cy;
            } else {
                frame.origin.x = point.y - cx;
                frame.origin.y = (screen.width - point.x) - cy;
            }
            CGFloat maxX = MAX(0, screen.height - frame.size.width);   // 屏幕竖直
            CGFloat maxY = MAX(0, screen.width  - frame.size.height);  // 屏幕水平
            frame.origin.x = MAX(0, MIN(frame.origin.x, maxX));
            frame.origin.y = MAX(0, MIN(frame.origin.y, maxY));
        }
    } else {
        // portrait 模式(或竖屏设备): point 恒为竖屏基准逻辑点(球心)。
        // 全部按竖屏坐标直接放置 —— 不做任何方向/旋转换算:
        //   frame.origin = point - 球心窗口内偏移, clamp 用竖屏基准尺寸。
        // 横屏设备上窗口 frame 坐标系本就是竖屏基准(375×667), 由系统旋转显示,
        // 所以"直接按竖屏坐标放"即"位置随屏幕旋转", 无需也不应该判断 LL/LR。
        if (collapsed) {
            // 收起: 窗口收缩为球本体 44×44, 球居中, point 即球心, 可贴任意边缘
            frame.size = CGSizeMake(kBallSize, kBallSize);
            _mainBtn.frame = CGRectMake((kBallSize - kBallVisSize) / 2.0,
                                        (kBallSize - kBallVisSize) / 2.0,
                                        kBallVisSize, kBallVisSize);
            frame.origin.x = point.x - kBallSize / 2.0;
            frame.origin.y = point.y - kBallSize / 2.0;
            CGFloat maxX = MAX(0, base.width  - frame.size.width);
            CGFloat maxY = MAX(0, base.height - frame.size.height);
            frame.origin.x = MAX(0, MIN(frame.origin.x, maxX));
            frame.origin.y = MAX(0, MIN(frame.origin.y, maxY));
        } else {
            // 展开: 窗口 200×44, 球心在窗口内 (_ballX + kBallSize/2, kBallSize/2)
            frame.size = CGSizeMake(kExpandedW, kBallSize);
            frame.origin.x = point.x - ([self _ballX] + kBallSize / 2.0);
            frame.origin.y = point.y - kBallSize / 2.0;
            CGFloat maxX = MAX(0, base.width  - frame.size.width);
            CGFloat maxY = MAX(0, base.height - frame.size.height);
            frame.origin.x = MAX(0, MIN(frame.origin.x, maxX));
            frame.origin.y = MAX(0, MIN(frame.origin.y, maxY));
        }
    }
    self.frame = frame;
    // 后台 SBS 托管时 CA 提交被节流, 显式 flush 确保新位置立即同步到
    // SpringBoard 远程上下文, 否则"移动悬浮球不生效/延迟生效"
    TSFlushCATransaction();
}

// 冷启动接口 /float 实现: 移动/隐藏悬浮球
- (void)moveBallToSide:(NSInteger)side verticalPx:(CGFloat)yPx {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self moveBallToSide:side verticalPx:yPx];
        });
        return;
    }
    CGSize screen = [self _effectiveScreenSize];
    if (yPx < 0) {
        // 移到屏幕外不可见位置实现隐藏 (不销毁窗口状态)
        CGRect f = self.frame;
        f.origin.x = screen.width + 500;
        f.origin.y = screen.height + 500;
        self.frame = f;
        return;
    }
    [self show];
    CGFloat scale = [UIScreen mainScreen].scale;
    CGFloat x = (side == 1) ? screen.width : 0;
    CGFloat y = yPx / scale;
    [self setBallPoint:CGPointMake(x, y)];
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
    // 前后台切换可能伴随设备方向/悬浮球位置变化 (后台冻结竖屏坐标系),
    // 回到前台后刷新方向布局与贴边。
    if (self.hidden) return;
    [self _applyOrientationLayout];
    [self _snapToEdgeAnimated:NO];
}

@end
