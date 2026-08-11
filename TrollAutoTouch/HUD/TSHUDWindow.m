//
//  TSHUDWindow.m
//  TrollAutoTouch
//

#import "TSHUDWindow.h"

static CGFloat const kBtnSize = 52;
static CGFloat const kPanelBtnSize = 40;
static CGFloat const kMargin = 8;
static NSInteger const kPanelCols = 4;

@interface TSHUDWindow () {
    UIButton     *_mainBtn;
    UIView       *_panelView;
    BOOL          _panelExpanded;
    BOOL          _isDragging;
    CGPoint       _dragOffset;
    BOOL          _scriptRunning;
    BOOL          _isRecording;
}
@property (nonatomic, copy) TSHUDActionBlock actionHandler;
@end

@implementation TSHUDWindow

+ (instancetype)shared {
    static TSHUDWindow *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIWindowScene *scene = (UIWindowScene *)[UIApplication sharedApplication].connectedScenes.allObjects.firstObject;
        instance = [[TSHUDWindow alloc] initWithWindowScene:scene];
    });
    return instance;
}

- (instancetype)initWithWindowScene:(UIWindowScene *)scene {
    self = [super initWithWindowScene:scene];
    if (self) {
        self.frame = CGRectMake(0, 0, 200, 200);
        self.windowLevel = UIWindowLevelAlert + 100;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.rootViewController = [UIViewController new];
        self.rootViewController.view.backgroundColor = [UIColor clearColor];

        _panelExpanded = NO;
        _scriptRunning = NO;
        _isRecording = NO;

        [self _buildUI];
    }
    return self;
}

- (void)_buildUI {
    // ---- 主按钮(圆形) ----
    _mainBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _mainBtn.frame = CGRectMake(0, 0, kBtnSize, kBtnSize);
    _mainBtn.layer.cornerRadius = kBtnSize / 2;
    _mainBtn.layer.shadowColor = [UIColor blackColor].CGColor;
    _mainBtn.layer.shadowOffset = CGSizeMake(0, 2);
    _mainBtn.layer.shadowOpacity = 0.4;
    _mainBtn.layer.shadowRadius = 4;
    _mainBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9];
    [_mainBtn setTitle:@"▶" forState:UIControlStateNormal];
    _mainBtn.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    [_mainBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    // 拖动手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_onPan:)];
    [_mainBtn addGestureRecognizer:pan];

    // 点击: 切换脚本
    [_mainBtn addTarget:self action:@selector(_onMainTap) forControlEvents:UIControlEventTouchUpInside];

    // 长按: 展开/收起面板
    UILongPressGestureRecognizer *longP = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(_onLongPress:)];
    longP.minimumPressDuration = 0.5;
    [_mainBtn addGestureRecognizer:longP];

    [self.rootViewController.view addSubview:_mainBtn];

    // ---- 控制面板(默认隐藏) ----
    _panelView = [[UIView alloc] init];
    _panelView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
    _panelView.layer.cornerRadius = 12;
    _panelView.clipsToBounds = YES;
    _panelView.hidden = YES;
    [self.rootViewController.view addSubview:_panelView];

    // 面板按钮
    NSArray *items = @[
        @{@"title": @"开始",   @"tag": @(TSHUDActionToggleScript)},
        @{@"title": @"录制",   @"tag": @(TSHUDActionRecord)},
        @{@"title": @"回放",   @"tag": @(TSHUDActionPlayRecord)},
        @{@"title": @"缓存",   @"tag": @(TSHUDActionKeepScreen)},
        @{@"title": @"截屏",   @"tag": @(TSHUDActionScreenshot)},
        @{@"title": @"设备",   @"tag": @(TSHUDActionDeviceInfo)},
        @{@"title": @"UI树",   @"tag": @(TSHUDActionAppTree)},
        @{@"title": @"停止全部",@"tag": @(TSHUDActionStopAll)},
    ];

    CGFloat pW = kPanelCols * kPanelBtnSize + (kPanelCols + 1) * kMargin;
    CGFloat rows = ceil((CGFloat)items.count / kPanelCols);
    CGFloat pH = rows * kPanelBtnSize + (rows + 1) * kMargin;
    _panelView.frame = CGRectMake(0, 0, pW, pH);

    for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
        NSInteger row = i / kPanelCols, col = i % kPanelCols;
        CGFloat bx = kMargin + col * (kPanelBtnSize + kMargin);
        CGFloat by = kMargin + row * (kPanelBtnSize + kMargin);

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(bx, by, kPanelBtnSize, kPanelBtnSize);
        btn.layer.cornerRadius = kPanelBtnSize / 2;
        btn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
        [btn setTitle:items[i][@"title"] forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:11];
        btn.tag = [items[i][@"tag"] integerValue];
        [btn addTarget:self action:@selector(_onPanelBtn:) forControlEvents:UIControlEventTouchUpInside];
        [_panelView addSubview:btn];
    }
}

#pragma mark - 公开 API

- (void)show {
    self.hidden = NO;

    // 默认位置: 右侧中部
    CGFloat sx = [UIScreen mainScreen].bounds.size.width - kBtnSize - 16;
    CGFloat sy = [UIScreen mainScreen].bounds.size.height * 0.4;
    self.frame = CGRectMake(sx, sy, kBtnSize, kBtnSize);
    _mainBtn.frame = CGRectMake(0, 0, kBtnSize, kBtnSize);

    [self _layoutPanel];
}

- (void)hide {
    self.hidden = YES;
}

- (void)setActionHandler:(TSHUDActionBlock)handler {
    _actionHandler = handler;
}

- (void)setRecording:(BOOL)recording {
    _isRecording = recording;
    if (!_panelExpanded) return;
    for (UIView *v in _panelView.subviews) {
        if ([v isKindOfClass:[UIButton class]] && v.tag == TSHUDActionRecord) {
            [(UIButton *)v setTitle:recording ? @"停止录制" : @"录制" forState:UIControlStateNormal];
            v.backgroundColor = recording ? [UIColor redColor] : [UIColor colorWithWhite:0.25 alpha:1];
        }
    }
}

- (void)setScriptRunning:(BOOL)running {
    _scriptRunning = running;
    [_mainBtn setTitle:running ? @"■" : @"▶" forState:UIControlStateNormal];
    _mainBtn.backgroundColor = running
        ? [UIColor colorWithRed:0.9 green:0.3 blue:0.3 alpha:0.9]
        : [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9];
}

#pragma mark - 交互

- (void)_onMainTap {
    if (self.actionHandler) self.actionHandler(TSHUDActionToggleScript);
}

- (void)_onLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    _panelExpanded = !_panelExpanded;

    if (_panelExpanded) {
        [self _showPanel];
    } else {
        [self _hidePanel];
    }
}

- (void)_onPanelBtn:(UIButton *)btn {
    TSHUDAction action = (TSHUDAction)btn.tag;
    if (self.actionHandler) self.actionHandler(action);
}

- (void)_onPan:(UIPanGestureRecognizer *)pan {
    CGPoint trans = [pan translationInView:self];
    if (pan.state == UIGestureRecognizerStateBegan) {
        _isDragging = YES;
        _dragOffset = CGPointZero;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGRect f = self.frame;
        f.origin.x += trans.x - _dragOffset.x;
        f.origin.y += trans.y - _dragOffset.y;
        _dragOffset = trans;

        // 边界约束
        CGFloat maxX = [UIScreen mainScreen].bounds.size.width - kBtnSize;
        CGFloat maxY = [UIScreen mainScreen].bounds.size.height - kBtnSize;
        f.origin.x = MAX(0, MIN(f.origin.x, maxX));
        f.origin.y = MAX(0, MIN(f.origin.y, maxY));

        self.frame = f;
        [self _layoutPanel];
    } else if (pan.state == UIGestureRecognizerStateEnded) {
        _isDragging = NO;
    }
}

- (void)_showPanel {
    self.frame = CGRectMake(self.frame.origin.x, self.frame.origin.y,
                            _panelView.frame.size.width, _panelView.frame.size.height + kBtnSize + kMargin);
    _mainBtn.frame = CGRectMake(0, _panelView.frame.size.height + kMargin, kBtnSize, kBtnSize);
    _panelView.frame = CGRectMake(0, 0, _panelView.frame.size.width, _panelView.frame.size.height);
    _panelView.hidden = NO;

    // 更新录制按钮
    [self setRecording:_isRecording];
}

- (void)_hidePanel {
    _panelView.hidden = YES;
    self.frame = CGRectMake(self.frame.origin.x, self.frame.origin.y + _panelView.frame.size.height + kMargin,
                            kBtnSize, kBtnSize);
    _mainBtn.frame = CGRectMake(0, 0, kBtnSize, kBtnSize);
}

- (void)_layoutPanel {
    if (_panelExpanded) {
        _mainBtn.frame = CGRectMake(0, _panelView.frame.size.height + kMargin, kBtnSize, kBtnSize);
    } else {
        _mainBtn.frame = CGRectMake(0, 0, kBtnSize, kBtnSize);
    }
}

@end
