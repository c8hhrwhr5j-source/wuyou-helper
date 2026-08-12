//
//  TSTouchSimulator.m
//  TrollAutoTouch
//

#import "TSTouchSimulator.h"
#import "TSScreenCapture.h"
#import "TSColorFinder.h"
#import "TSHIDEventTouch.h"

@implementation TSTouchSimulator

+ (instancetype)shared {
    static TSTouchSimulator *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [TSTouchSimulator new]; });
    return instance;
}

- (BOOL)capture:(uint8_t **)pixels width:(int *)w height:(int *)h {
    return [[TSScreenCapture shared] captureScreenToRGBA:pixels width:w height:h];
}

- (void)tapAt:(CGPoint)point {
    [[TSHIDEventTouch shared] tapAtPoint:point duration:0.05];
}

- (void)swipeFrom:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)d {
    [[TSHIDEventTouch shared] swipeFromPoint:from toPoint:to duration:d steps:(NSInteger)(d * 60)];
}

- (BOOL)tapColor:(int)color sim:(CGFloat)sim
        offsetX:(CGFloat)offsetX offsetY:(CGFloat)offsetY {
    return [self tapColor:color sim:sim rect:CGRectZero offsetX:offsetX offsetY:offsetY];
}

- (BOOL)tapColor:(int)color sim:(CGFloat)sim
            rect:(CGRect)rect
        offsetX:(CGFloat)offsetX offsetY:(CGFloat)offsetY {
    uint8_t *pixels = NULL;
    int w = 0, h = 0;
    if (![self capture:&pixels width:&w height:&h] || !pixels) { return NO; }

    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    TSColorResult *r = [TSColorFinder findColor:color
                                            rect:rect
                                             sim:sim
                                          pixels:pixels
                                           width:w height:h
                                      screenSize:screenSize];
    free(pixels);
    if (!r) { return NO; }
    CGPoint tap = CGPointMake(r.point.x + offsetX, r.point.y + offsetY);
    [self tapAt:tap];
    return YES;
}

- (BOOL)tapMultiColor:(int)mainColor
                 rect:(CGRect)rect
          mainColorSim:(CGFloat)sim
               offsets:(NSArray<NSDictionary *> *)offsets
             offsetSim:(CGFloat)offsetSim
               offsetX:(CGFloat)offsetX offsetY:(CGFloat)offsetY {
    uint8_t *pixels = NULL;
    int w = 0, h = 0;
    if (![self capture:&pixels width:&w height:&h] || !pixels) { return NO; }

    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    TSColorResult *r = [TSColorFinder findMultiColor:mainColor
                                                 rect:rect
                                          mainColorSim:sim
                                               offsets:offsets
                                             offsetSim:offsetSim
                                                 pixels:pixels
                                                  width:w height:h
                                             screenSize:screenSize];
    free(pixels);
    if (!r) { return NO; }
    CGPoint tap = CGPointMake(r.point.x + offsetX, r.point.y + offsetY);
    [self tapAt:tap];
    return YES;
}

@end
