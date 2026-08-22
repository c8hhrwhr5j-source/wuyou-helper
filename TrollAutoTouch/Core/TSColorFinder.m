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
                          mainTolR:(uint8_t)mainTolR
                          mainTolG:(uint8_t)mainTolG
                          mainTolB:(uint8_t)mainTolB
                           offsets:(NSArray<NSDictionary *> *)offsets
                          offsetSim:(CGFloat)offsetSim
                          direction:(int)direction
                            pixels:(const uint8_t *)pixels
                             width:(int)w height:(int)h
                        screenSize:(CGSize)screenSize {
    if (sim <= 0) sim = 0.9;
    if (offsetSim <= 0) offsetSim = sim;
    // AutoGo str2color: 无偏色后缀时每通道容差 = (1-sim)*255
    uint8_t baseTol = (uint8_t)((1.0 - sim) * 255.0);
    uint8_t offTol  = (uint8_t)((1.0 - offsetSim) * 255.0);
    if (mainTolR == 0 && mainTolG == 0 && mainTolB == 0) {
        mainTolR = mainTolG = mainTolB = baseTol;
    }
    int mR = (mainColor >> 16) & 0xFF, mG = (mainColor >> 8) & 0xFF, mB = mainColor & 0xFF;

    CGFloat sx = (CGFloat)w / screenSize.width;
    CGFloat sy = (CGFloat)h / screenSize.height;
    int x0 = rect.size.width  > 0 ? (int)(rect.origin.x * sx) : 0;
    int y0 = rect.size.height > 0 ? (int)(rect.origin.y * sy) : 0;
    int x1 = rect.size.width  > 0 ? (int)((rect.origin.x + rect.size.width)  * sx) : w;
    int y1 = rect.size.height > 0 ? (int)((rect.origin.y + rect.size.height) * sy) : h;
    x0 = MAX(0, x0); y0 = MAX(0, y0);
    x1 = MIN(w, x1); y1 = MIN(h, y1);

    // AutoGo dir 扫描方向: 0=左→右/上→下, 1=右→左/上→下, 2=左→右/下→上, 3=右→左/下→上
    int stepX = (direction == 1 || direction == 3) ? -1 : 1;
    int stepY = (direction == 2 || direction == 3) ? -1 : 1;
    int xs = stepX > 0 ? x0 : x1 - 1;
    int ys = stepY > 0 ? y0 : y1 - 1;
    int xe = stepX > 0 ? x1 : x0 - 1;
    int ye = stepY > 0 ? y1 : y0 - 1;

    for (int y = ys; y != ye; y += stepY) {
        const uint8_t *row = pixels + y * w * 4;
        for (int x = xs; x != xe; x += stepX) {
            const uint8_t *c = row + x * 4;
            // isColorMatch: 主色逐通道偏色判定
            int dr = c[0] - mR; if (dr < 0) dr = -dr;
            int dg = c[1] - mG; if (dg < 0) dg = -dg;
            int db = c[2] - mB; if (db < 0) db = -db;
            if (dr > mainTolR || dg > mainTolG || db > mainTolB) { continue; }

            // 主色命中，校验偏移点(compareColorsInSequence)
            BOOL allOk = YES;
            for (NSDictionary *off in offsets) {
                int dx = (int)([off[@"x"] doubleValue] * sx);
                int dy = (int)([off[@"y"] doubleValue] * sy);
                int oc = [off[@"color"] intValue];
                NSNumber *tr = off[@"tolR"];
                uint8_t oR = tr ? (uint8_t)tr.intValue : offTol;
                NSNumber *tg = off[@"tolG"];
                uint8_t oG = tg ? (uint8_t)tg.intValue : offTol;
                NSNumber *tb = off[@"tolB"];
                uint8_t oB = tb ? (uint8_t)tb.intValue : offTol;
                int opx = x + dx, opy = y + dy;
                if (opx < 0 || opx >= w || opy < 0 || opy >= h) { allOk = NO; break; }
                const uint8_t *o = pixels + (opy * w + opx) * 4;
                int odr = o[0] - ((oc >> 16) & 0xFF); if (odr < 0) odr = -odr;
                int odg = o[1] - ((oc >> 8) & 0xFF);  if (odg < 0) odg = -odg;
                int odb = o[2] - (oc & 0xFF);         if (odb < 0) odb = -odb;
                if (odr > oR || odg > oG || odb > oB) { allOk = NO; break; }
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
