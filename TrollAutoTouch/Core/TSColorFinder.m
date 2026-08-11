//
//  TSColorFinder.m
//  TrollAutoTouch
//

#import "TSColorFinder.h"
#import <limits.h>

@implementation TSColorResult
@end

@implementation TSColorFinder

/// 逻辑点 -> 像素坐标(考虑 scale)
static inline void pointToPixel(CGPoint p, CGSize screenSize, int w, int h, int *px, int *py) {
    CGFloat sx = (CGFloat)w / screenSize.width;
    CGFloat sy = (CGFloat)h / screenSize.height;
    *px = (int)(p.x * sx);
    *py = (int)(p.y * sy);
    if (*px < 0) *px = 0; if (*px >= w) *px = w - 1;
    if (*py < 0) *py = 0; if (*py >= h) *py = h - 1;
}

+ (int)getColorAtPoint:(CGPoint)point
                pixels:(const uint8_t *)pixels
                 width:(int)w height:(int)h
            screenSize:(CGSize)screenSize {
    int px, py;
    pointToPixel(point, screenSize, w, h, &px, &py);
    const uint8_t *c = pixels + (py * w + px) * 4;
    return (c[0] << 16) | (c[1] << 8) | c[2]; // 0xRRGGBB
}

+ (int)colorDiffBetween:(int)a and:(int)b {
    int ar = (a >> 16) & 0xFF, ag = (a >> 8) & 0xFF, ab = a & 0xFF;
    int br = (b >> 16) & 0xFF, bg = (b >> 8) & 0xFF, bb = b & 0xFF;
    int dr = ar - br, dg = ag - bg, db = ab - bb;
    return dr * dr + dg * dg + db * db;
}

+ (TSColorResult *)findColor:(int)color
                        rect:(CGRect)rect
                         sim:(CGFloat)sim
                      pixels:(const uint8_t *)pixels
                       width:(int)w height:(int)h
                  screenSize:(CGSize)screenSize {
    if (sim <= 0) { sim = 0.9; }
    if (sim > 1)  { sim = 1; }
    // 相似度 -> 允许的最大色差平方和
    int maxDiff = (int)((1.0 - sim) * 3.0 * 255.0 * 255.0);

    // 搜索区域(逻辑点)->像素区域
    CGFloat sx = (CGFloat)w / screenSize.width;
    CGFloat sy = (CGFloat)h / screenSize.height;
    int x0 = rect.size.width  > 0 ? (int)(rect.origin.x * sx) : 0;
    int y0 = rect.size.height > 0 ? (int)(rect.origin.y * sy) : 0;
    int x1 = rect.size.width  > 0 ? (int)((rect.origin.x + rect.size.width)  * sx) : w;
    int y1 = rect.size.height > 0 ? (int)((rect.origin.y + rect.size.height) * sy) : h;
    x0 = MAX(0, x0); y0 = MAX(0, y0);
    x1 = MIN(w, x1); y1 = MIN(h, y1);

    int bestDiff = INT_MAX;
    CGPoint best = CGPointMake(-1, -1);

    for (int y = y0; y < y1; y++) {
        const uint8_t *row = pixels + y * w * 4;
        for (int x = x0; x < x1; x++) {
            const uint8_t *c = row + x * 4;
            int got = (c[0] << 16) | (c[1] << 8) | c[2];
            int d = [self colorDiffBetween:got and:color];
            if (d <= maxDiff && d < bestDiff) {
                bestDiff = d;
                best = CGPointMake(x / sx, y / sy);
                if (d == 0) { goto done; } // 完全命中
            }
        }
    }
done:
    if (best.x < 0) { return nil; }
    TSColorResult *r = [TSColorResult new];
    r.point = best;
    r.diff = bestDiff;
    return r;
}

+ (TSColorResult *)findMultiColor:(int)mainColor
                              rect:(CGRect)rect
                       mainColorSim:(CGFloat)sim
                           offsets:(NSArray<NSDictionary *> *)offsets
                          offsetSim:(CGFloat)offsetSim
                            pixels:(const uint8_t *)pixels
                             width:(int)w height:(int)h
                        screenSize:(CGSize)screenSize {
    if (sim <= 0) sim = 0.9;
    if (offsetSim <= 0) offsetSim = sim;
    int maxMain = (int)((1.0 - sim) * 3.0 * 255.0 * 255.0);
    int maxOff  = (int)((1.0 - offsetSim) * 3.0 * 255.0 * 255.0);

    CGFloat sx = (CGFloat)w / screenSize.width;
    CGFloat sy = (CGFloat)h / screenSize.height;
    int x0 = rect.size.width  > 0 ? (int)(rect.origin.x * sx) : 0;
    int y0 = rect.size.height > 0 ? (int)(rect.origin.y * sy) : 0;
    int x1 = rect.size.width  > 0 ? (int)((rect.origin.x + rect.size.width)  * sx) : w;
    int y1 = rect.size.height > 0 ? (int)((rect.origin.y + rect.size.height) * sy) : h;
    x0 = MAX(0, x0); y0 = MAX(0, y0);
    x1 = MIN(w, x1); y1 = MIN(h, y1);

    for (int y = y0; y < y1; y++) {
        const uint8_t *row = pixels + y * w * 4;
        for (int x = x0; x < x1; x++) {
            const uint8_t *c = row + x * 4;
            int got = (c[0] << 16) | (c[1] << 8) | c[2];
            if ([self colorDiffBetween:got and:mainColor] > maxMain) { continue; }

            // 主色命中，校验偏移点
            BOOL allOk = YES;
            for (NSDictionary *off in offsets) {
                CGFloat dx = [off[@"x"] doubleValue];
                CGFloat dy = [off[@"y"] doubleValue];
                int oc = [off[@"color"] intValue];
                int opx = x + (int)(dx * sx);
                int opy = y + (int)(dy * sy);
                if (opx < 0 || opx >= w || opy < 0 || opy >= h) { allOk = NO; break; }
                const uint8_t *oc2 = pixels + (opy * w + opx) * 4;
                int ogot = (oc2[0] << 16) | (oc2[1] << 8) | oc2[2];
                if ([self colorDiffBetween:ogot and:oc] > maxOff) { allOk = NO; break; }
            }
            if (allOk) {
                TSColorResult *r = [TSColorResult new];
                r.point = CGPointMake(x / sx, y / sy);
                r.diff = 0;
                return r;
            }
        }
    }
    return nil;
}

@end
