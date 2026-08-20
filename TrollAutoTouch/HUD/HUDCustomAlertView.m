//
//  HUDCustomAlertView.m
//  TrollAutoTouch
//
//  自绘弹窗视图实现: 全屏半透明遮罩 + 居中深色圆角卡片。
//  卡片内含标题/内容/按钮; 按钮点击或超时后自动淡出移除并回调结果。
//

#import "HUDCustomAlertView.h"

static const CGFloat kCardMaxWidth  = 300.0;
static const CGFloat kCardMinWidth  = 260.0;
static const CGFloat kCardCorner    = 14.0;
static const CGFloat kCardHMargin   = 24.0;   // 卡片距屏幕左右
static const CGFloat kCardPadding   = 18.0;   // 卡片内边距
static const CGFloat kTitleFontSize = 17.0;
static const CGFloat kMsgFontSize   = 14.0;
static const CGFloat kBtnFontSize   = 15.0;
static const CGFloat kBtnHeight     = 44.0;
static const CGFloat kTitleGap      = 6.0;    // 标题与内容间距
static const CGFloat kMsgGap        = 16.0;   // 内容与按钮间距

@interface HUDCustomAlertView ()

@property (nonatomic, copy) void (^resultBlock)(NSString *_Nullable);
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIView *buttonContainer;
@property (nonatomic, assign) NSTimeInterval timeout;
@property (nonatomic, assign) BOOL finished;

@end

@implementation HUDCustomAlertView {
    NSString *_alertTitle;
    NSString *_alertMessage;
    NSArray<NSString *> *_alertButtons;
}

- (instancetype)initWithTitle:(NSString *)title
                      message:(NSString *)message
                      buttons:(NSArray<NSString *> *)buttons
                      timeout:(NSTimeInterval)timeout
                     onResult:(void (^)(NSString *_Nullable))resultBlock {
    self = [super initWithFrame:[UIScreen mainScreen].bounds];
    if (self) {
        _resultBlock = resultBlock;
        _timeout = timeout;
        _finished = NO;
        self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];

        _alertTitle = [title copy];
        _alertMessage = [message copy];

        // 按钮兜底: 显式按钮优先; 空按钮 + 永久显示 -> 补"确定"保证可关闭
        NSMutableArray *finalButtons = [buttons mutableCopy];
        if (!finalButtons) {
            finalButtons = [NSMutableArray array];
        }
        if (finalButtons.count == 0 && timeout <= 0) {
            [finalButtons addObject:@"确定"];
        }
        _alertButtons = [finalButtons copy];

        [self _buildCardWithTitle:_alertTitle message:_alertMessage buttons:_alertButtons];
    }
    return self;
}

#pragma mark - 布局

// 按容器尺寸(宿主内容层, 旋转后宽高已交换)重排。
// 主线程调用; 加入容器后由 TSHUDHost 调用, 也可随时重排。
- (void)layoutInContainerSize:(CGSize)size {
    self.frame = CGRectMake(0, 0, size.width, size.height);

    // 移除旧卡片重建 (按钮需重新排布)
    [_cardView removeFromSuperview];
    _cardView = nil;
    _titleLabel = nil;
    _messageLabel = nil;
    _buttonContainer = nil;
    [self _buildCardWithTitle:_alertTitle message:_alertMessage buttons:_alertButtons];
}

- (void)_buildCardWithTitle:(NSString *)title message:(NSString *)message
                    buttons:(NSArray<NSString *> *)buttons {
    UIFont *titleFont = [UIFont boldSystemFontOfSize:kTitleFontSize];
    UIFont *msgFont   = [UIFont systemFontOfSize:kMsgFontSize];

    // 计算卡片尺寸 (基于当前内容层尺寸, 横屏时宽高已交换)
    CGFloat screenW = self.bounds.size.width;
    CGFloat cardW = MIN(kCardMaxWidth, MAX(kCardMinWidth, screenW - kCardHMargin * 2));

    CGFloat contentW = cardW - kCardPadding * 2;
    CGFloat y = kCardPadding;

    // 标题
    BOOL hasTitle = (title.length > 0);
    if (hasTitle) {
        CGRect r = [title boundingRectWithSize:CGSizeMake(contentW, CGFLOAT_MAX)
                                       options:NSStringDrawingUsesLineFragmentOrigin
                                    attributes:@{NSFontAttributeName: titleFont}
                                       context:nil];
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(kCardPadding, y, contentW, ceil(r.size.height))];
        _titleLabel.text = title;
        _titleLabel.font = titleFont;
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.numberOfLines = 0;
        y += CGRectGetHeight(_titleLabel.frame) + kTitleGap;
    }

    // 内容
    CGFloat msgMaxHeight = self.bounds.size.height * 0.5;
    CGRect mr = [message boundingRectWithSize:CGSizeMake(contentW, msgMaxHeight)
                                      options:NSStringDrawingUsesLineFragmentOrigin
                                   attributes:@{NSFontAttributeName: msgFont}
                                      context:nil];
    _messageLabel = [[UILabel alloc] initWithFrame:CGRectMake(kCardPadding, y, contentW, ceil(mr.size.height))];
    _messageLabel.text = message;
    _messageLabel.font = msgFont;
    _messageLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    _messageLabel.textAlignment = NSTextAlignmentCenter;
    _messageLabel.numberOfLines = 0;
    y += CGRectGetHeight(_messageLabel.frame);

    // 按钮区 (内容与按钮之间留白); 多按钮(>3)时自动增高为多行网格
    if (buttons.count > 0) {
        y += kMsgGap;
        NSUInteger cols = (buttons.count <= 3) ? buttons.count : 2;
        NSUInteger rows = (buttons.count + cols - 1) / cols;
        CGFloat containerH = rows * kBtnHeight + (rows - 1) * 8.0;
        _buttonContainer = [[UIView alloc] initWithFrame:CGRectMake(kCardPadding, y, contentW, containerH)];
        [self _layoutButtons:buttons inContainer:_buttonContainer];
        y += containerH;
    }

    y += kCardPadding;

    // 卡片 (cornerRadius 需 masksToBounds 裁剪, 阴影无法同时显示, 以边框代替)
    CGFloat cardH = y;
    _cardView = [[UIView alloc] initWithFrame:CGRectMake((screenW - cardW) / 2,
                                                         (self.bounds.size.height - cardH) / 2,
                                                         cardW, cardH)];
    _cardView.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.96];
    _cardView.layer.cornerRadius = kCardCorner;
    _cardView.layer.masksToBounds = YES;
    _cardView.layer.borderColor = [UIColor colorWithWhite:0.32 alpha:1.0].CGColor;
    _cardView.layer.borderWidth = 0.5;

    if (_titleLabel)   [_cardView addSubview:_titleLabel];
    if (_messageLabel) [_cardView addSubview:_messageLabel];
    if (_buttonContainer) [_cardView addSubview:_buttonContainer];
    [self addSubview:_cardView];
}

// 按钮排布: <=3 个水平等宽排; >3 个两列网格 (容器高度已在布局时按行数计算)
- (void)_layoutButtons:(NSArray<NSString *> *)buttons inContainer:(UIView *)container {
    NSUInteger count = buttons.count;
    CGFloat w = container.bounds.size.width;

    NSUInteger cols = (count <= 3) ? count : 2;
    CGFloat btnW = (w - (cols - 1) * 0.5) / cols;
    CGFloat btnH = kBtnHeight;

    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger col = i % cols;
        NSUInteger row = i / cols;
        CGFloat x = col * (btnW + 0.5);
        CGFloat by = row * (btnH + 8.0);
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(x, by, btnW, btnH);
        btn.tag = (NSInteger)i;
        [btn setTitle:buttons[i] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:kBtnFontSize weight:UIFontWeightMedium];
        btn.titleLabel.adjustsFontSizeToFitWidth = YES;
        btn.titleLabel.minimumScaleFactor = 0.6;
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor colorWithWhite:0.6 alpha:1.0] forState:UIControlStateHighlighted];
        btn.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1.0];
        btn.layer.cornerRadius = 8.0;
        btn.layer.masksToBounds = YES;
        [btn addTarget:self action:@selector(_buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [container addSubview:btn];
    }
}

#pragma mark - 展示 / 关闭

- (void)show {
    self.alpha = 0.0;
    [UIView animateWithDuration:0.25 animations:^{
        self.alpha = 1.0;
    }];

    if (_timeout > 0) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_timeout * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(self) self = weakSelf;
            if (self && !self.finished) {
                [self _finishWithResult:nil];
            }
        });
    }
}

- (void)_buttonTapped:(UIButton *)sender {
    NSString *title = [sender titleForState:UIControlStateNormal];
    [self _finishWithResult:title];
}

- (void)_finishWithResult:(NSString *)result {
    if (_finished) return;
    _finished = YES;

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.2 animations:^{
        __strong typeof(self) self = weakSelf;
        self.alpha = 0.0;
    } completion:^(BOOL finished) {
        __strong typeof(self) self = weakSelf;
        void (^block)(NSString *) = self.resultBlock;
        self.resultBlock = nil;
        [self removeFromSuperview];
        if (block) {
            block(result);
        }
    }];
}

@end
