//
//  ScreenCapture.h
//  无忧辅助 - 屏幕截图与取色
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    int r, g, b;
} ScreenColor;

@interface ScreenCapture : NSObject

+ (instancetype)sharedInstance;

/// 获取屏幕分辨率（像素）
- (CGSize)screenSize;

/// 获取指定像素点的颜色
- (ScreenColor)colorAtX:(int)x y:(int)y;

/// 在指定区域内查找颜色（返回坐标，找不到返回 {-1, -1}）
- (CGPoint)findColor:(ScreenColor)color
            tolerance:(int)tolerance
                   x1:(int)x1 y1:(int)y1
                   x2:(int)x2 y2:(int)y2;

/// 查找所有匹配坐标
- (NSArray<NSValue *> *)findAllColors:(ScreenColor)color
                            tolerance:(int)tolerance
                                   x1:(int)x1 y1:(int)y1
                                   x2:(int)x2 y2:(int)y2;

/// 屏幕保持（缓存屏幕数据，后续取色不重新截图）
- (void)keepScreen;

/// 释放屏幕保持
- (void)releaseScreen;

/// 全屏截图保存到路径
- (BOOL)snapshotToPath:(NSString *)path;

/// 区域截图保存到路径
- (BOOL)snapshotToPath:(NSString *)path x:(int)x y:(int)y w:(int)w h:(int)h;

@end

NS_ASSUME_NONNULL_END
