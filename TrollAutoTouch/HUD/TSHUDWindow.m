//
//  TSHUDWindow.m
//  TrollAutoTouch
//
//  悬浮窗实现: 悬浮球 + 向左展开的快捷按钮组 (暂停/恢复、启动/停止、关闭)
//  所有按钮仅图标, 不显示文字。点击悬浮球本体: 未展开则展开, 已展开则收回(取消)。
//

#import "TSHUDWindow.h"
#import "../Script/TSLuaBridge.h"

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

    _pauseBtn.frame  = CGRectMake(kBallX - (kBtnSize + kGap) * 1, 0, kBtnSize, kBtnSize);
    _toggleBtn.frame = CGRectMake(kBallX - (kBtnSize + kGap) * 2, 0, kBtnSize, kBtnSize);
    _closeBtn.frame  = CGRectMake(kBallX - (kBtnSize + kGap) * 3, 0, kBtnSize, kBtnSize);

    // 初始隐藏扩展按钮 (位于悬浮球左侧, 未展开)
    _pauseBtn.alpha  = 0;
    _toggleBtn.alpha = 0;
    _closeBtn.alpha  = 0;
    _pauseBtn.hidden  = YES;
    _toggleBtn.hidden = YES;
    _closeBtn.hidden  = YES;

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
    // 暂停/恢复: 脚本未运行时灰色禁用
    if (_scriptRunning) {
        _pauseBtn.enabled = YES;
        _pauseBtn.alpha = 1.0;
        _pauseBtn.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.88];
        [self _applyIcon:[self _hudIcon:(_paused ? @"play.fill" : @"pause.fill")] to:_pauseBtn];
    } else {
        _pauseBtn.enabled = NO;
        _pauseBtn.alpha = 1.0; // 收起后整体淡出, 展开时靠背景透明度区分
        _pauseBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.5];
        [self _applyIcon:[self _hudIcon:@"pause.fill"] to:_pauseBtn];
    }
    // 启动/停止: 未运行显示 play, 运行中显示 stop
    if (_scriptRunning) {
        [self _applyIcon:[self _hudIcon:@"stop.fill"] to:_toggleBtn];
    } else {
        [self _applyIcon:[self _hudIcon:@"play.fill"] to:_toggleBtn];
    }
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
    _pauseBtn.hidden  = NO;
    _toggleBtn.hidden = NO;
    _closeBtn.hidden  = NO;

    UIButton *buttons[] = {_closeBtn, _toggleBtn, _pauseBtn};
    for (int i = 0; i < kExtCount; i++) {
        UIButton *b = buttons[i];
        CGPoint target = b.frame.origin;
        if (animated) {
            b.frame = CGRectMake(kBallX, 0, kBtnSize, kBtnSize); // 从悬浮球位置出发
            b.alpha = 0;
        }
        [UIView animateWithDuration:animated ? 0.22 : 0.0
                              delay:animated ? (i * 0.04) : 0.0
             usingSpringWithDamping:0.85 initialSpringVelocity:0.6
                            options:UIViewAnimationOptionCurveEaseOut
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
                         animations:^{
                             b.frame = CGRectMake(kBallX, 0, kBtnSize, kBtnSize);
                             b.alpha = 0;
                         }
                         completion:^(BOOL finished) {
                             b.hidden = YES;
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
}

- (void)hide {
    if (_expanded) [self _collapseAnimated:NO];
    self.hidden = YES;
}

@end
