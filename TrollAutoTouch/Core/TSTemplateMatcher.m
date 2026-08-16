//
//  TSTemplateMatcher.m
//  TrollAutoTouch
//
//  归一化互相关(NCC)模板匹配实现。
//  算法: 在截屏 RGBA 像素缓冲中滑动模板窗口，计算归一化互相关系数，
//        取最高分且超过阈值的位置作为匹配结果。
//

#import "TSTemplateMatcher.h"
#import "TSScreenCapture.h"
#import <UIKit/UIKit.h>
#import <Accelerate/Accelerate.h>

@implementation TSTemplateMatchResult
@end

@interface TSTemplateMatcher ()
// 缓存模板灰度数据，避免重复转换
@property (nonatomic, strong) NSCache<NSString *, NSData *> *templateCache;
@end

@implementation TSTemplateMatcher

+ (instancetype)shared {
    static TSTemplateMatcher *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[TSTemplateMatcher alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _templateCache = [[NSCache alloc] init];
        _templateCache.countLimit = 10;
    }
    return self;
}

#pragma mark - 公共 API

- (nullable TSTemplateMatchResult *)findImageOnScreen:(UIImage *)templateImage
                                             accuracy:(CGFloat)accuracy
                                                 rect:(CGRect)rect {
    uint8_t *pixels = NULL;
    int w = 0, h = 0;
    // 优先复用 screen.keep() 缓存像素(找图性能提升)；无缓存则实时截屏
    if (![[TSScreenCapture shared] getCachedPixels:&pixels width:&w height:&h] || !pixels) {
        return nil;
    }
    
    // 截屏像素尺寸即屏幕物理像素，Lua 层统一用物理像素坐标，因此按 1:1 换算
    CGSize ss = CGSizeMake(w, h);
    TSTemplateMatchResult *res = [self findImage:templateImage accuracy:accuracy rect:rect
                                         pixels:pixels width:w height:h screenSize:ss];
    free(pixels);
    return res;
}

- (nullable TSTemplateMatchResult *)findImageAtPath:(NSString *)imagePath
                                           accuracy:(CGFloat)accuracy
                                               rect:(CGRect)rect {
    UIImage *img = [UIImage imageWithContentsOfFile:imagePath];
    if (!img) return nil;
    return [self findImageOnScreen:img accuracy:accuracy rect:rect];
}

- (nullable TSTemplateMatchResult *)findImage:(UIImage *)templateImage
                                     accuracy:(CGFloat)accuracy
                                         rect:(CGRect)rect {
    return [self findImageOnScreen:templateImage accuracy:accuracy rect:rect];
}

#pragma mark - 核心匹配算法

- (nullable TSTemplateMatchResult *)findImage:(UIImage *)templateImage
                                     accuracy:(CGFloat)accuracy
                                         rect:(CGRect)rect
                                      pixels:(const uint8_t *)pixels
                                       width:(int)screenW height:(int)screenH
                                  screenSize:(CGSize)screenSize {
    if (!templateImage || !pixels || screenW <= 0 || screenH <= 0) return nil;
    if (accuracy <= 0) accuracy = 0.8;
    if (accuracy > 1) accuracy = 1;
    
    // 1) 提取模板灰度数据
    float *tplGray = NULL;
    int tplW = 0, tplH = 0;
    if (![self _extractGrayFromImage:templateImage outData:&tplGray width:&tplW height:&tplH]) {
        return nil;
    }
    
    if (tplW > screenW || tplH > screenH) {
        free(tplGray);
        return nil; // 模板比截屏大
    }
    
    // 2) 提取截屏灰度(仅在搜索区域内)
    CGFloat sx = (CGFloat)screenW / screenSize.width;
    CGFloat sy = (CGFloat)screenH / screenSize.height;
    
    int x0 = 0, y0 = 0, x1 = screenW, y1 = screenH;
    if (rect.size.width > 0 && rect.size.height > 0) {
        x0 = (int)(rect.origin.x * sx);
        y0 = (int)(rect.origin.y * sy);
        x1 = (int)((rect.origin.x + rect.size.width) * sx);
        y1 = (int)((rect.origin.y + rect.size.height) * sy);
        x0 = MAX(0, x0); y0 = MAX(0, y0);
        x1 = MIN(screenW, x1); y1 = MIN(screenH, y1);
    }
    int roiW = x1 - x0;
    int roiH = y1 - y0;
    if (roiW < tplW || roiH < tplH) {
        free(tplGray);
        return nil;
    }
    
    float *scrnGray = malloc(roiW * roiH * sizeof(float));
    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            int idx = (y * screenW + x) * 4;
            scrnGray[(y - y0) * roiW + (x - x0)] =
                0.299f * pixels[idx] + 0.587f * pixels[idx+1] + 0.114f * pixels[idx+2];
        }
    }
    
    // 3) 计算模板统计量
    float tplMean = 0, tplStd = 0;
    int tplN = tplW * tplH;
    for (int i = 0; i < tplN; i++) tplMean += tplGray[i];
    tplMean /= tplN;
    for (int i = 0; i < tplN; i++) {
        float d = tplGray[i] - tplMean;
        tplStd += d * d;
    }
    tplStd = sqrtf(tplStd);
    if (tplStd < 1e-6f) { free(tplGray); free(scrnGray); return nil; } // 模板是纯色
    
    // 4) 滑动窗口 NCC 匹配
    float bestScore = -1;
    int bestX = 0, bestY = 0;
    int scanW = roiW - tplW + 1;
    int scanH = roiH - tplH + 1;
    
    for (int sy0 = 0; sy0 < scanH; sy0++) {
        for (int sx0 = 0; sx0 < scanW; sx0++) {
            // 计算窗口均值
            float winMean = 0;
            for (int ty = 0; ty < tplH; ty++) {
                int rowOff = (sy0 + ty) * roiW + sx0;
                for (int tx = 0; tx < tplW; tx++) {
                    winMean += scrnGray[rowOff + tx];
                }
            }
            winMean /= tplN;
            
            // 计算窗口标准差
            float winStd = 0;
            for (int ty = 0; ty < tplH; ty++) {
                int rowOff = (sy0 + ty) * roiW + sx0;
                for (int tx = 0; tx < tplW; tx++) {
                    float d = scrnGray[rowOff + tx] - winMean;
                    winStd += d * d;
                }
            }
            winStd = sqrtf(winStd);
            if (winStd < 1e-6f) continue; // 窗口是纯色, 跳过
            
            // 互相关
            float ncc = 0;
            for (int ty = 0; ty < tplH; ty++) {
                int rowOff = (sy0 + ty) * roiW + sx0;
                int tplOff = ty * tplW;
                for (int tx = 0; tx < tplW; tx++) {
                    ncc += (tplGray[tplOff + tx] - tplMean) * (scrnGray[rowOff + tx] - winMean);
                }
            }
            ncc /= (tplStd * winStd);
            
            if (ncc > bestScore) {
                bestScore = ncc;
                bestX = sx0 + x0;
                bestY = sy0 + y0;
                if (bestScore >= 0.999f) goto found; // 完美匹配，可提前退出
            }
        }
    }
    
found:
    free(tplGray);
    free(scrnGray);
    
    if (bestScore < accuracy) return nil;
    
    // 输出结果(转回逻辑坐标)
    TSTemplateMatchResult *result = [[TSTemplateMatchResult alloc] init];
    CGFloat cx = (CGFloat)(bestX + tplW / 2) / sx;
    CGFloat cy = (CGFloat)(bestY + tplH / 2) / sy;
    result.center = CGPointMake(cx, cy);
    result.confidence = bestScore;
    result.rect = CGRectMake((CGFloat)bestX / sx, (CGFloat)bestY / sy,
                             (CGFloat)tplW / sx, (CGFloat)tplH / sy);
    return result;
}

#pragma mark - 工具函数

/// 从 UIImage 提取灰度浮点数组
- (BOOL)_extractGrayFromImage:(UIImage *)image
                      outData:(float **)outData
                        width:(int *)width height:(int *)height {
    CGImageRef cg = image.CGImage;
    int w = (int)CGImageGetWidth(cg);
    int h = (int)CGImageGetHeight(cg);
    if (w <= 0 || h <= 0) return NO;
    
    uint8_t *rgba = malloc(w * h * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rgba, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    
    float *gray = malloc(w * h * sizeof(float));
    for (int i = 0; i < w * h; i++) {
        gray[i] = 0.299f * rgba[i*4] + 0.587f * rgba[i*4+1] + 0.114f * rgba[i*4+2];
    }
    free(rgba);
    
    *outData = gray;
    *width = w;
    *height = h;
    return YES;
}

@end
