//
//  TSHUDWindow.m
//  TrollAutoTouch
//
//  悬浮控制窗(HUD): 可拖动圆形主按钮 + 点击展开控制面板。
//  使用旧式 UIWindow (不依赖 UIScene)，避免 TrollStore 下 Scene 生命周期冲突。
//
//  控制面板包含: 启停脚本 / 录制触控 / 回放 / 缓存截屏 / 拍照 / 设备信息 / UI树 / 全部停止
//

#import "TSHUDWindow.h"

static const CGFloat kBtnSize   = 52.0;
static const CGFloat kPanelW    = 180.0;
static const CGFloat kPanelH    = 360.0;
static const CGFloat kRowH      = 42.0;
static const CGFloat kAnimDur   = 0.25;

static NSString * const kPanelTitles[] = {
    @"启停脚本", @"录制触控", @"回放",
    @"缓存截屏", @"保存截屏", @"设备信息",
    @"UI 树", @"全部停止"
};

@interface TSHUDPanelView : UIView
@property (nonatomic, strong) NSMutableArray<UIButton *> *actionButtons;
@end
@implementation TSHUDPanelView
@end

@interface TSHUDWindow ()
@property (nonatomic, strong) UIButton            *mainBtn;
@property (nonatomic, strong) TSHUDPanelView      *panelView;
@property (nonatomic, assign) BOOL                 panelVisible;
@property (nonatomic, assign) BOOL                 recording;
@property (nonatomic, assign) BOOL                 scriptRunning;
@property (nonatomic, strong) UIPanGestureRecognizer *panGr;
@property (nonatomic, copy)   TSHUDActionBlock     actionHandler;
@end

@implementation TSHUDWindow

+ (instancetype)shared {
    static TSHUDWindow *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 旧式 UIWindow — 不依赖 UIScene
        instance = [[TSHUDWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    });
    return instance;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 100;
        self.backgroundColor = [UIColor clearColor];
        self.rootViewController = [[UIViewController alloc] init];
        self.rootViewController.view.backgroundColor = [UIColor clearColor];

        // ── 主按钮（应用图标）──
        _mainBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        _mainBtn.frame = CGRectMake(0, 0, kBtnSize, kBtnSize);
        _mainBtn.layer.cornerRadius = kBtnSize / 2.0;
        _mainBtn.layer.masksToBounds = YES;
        _mainBtn.backgroundColor = [UIColor clearColor];
        _mainBtn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
        _mainBtn.layer.borderWidth = 2.0;
        _mainBtn.layer.shadowColor = [UIColor blackColor].CGColor;
        _mainBtn.layer.shadowOffset = CGSizeMake(0, 3);
        _mainBtn.layer.shadowRadius = 6;
        _mainBtn.layer.shadowOpacity = 0.5;

        // 优先使用 AppIcon，找不到则回退到纯色 + "T"
        UIImage *icon = [UIImage imageNamed:@"AppIcon"];
        if (icon) {
            [_mainBtn setImage:icon forState:UIControlStateNormal];
            _mainBtn.imageView.contentMode = UIViewContentModeScaleAspectFill;
            _mainBtn.imageEdgeInsets = UIEdgeInsetsZero;
        } else {
            _mainBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:1.0 alpha:0.88];
            [_mainBtn setTitle:@"T" forState:UIControlStateNormal];
            _mainBtn.titleLabel.font = [UIFont boldSystemFontOfSize:26];
            [_mainBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        }

        [_mainBtn addTarget:self action:@selector(_onMainTap) forControlEvents:UIControlEventTouchUpInside];
        [self.rootViewController.view addSubview:_mainBtn];

        // 拖拽手势
        _panGr = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_onPan:)];
        [_mainBtn addGestureRecognizer:_panGr];

        // ── 面板 ──
        _panelView = [[TSHUDPanelView alloc] initWithFrame:CGRectMake(0, 0, kPanelW, kPanelH)];
        _panelView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        _panelView.layer.cornerRadius = 14;
        _panelView.layer.masksToBounds = YES;
        _panelView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
        _panelView.layer.borderWidth = 0.5;
        _panelView.hidden = YES;
        _panelView.alpha = 0;
        _panelView.actionButtons = [NSMutableArray array];
        [self.rootViewController.view addSubview:_panelView];

        [self _buildPanelButtons];
    }
    return self;
}

#pragma mark - Public API

- (void)show {
    CGFloat sx = [UIScreen mainScreen].bounds.size.width - kBtnSize - 16;
    CGFloat sy = [UIScreen mainScreen].bounds.size.height * 0.35;
    self.frame = [UIScreen mainScreen].bounds;
    _mainBtn.frame = CGRectMake(sx, sy, kBtnSize, kBtnSize);
    [self _layoutPanel];
    self.hidden = NO;
}

- (void)hide {
    self.hidden = YES;
}

- (void)setActionHandler:(TSHUDActionBlock)handler {
    _actionHandler = handler;
}

- (void)setRecording:(BOOL)recording {
    _recording = recording;
    // 更新录制按钮状态
    if (recording) {
        UIButton *btn = _panelView.actionButtons[TSHUDActionRecord];
        [btn setTitle:@"停止录制" forState:UIControlStateNormal];
        btn.tintColor = [UIColor redColor];
    } else {
        UIButton *btn = _panelView.actionButtons[TSHUDActionRecord];
        [btn setTitle:@"录制触控" forState:UIControlStateNormal];
        btn.tintColor = nil;
    }
}

- (void)setScriptRunning:(BOOL)running {
    _scriptRunning = running;
    if (running) {
        UIButton *btn = _panelView.actionButtons[TSHUDActionToggleScript];
        [btn setTitle:@"停止脚本" forState:UIControlStateNormal];
    } else {
        UIButton *btn = _panelView.actionButtons[TSHUDActionToggleScript];
        [btn setTitle:@"启停脚本" forState:UIControlStateNormal];
    }
}

#pragma mark - Actions

- (void)_onMainTap {
    if (_panelVisible) {
        [self _hidePanel:YES];
    } else {
        [self _showPanel];
    }
}

- (void)_showPanel {
    [self _layoutPanel];
    _panelView.transform = CGAffineTransformMakeScale(0.85, 0.85);
    _panelView.alpha = 0;
    _panelView.hidden = NO;
    [UIView animateWithDuration:kAnimDur
                          delay:0
         usingSpringWithDamping:0.75
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.panelView.alpha = 1;
        self.panelView.transform = CGAffineTransformIdentity;
    } completion:nil];
    _panelVisible = YES;
}

- (void)_hidePanel:(BOOL)animated {
    if (!animated) {
        _panelView.hidden = YES;
        _panelView.alpha = 0;
        _panelVisible = NO;
        return;
    }
    [UIView animateWithDuration:kAnimDur * 0.7 animations:^{
        self.panelView.alpha = 0;
        self.panelView.transform = CGAffineTransformMakeScale(0.85, 0.85);
    } completion:^(BOOL finished) {
        self.panelView.hidden = YES;
    }];
    _panelVisible = NO;
}

- (void)_layoutPanel {
    CGFloat sx = _mainBtn.frame.origin.x;
    CGFloat sy = _mainBtn.frame.origin.y;
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;

    CGFloat px = sx - kPanelW + kBtnSize;
    if (px < 8) px = sx + 8;
    CGFloat py = sy + kBtnSize + 6;
    if (py + kPanelH > screenH - 20) {
        py = sy - kPanelH - 6;
    }
    _panelView.frame = CGRectMake(px, py, kPanelW, kPanelH);
}

- (void)_buildPanelButtons {
    NSUInteger count = sizeof(kPanelTitles) / sizeof(kPanelTitles[0]);
    for (NSUInteger i = 0; i < count; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(0, i * kRowH, kPanelW, kRowH);
        [btn setTitle:kPanelTitles[i] forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        btn.tag = i;
        [btn addTarget:self action:@selector(_onPanelButton:) forControlEvents:UIControlEventTouchUpInside];
        [_panelView.actionButtons addObject:btn];
        [_panelView addSubview:btn];

        if (i < count - 1) {
            UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(14, (i+1)*kRowH - 0.5, kPanelW - 28, 0.5)];
            sep.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
            [_panelView addSubview:sep];
        }
    }
}

- (void)_onPanelButton:(UIButton *)sender {
    TSHUDAction action = (TSHUDAction)sender.tag;
    [self _hidePanel:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.actionHandler) {
            self.actionHandler(action);
        }
    });
}

#pragma mark - Pan Gesture

- (void)_onPan:(UIPanGestureRecognizer *)gr {
    if (_panelVisible) return;
    CGPoint t = [gr translationInView:self];
    CGRect f = _mainBtn.frame;
    _mainBtn.frame = CGRectMake(f.origin.x + t.x, f.origin.y + t.y, f.size.width, f.size.height);
    [gr setTranslation:CGPointZero inView:self];

    if (gr.state == UIGestureRecognizerStateEnded) {
        CGFloat mx = [UIScreen mainScreen].bounds.size.width;
        CGFloat my = [UIScreen mainScreen].bounds.size.height;
        CGFloat targetX;
        if (_mainBtn.frame.origin.x + kBtnSize/2.0 < mx/2.0) {
            targetX = 12;
        } else {
            targetX = mx - kBtnSize - 12;
        }
        CGFloat targetY = _mainBtn.frame.origin.y;
        if (targetY < 40) targetY = 40;
        if (targetY + kBtnSize > my - 40) targetY = my - kBtnSize - 40;

        [UIView animateWithDuration:0.2 animations:^{
            self.mainBtn.frame = CGRectMake(targetX, targetY, kBtnSize, kBtnSize);
        }];
        [self _layoutPanel];
    }
}

#pragma mark - Hit testing: 按钮区域响应，透明区域透传

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];

    // 面板显示时
    if (_panelVisible) {
        CGPoint pp = [self convertPoint:point toView:_panelView];
        if ([_panelView pointInside:pp withEvent:event]) {
            return [_panelView hitTest:pp withEvent:event];
        }
        // 点击面板外关闭
        [self _hidePanel:YES];
        return hit; // 如果下面有其他视图也让他们接收
    }

    // 检查是否点击在主按钮上
    CGPoint bp = [self convertPoint:point toView:_mainBtn];
    if ([_mainBtn pointInside:bp withEvent:event]) {
        return _mainBtn;
    }

    // 透明区域 → 穿透给下层
    return nil;
}

@end
