//
//  HUDToastView.m
//  TrollAutoTouch
//

#import "HUDToastView.h"

@implementation HUDToastView {
    NSString *_text;
    NSTimeInterval _duration;
    BOOL _hiddenStyle;
    UIView *_card;
    UILabel *_label;
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
        [self layoutInContainerSize:[UIScreen mainScreen].bounds.size];
    }
    return self;
}

// 按容器尺寸(宿主内容层, 旋转后宽高已交换)布局。
// 主线程调用; 已在容器内时可随时重排。
- (void)layoutInContainerSize:(CGSize)size {
    UIFont *font = [UIFont boldSystemFontOfSize:_hiddenStyle ? 11.0 : 14.0];
    CGFloat maxW = size.width * (_hiddenStyle ? 0.9 : 0.78);
    CGFloat maxH = size.height * 0.35;

    // 计算文本尺寸
    CGRect textRect = [_text boundingRectWithSize:CGSizeMake(maxW, maxH)
                                          options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                       attributes:@{NSFontAttributeName : font}
                                          context:nil];
    CGFloat padX = 16, padY = 10;
    CGSize cardSize = CGSizeMake(ceil(textRect.size.width) + padX * 2,
                                 ceil(textRect.size.height) + padY * 2);
    if (cardSize.width > maxW + padX * 2) cardSize.width = maxW + padX * 2;

    // 位置: 普通样式居中偏上; 弱化样式贴顶部(状态栏下方)
    CGFloat x = (size.width - cardSize.width) / 2.0;
    CGFloat y;
    if (_hiddenStyle) {
        y = 60.0; // 顶部小字, 远离中部的找色区域
    } else {
        y = size.height * 0.32; // 居中偏上, 醒目但不过分遮挡
    }
    self.frame = CGRectMake(x, y, cardSize.width, cardSize.height);

    if (!_card) {
        // 背景卡片
        _card = [[UIView alloc] initWithFrame:self.bounds];
        _card.layer.cornerRadius = 8.0;
        _card.clipsToBounds = YES;
        if (_hiddenStyle) {
            _card.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
        } else {
            _card.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
        }
        [self addSubview:_card];

        // 文本
        _label = [[UILabel alloc] initWithFrame:CGRectInset(self.bounds, padX, padY)];
        _label.text = _text;
        _label.font = font;
        _label.textColor = [UIColor whiteColor];
        _label.numberOfLines = 0;
        _label.textAlignment = NSTextAlignmentCenter;
        _label.lineBreakMode = NSLineBreakByWordWrapping;
        [self addSubview:_label];
    } else {
        _card.frame = self.bounds;
        _label.frame = CGRectInset(self.bounds, padX, padY);
    }
}

// 加入容器后自动按容器实际尺寸重排 (容器可能是旋转后的内容层)。
- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    if (self.superview) {
        [self layoutInContainerSize:self.superview.bounds.size];
    }
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
