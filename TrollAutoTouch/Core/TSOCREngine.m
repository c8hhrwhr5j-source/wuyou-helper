//
//  TSOCREngine.m
//  TrollAutoTouch
//
//  OCR 实现：基于 Apple Vision Framework 的 VNRecognizeTextRequest。
//  替换原版 PaddleOCR (TomatoOCR.so) 功能。
//

#import "TSOCREngine.h"
#import "TSHIDEventTouch.h"
#import <Vision/Vision.h>

#pragma mark - TSOCRResult

@implementation TSOCRResult
- (NSString *)description {
    return [NSString stringWithFormat:@"<OCR: \"%@\" center=(%.0f,%.0f) conf=%.2f rect=%@>",
            self.text, self.center.x, self.center.y, self.confidence,
            NSStringFromCGRect(self.rect)];
}
@end

#pragma mark - TSOCREngine

@interface TSOCREngine ()
@property (nonatomic, strong) NSOperationQueue *ocrQueue;
@end

@implementation TSOCREngine

+ (instancetype)shared {
    static TSOCREngine *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TSOCREngine alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _ocrQueue = [[NSOperationQueue alloc] init];
        _ocrQueue.maxConcurrentOperationCount = 1;
        _ocrQueue.qualityOfService = NSQualityOfServiceUserInitiated;
    }
    return self;
}

#pragma mark - 整屏 OCR

- (NSArray<TSOCRResult *> *)recognize:(UIImage *)image {
    return [self recognize:image inRegion:CGRectZero languages:nil];
}

- (NSArray<TSOCRResult *> *)recognize:(UIImage *)image languages:(NSArray<NSString *> *)languages {
    return [self recognize:image inRegion:CGRectZero languages:languages];
}

- (NSArray<TSOCRResult *> *)recognize:(UIImage *)image inRegion:(CGRect)region {
    return [self recognize:image inRegion:region languages:nil];
}

- (NSArray<TSOCRResult *> *)recognize:(UIImage *)image
                              inRegion:(CGRect)region
                              languages:(NSArray<NSString *> *)languages {
    if (!image) return @[];

    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return @[];

    CGFloat imgW = (CGFloat)CGImageGetWidth(cgImage);
    CGFloat imgH = (CGFloat)CGImageGetHeight(cgImage);

    // 裁剪区域（如果需要）
    CGImageRef subImage = cgImage;
    BOOL shouldReleaseSub = NO;
    if (!CGRectEqualToRect(region, CGRectMake(0, 0, imgW, imgH)) &&
        !CGRectIsEmpty(region)) {
        CGRect clamped = CGRectIntersection(region, CGRectMake(0, 0, imgW, imgH));
        if (CGRectIsEmpty(clamped)) return @[];
        subImage = CGImageCreateWithImageInRect(cgImage, clamped);
        shouldReleaseSub = YES;
    }

    // Vision 请求
    __block NSArray<TSOCRResult *> *results = @[];
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest * _Nonnull request, NSError * _Nullable error) {
        if (error) {
            dispatch_semaphore_signal(sema);
            return;
        }
        NSMutableArray<TSOCRResult *> *arr = [NSMutableArray array];

        for (VNRecognizedTextObservation *obs in request.results) {
            NSArray<VNRecognizedText *> *candidates = [obs topCandidates:1];
            if (candidates.count == 0) continue;

            VNRecognizedText *top = candidates.firstObject;
            TSOCRResult *r = [[TSOCRResult alloc] init];
            r.text = top.string;
            r.confidence = top.confidence;

            // Vision 返回的 boundingBox 是归一化坐标 (左下角原点)
            // 转换到 UIKit 坐标 (左上角原点)
            CGRect normBox = obs.boundingBox;
            r.rect = CGRectMake(
                normBox.origin.x * imgW,
                (1.0 - normBox.origin.y - normBox.size.height) * imgH,
                normBox.size.width * imgW,
                normBox.size.height * imgH
            );
            r.boundingBox = normBox;
            r.center = CGPointMake(CGRectGetMidX(r.rect), CGRectGetMidY(r.rect));

            [arr addObject:r];
        }

        // 按 y 坐标排序（从上到下）
        [arr sortUsingComparator:^NSComparisonResult(TSOCRResult *a, TSOCRResult *b) {
            if (a.center.y < b.center.y) return NSOrderedAscending;
            if (a.center.y > b.center.y) return NSOrderedDescending;
            if (a.center.x < b.center.x) return NSOrderedAscending;
            if (a.center.x > b.center.x) return NSOrderedDescending;
            return NSOrderedSame;
        }];

        results = arr;
        dispatch_semaphore_signal(sema);
    }];

    // 配置识别参数
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;  // 精确模式
    // 语言: 传入则用传入的, 否则用默认中英文
    if (languages.count > 0) {
        req.recognitionLanguages = languages;
    } else {
        req.recognitionLanguages = @[@"zh-Hans", @"zh-Hant", @"en-US"];
    }
    req.usesLanguageCorrection = YES;
    req.minimumTextHeight = 0.01;  // 最小识别文字高度(归一化)

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:subImage options:@{}];
    [handler performRequests:@[req] error:nil];

    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

    if (shouldReleaseSub) {
        CGImageRelease(subImage);
    }

    return results;
}

#pragma mark - 查找文字

- (nullable TSOCRResult *)findText:(NSString *)text inImage:(UIImage *)image {
    return [self findText:text inImage:image inRegion:CGRectZero];
}

- (nullable TSOCRResult *)findText:(NSString *)text inImage:(UIImage *)image inRegion:(CGRect)region {
    NSArray<TSOCRResult *> *results;
    if (CGRectIsEmpty(region)) {
        results = [self recognize:image];
    } else {
        results = [self recognize:image inRegion:region];
    }

    for (TSOCRResult *r in results) {
        if ([r.text containsString:text] ||
            [r.text localizedCaseInsensitiveContainsString:text]) {
            return r;
        }
    }
    return nil;
}

- (NSArray<TSOCRResult *> *)findAllText:(NSString *)text inImage:(UIImage *)image {
    NSArray<TSOCRResult *> *results = [self recognize:image];
    NSMutableArray<TSOCRResult *> *matches = [NSMutableArray array];
    for (TSOCRResult *r in results) {
        if ([r.text containsString:text] ||
            [r.text localizedCaseInsensitiveContainsString:text]) {
            [matches addObject:r];
        }
    }
    return matches;
}

#pragma mark - 查找并点击

- (BOOL)tapText:(NSString *)text inImage:(UIImage *)image {
    TSOCRResult *hit = [self findText:text inImage:image];
    if (!hit) {
        NSLog(@"[OCR] 未找到文字: %@", text);
        return NO;
    }

    CGFloat scale = image.scale;
    CGPoint pt = CGPointMake(hit.center.x / scale, hit.center.y / scale);
    NSLog(@"[OCR] 找到文字 \"%@\" 于 (%.0f, %.0f), 点击中...", text, pt.x, pt.y);
    [[TSHIDEventTouch shared] tapAtPoint:pt duration:0.05];
    return YES;
}

@end
