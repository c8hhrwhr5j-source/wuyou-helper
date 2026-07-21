/**
 *  ScreenCapture.m
 *  全屏截图 + 像素取色 + 区域找色 实现
 *
 *  技术路线: IOMobileFramebuffer → IOSurface → 直接读 BGRA 像素
 *  完全内存操作，不弹窗、不保存文件、无 IO 开销
 */

#import "ScreenCapture.h"
#import <UIKit/UIKit.h>
#import <IOSurface/IOSurface.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>

// ---- IOMobileFramebuffer 私有声明 ----
typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;

extern kern_return_t IOMobileFramebufferGetMainDisplay(IOMobileFramebufferRef *fb);
extern kern_return_t IOMobileFramebufferGetLayerDefaultSurface(
    IOMobileFramebufferRef fb, int layer, IOSurfaceRef *surface);

@interface ScreenCapture () {
    IOMobileFramebufferRef _framebuffer;
    IOSurfaceRef _surface;
    const uint8_t *_pixelData;       // 当前锁定的像素数据
    int _width, _height, _bytesPerRow;
    BOOL _isLocked;
}
@end

@implementation ScreenCapture

+ (instancetype)shared {
    static ScreenCapture *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[ScreenCapture alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _framebuffer = NULL;
        _surface = NULL;
        _pixelData = NULL;
        _isLocked = NO;
    }
    return self;
}

- (void)dealloc {
    [self releaseCapture];
}

#pragma mark - 截图核心

- (void)refreshCapture {
    [self releaseCapture];

    kern_return_t kr = IOMobileFramebufferGetMainDisplay(&_framebuffer);
    if (kr != KERN_SUCCESS || !_framebuffer) {
        NSLog(@"[触控精灵] IOMobileFramebufferGetMainDisplay 失败: 0x%x", kr);
        return;
    }

    kr = IOMobileFramebufferGetLayerDefaultSurface(_framebuffer, 0, &_surface);
    if (kr != KERN_SUCCESS || !_surface) {
        NSLog(@"[触控精灵] GetLayerDefaultSurface 失败: 0x%x", kr);
        return;
    }

    kr = IOSurfaceLock(_surface, kIOSurfaceLockReadOnly, NULL);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[触控精灵] IOSurfaceLock 失败: 0x%x", kr);
        CFRelease(_surface);
        _surface = NULL;
        return;
    }
    _isLocked = YES;

    _pixelData = (const uint8_t *)IOSurfaceGetBaseAddress(_surface);
    _width = (int)IOSurfaceGetWidth(_surface);
    _height = (int)IOSurfaceGetHeight(_surface);
    _bytesPerRow = (int)IOSurfaceGetBytesPerRow(_surface);
}

- (const uint8_t *)captureScreenWithWidth:(int *)outWidth
                                   height:(int *)outHeight
                               bytesPerRow:(int *)outBytesPerRow
{
    if (!_pixelData) {
        [self refreshCapture];
    }
    if (_pixelData) {
        if (outWidth) *outWidth = _width;
        if (outHeight) *outHeight = _height;
        if (outBytesPerRow) *outBytesPerRow = _bytesPerRow;
    }
    return _pixelData;
}

- (void)releaseCapture {
    if (_isLocked && _surface) {
        IOSurfaceUnlock(_surface, kIOSurfaceLockReadOnly, NULL);
        _isLocked = NO;
    }
    if (_surface) {
        CFRelease(_surface);
        _surface = NULL;
    }
    _pixelData = NULL;
    _width = _height = _bytesPerRow = 0;
}

#pragma mark - 单点取色

- (BOOL)getColorAtX:(int)x y:(int)y red:(uint8_t *)r green:(uint8_t *)g blue:(uint8_t *)b {
    if (!_pixelData) return NO;
    if (x < 0 || x >= _width || y < 0 || y >= _height) return NO;

    // BGRA 像素格式: [B][G][R][A]
    const uint8_t *pixel = _pixelData + y * _bytesPerRow + x * 4;
    if (b) *b = pixel[0];
    if (g) *g = pixel[1];
    if (r) *r = pixel[2];
    return YES;
}

#pragma mark - 区域找色

- (BOOL)findColorInRect:(CGRect)rect
              targetRed:(uint8_t)tr
            targetGreen:(uint8_t)tg
             targetBlue:(uint8_t)tb
             similarity:(int)similarity
                   outX:(int *)outX
                   outY:(int *)outY
{
    if (!_pixelData) {
        if (outX) *outX = -1;
        if (outY) *outY = -1;
        return NO;
    }

    // 裁剪到屏幕范围
    int x1 = MAX(0, (int)rect.origin.x);
    int y1 = MAX(0, (int)rect.origin.y);
    int x2 = MIN(_width,  (int)(rect.origin.x + rect.size.width));
    int y2 = MIN(_height, (int)(rect.origin.y + rect.size.height));

    if (x1 >= x2 || y1 >= y2) {
        if (outX) *outX = -1;
        if (outY) *outY = -1;
        return NO;
    }

    // 相似度阈值: similarity=100 → maxDiff=0, similarity=90 → maxDiff=25
    int maxDiff = (int)((100.0f - similarity) / 100.0f * 255.0f);

    for (int y = y1; y < y2; y++) {
        const uint8_t *row = _pixelData + y * _bytesPerRow;
        for (int x = x1; x < x2; x++) {
            int idx = x * 4;
            int b = row[idx];
            int g = row[idx + 1];
            int r = row[idx + 2];

            if (abs(r - tr) <= maxDiff &&
                abs(g - tg) <= maxDiff &&
                abs(b - tb) <= maxDiff)
            {
                if (outX) *outX = x;
                if (outY) *outY = y;
                return YES;
            }
        }
    }

    if (outX) *outX = -1;
    if (outY) *outY = -1;
    return NO;
}

- (CGSize)screenSize {
    if (_pixelData) {
        return CGSizeMake(_width, _height);
    }
    return [UIScreen mainScreen].nativeBounds.size;
}

@end
