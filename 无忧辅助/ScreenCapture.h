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

/// 获取屏幕分辨率（像素），受 rotate 影响
- (CGSize)screenSize;

/// 获取指定像素点的颜色（坐标已应用 rotate）
- (ScreenColor)colorAtX:(int)x y:(int)y;

/// 在指定区域内查找颜色（坐标已应用 rotate），返回原图坐标
- (CGPoint)findColor:(ScreenColor)color
            tolerance:(int)tolerance
                   x1:(int)x1 y1:(int)y1
                   x2:(int)x2 y2:(int)y2;

/// 查找所有匹配坐标（坐标已应用 rotate）
- (NSArray<NSValue *> *)findAllColors:(ScreenColor)color
                            tolerance:(int)tolerance
                                   x1:(int)x1 y1:(int)y1
                                   x2:(int)x2 y2:(int)y2;

/// 旋转坐标系: 0=正常, 90/270=横屏, -90同270, 180=倒立
- (void)setRotation:(int)degrees;

/// 重置为默认坐标系
- (void)resetRotation;

/// 获取当前旋转角度
- (int)rotation;

/// 屏幕保持（缓存屏幕数据，后续取色不重新截图）
- (void)keepScreen;

/// 释放屏幕保持
- (void)releaseScreen;

/// 全屏截图保存到路径
- (BOOL)snapshotToPath:(NSString *)path;

/// 区域截图保存到路径
- (BOOL)snapshotToPath:(NSString *)path x:(int)x y:(int)y w:(int)w h:(int)h;

/// 屏幕捕获是否可用（已连接 IOMobileFramebuffer）
- (BOOL)isConnected;

/// 重新连接 IOMobileFramebuffer（后天切换后恢复取色）
- (void)reconnectScreen;

/// 屏幕取色是否存活（读取测试像素验证）
- (BOOL)isScreenAlive;

/// 诊断信息（供 UI 展示）
- (NSString *)diagnosticDescription;

/// 详细取色诊断：分别从 IOMFB 直连和 roothelper 读指定像素，返回对比结果
- (NSString *)testPixelAtX:(int)x y:(int)y;

@end

NS_ASSUME_NONNULL_END
