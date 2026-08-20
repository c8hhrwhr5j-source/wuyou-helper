//
//  HUDToastView.m
//  TrollAutoTouch
//

#import "HUDToastView.h"

@implementation HUDToastView {
    NSString *_text;
    NSTimeInterval _duration;
    BOOL _hiddenStyle;
}

- (instancetype)initWithText:(NSString *)text
                    duration:(NSTimeInterval)duration
                      hidden:(BOOL)hidden {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _text = [text copy];
        _duration = (duration > 0) ? duration : 1.0;
        _hiddenStyle = hidden;
        self.userInteractionEnabled = NO;   // toast 不拦截触摸
        self.backgroundColor = [UIColor clearColor];
        [self _layoutContent];
    }
    return self;
}

- (void)_layoutContent {
    UIFont *font = [UIFont boldSystemFontOfSize:_hiddenStyle ? 11.0 : 14.0];
    UIScreen *screen = [UIScreen mainScreen];
    CGFloat maxW = CGRectGetWidth(screen.bounds) * (_hiddenStyle ? 0.9 : 0.78);
    CGFloat maxH = CGRectGetHeight(screen.bounds) * 0.35;

    // 计算文本尺寸
    CGRect textRect = [_text boundingRectWithSize:CGSizeMake(maxW, maxH)
                                          options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                       attributes:@{NSFontAttributeName : font}
                                          context:nil];
    CGFloat padX = 16, padY = 10;
    CGSize cardSize = CGSizeMake(ceil(textRect.size.width) + padX * 2,
                                 ceil(textRect.size.height) + padY * 2);
    if (cardSize.width > maxW + padX * 2) cardSize.width = maxW + padX * 2;

    // 位置: 普通样式居中偏上; 弱化样式贴屏幕顶部(状态栏下方)
    CGFloat w = CGRectGetWidth(screen.bounds);
    CGFloat h = CGRectGetHeight(screen.bounds);
    CGFloat x = (w - cardSize.width) / 2.0;
    CGFloat y;
    if (_hiddenStyle) {
        y = 60.0; // 顶部小字, 远离中部的找色区域
    } else {
        y = h * 0.32; // 居中偏上, 醒目但不过分遮挡
    }
    self.frame = CGRectMake(x, y, cardSize.width, cardSize.height);

    // 背景卡片
    UIView *card = [[UIView alloc] initWithFrame:self.bounds];
    card.layer.cornerRadius = 8.0;
    card.clipsToBounds = YES;
    if (_hiddenStyle) {
        card.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
    } else {
        card.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
    }
    [self addSubview:card];

    // 文本
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(self.bounds, padX, padY)];
    label.text = _text;
    label.font = font;
    label.textColor = _hiddenStyle ? [UIColor whiteColor] : [UIColor whiteColor];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    [self addSubview:label];
}

- (void)show {
    // 淡入
    self.alpha = 0.0;
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = 1.0;
    } completion:^(BOOL finished) {
        // 到时淡出并移除
        [UIView animateWithDuration:0.3
                              delay:_duration
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:^{
            self.alpha = 0.0;
        } completion:^(BOOL done) {
            [self removeFromSuperview];
        }];
    }];
}

@end
