//
//  TSSparklineView.m
//  TrollAutoTouch
//

#import "TSSparklineView.h"

@implementation TSSparklineView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        _values = @[];
        _strokeColor = [UIColor colorWithRed:0.30 green:0.85 blue:0.40 alpha:1.0];
        _fillColor   = nil;
        _barMode = NO;
    }
    return self;
}

- (void)setValues:(NSArray<NSNumber *> *)values {
    _values = [values copy] ?: @[];
    [self setNeedsDisplay];
}

- (void)appendValue:(CGFloat)v {
    CGFloat clamped = MAX(0.0, MIN(1.0, v));
    NSMutableArray *m = [_values mutableCopy] ?: [NSMutableArray array];
    [m addObject:@(clamped)];
    if (m.count > 80) [m removeObjectsInRange:NSMakeRange(0, m.count - 80)];
    _values = m;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    if (_values.count == 0) return;

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetShouldAntialias(ctx, YES);
    CGContextSetLineWidth(ctx, 1.0);

    CGFloat w = rect.size.width;
    CGFloat h = rect.size.height;

    if (_barMode) {
        // ── 柱状模式：每个数据点画一个小竖条，渐变配色 ──
        NSUInteger n = _values.count;
        CGFloat step = w / MAX(n, 1);
        CGFloat bw = MAX(step - 0.5, 0.5);
        for (NSUInteger i = 0; i < n; i++) {
            CGFloat v = [_values[i] doubleValue];
            CGFloat bh = v * h;
            CGFloat x = i * step;
            CGFloat y = h - bh;

            UIColor *c;
            if (v < 0.5) {
                c = [UIColor colorWithRed:0.3 green:0.85 blue:0.4 alpha:0.85]; // 绿
            } else if (v < 0.85) {
                c = [UIColor colorWithRed:1.0 green:0.8 blue:0.2 alpha:0.85]; // 黄
            } else {
                c = [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:0.85]; // 红
            }
            CGContextSetFillColorWithColor(ctx, c.CGColor);
            CGContextFillRect(ctx, CGRectMake(x, y, bw, bh));
        }
        return;
    }

    // ── 折线模式 ──
    NSUInteger n = _values.count;
    CGFloat step = w / MAX(n - 1, 1);

    // 路径
    CGContextBeginPath(ctx);
    for (NSUInteger i = 0; i < n; i++) {
        CGFloat v = [_values[i] doubleValue];
        CGFloat x = i * step;
        CGFloat y = h - v * h;
        if (i == 0) CGContextMoveToPoint(ctx, x, y);
        else        CGContextAddLineToPoint(ctx, x, y);
    }

    // 填充
    if (_fillColor) {
        CGContextAddLineToPoint(ctx, w, h);
        CGContextAddLineToPoint(ctx, 0, h);
        CGContextClosePath(ctx);
        CGContextSetFillColorWithColor(ctx, _fillColor.CGColor);
        CGContextFillPath(ctx);

        // 重画线
        CGContextBeginPath(ctx);
        for (NSUInteger i = 0; i < n; i++) {
            CGFloat v = [_values[i] doubleValue];
            CGFloat x = i * step;
            CGFloat y = h - v * h;
            if (i == 0) CGContextMoveToPoint(ctx, x, y);
            else        CGContextAddLineToPoint(ctx, x, y);
        }
    }

    CGContextSetStrokeColorWithColor(ctx, _strokeColor.CGColor);
    CGContextStrokePath(ctx);
}

@end