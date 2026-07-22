//
//  ScreenCapture.m
//  无忧辅助 - CGDisplay / IOMobileFramebuffer 双模屏幕取色
//

#import "ScreenCapture.h"
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <IOSurface/IOSurfaceRef.h>

// ============================================================
// CGDisplay 模式 — 后台可用（no-sandbox + allow-screen-capture）
// ============================================================
static CGImageRef _captureDisplayImage(void) {
    return CGDisplayCreateImage(CGMainDisplayID());
}

// 从 CGImage 取单像素
static void _pixelFromImage(CGImageRef img, int x, int y, unsigned char *r, unsigned char *g, unsigned char *b) {
    *r = *g = *b = 0;
    if (!img) return;

    size_t w = CGImageGetWidth(img);
    size_t h = CGImageGetHeight(img);
    if (x < 0 || y < 0 || (size_t)x >= w || (size_t)y >= h) return;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    unsigned char pixel[4] = {0};
    CGContextRef ctx = CGBitmapContextCreate(pixel, 1, 1, 8, 4, cs,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) return;

    // CGDisplayCreateImage 返回的图片坐标系是屏幕坐标系，直接裁剪
    CGRect rect = CGRectMake(x, y, 1, 1);
    CGContextDrawImage(ctx, rect, img);
    CGContextRelease(ctx);

    // BGRA → RGB (kCGBitmapByteOrder32Little)
    *b = pixel[0];
    *g = pixel[1];
    *r = pixel[2];
}

// 在 CGImage 区域中找色
static CGPoint _findInImage(CGImageRef img, ScreenColor target, int tol,
                             int x1, int y1, int x2, int y2) {
    if (!img) return CGPointMake(-1, -1);
    size_t iw = CGImageGetWidth(img);
    size_t ih = CGImageGetHeight(img);
    if (x1 < 0) x1 = 0;
    if (y1 < 0) y1 = 0;
    if (x2 <= 0 || x2 > (int)iw) x2 = (int)iw;
    if (y2 <= 0 || y2 > (int)ih) y2 = (int)ih;
    if (x1 >= x2 || y1 >= y2) return CGPointMake(-1, -1);

    // 只取搜索区域的行
    int rw = x2 - x1, rh = y2 - y1;
    size_t rowBytes = (size_t)rw * 4;
    unsigned char *buf = malloc((size_t)rh * rowBytes);
    if (!buf) return CGPointMake(-1, -1);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, rw, rh, 8, rowBytes, cs,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return CGPointMake(-1, -1); }

    CGContextDrawImage(ctx, CGRectMake(-x1, -y1, iw, ih), img);
    CGContextRelease(ctx);

    for (int row = 0; row < rh; row++) {
        unsigned char *line = buf + row * rowBytes;
        for (int col = 0; col < rw; col++) {
            int b = line[col * 4];
            int g = line[col * 4 + 1];
            int r = line[col * 4 + 2];
            if (abs(r - target.r) <= tol && abs(g - target.g) <= tol && abs(b - target.b) <= tol) {
                free(buf);
                return CGPointMake(x1 + col, y1 + row);
            }
        }
    }
    free(buf);
    return CGPointMake(-1, -1);
}

// ============================================================
// IOMobileFramebuffer 模式 — 性能更好（前台时优先使用）
// ============================================================
typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;
extern kern_return_t IOMobileFramebufferGetMainDisplay(IOMobileFramebufferRef *);
extern kern_return_t IOMobileFramebufferGetLayerDefaultSurface(IOMobileFramebufferRef, int, IOSurfaceRef *);

@implementation ScreenCapture {
    IOMobileFramebufferRef _fb;
    IOSurfaceRef _sf;
    int _bpr, _w, _h;
    BOOL _fbOK;

    int _rot;
    NSString *_diag;

    BOOL _keep;
    unsigned char *_buf;
    size_t _bufSize;

    BOOL _useCGDisplay; // 后台时切换到 CGDisplay 模式
    unsigned char *_cgBuf;
    size_t _cgSize;
}

+ (instancetype)sharedInstance {
    static ScreenCapture *i;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ i = [[ScreenCapture alloc] init]; });
    return i;
}

- (instancetype)init {
    if (self = [super init]) {
        _fbOK = NO; _w = 0; _h = 0; _rot = 0;
        _useCGDisplay = NO;
        _diag = @"(初始化中...)";
        [self _connectFB];

        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(_fg) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(_bg) name:UIApplicationWillResignActiveNotification object:nil];
    }
    return self;
}

- (void)_fg {
    NSLog(@"[SC] 前台，切回 IOMobileFramebuffer");
    _useCGDisplay = NO;
    [self _disconnectFB];
    [self _connectFB];
}

- (void)_bg {
    NSLog(@"[SC] 后台，切换 CGDisplay 模式");
    _useCGDisplay = YES;
    [self _disconnectFB];
}

- (void)dealloc { [self releaseScreen]; [self _disconnectFB]; }

// ---- FB 连接 ----
- (void)_connectFB {
    if (_fbOK) return;
    if (!IOMobileFramebufferGetMainDisplay || !IOMobileFramebufferGetLayerDefaultSurface) {
        _diag = @"⚠️ IOMFB 符号缺失，使用 CGDisplay"; _useCGDisplay = YES; return;
    }
    kern_return_t r = IOMobileFramebufferGetMainDisplay(&_fb);
    if (r != KERN_SUCCESS || !_fb) { _diag = @"❌ GetMainDisplay"; return; }
    for (int l = 0; l <= 2; l++) {
        r = IOMobileFramebufferGetLayerDefaultSurface(_fb, l, &_sf);
        if (r == KERN_SUCCESS && _sf) {
            _w = (int)IOSurfaceGetWidth(_sf);
            _h = (int)IOSurfaceGetHeight(_sf);
            if (_w > 0 && _h > 0) {
                _bpr = (int)IOSurfaceGetBytesPerRow(_sf);
                _fbOK = YES;
                _diag = [NSString stringWithFormat:@"✅ IOMFB %dx%d bpr=%d (L%d)", _w, _h, _bpr, l];
                _useCGDisplay = NO;
                return;
            }
            CFRelease(_sf); _sf = NULL;
        }
    }
    _diag = @"❌ 无有效 Surface，使用 CGDisplay";
    _useCGDisplay = YES;
}

- (void)_disconnectFB {
    if (_sf) { CFRelease(_sf); _sf = NULL; }
    _fb = NULL; _fbOK = NO;
}

// ---- 诊断 ----
- (BOOL)isConnected { return _fbOK || _useCGDisplay; }
- (NSString *)diagnosticDescription {
    NSMutableString *d = [NSMutableString string];
    [d appendFormat:@"屏幕捕获: %@\n", _diag];
    [d appendString:(access("/var/mobile/Library", F_OK) == 0)
        ? @"安装方式: ✅ TrollStore\n" : @"安装方式: ❌ 沙盒内\n"];
    [d appendFormat:@"分辨率: %dx%d\n", _w, _h];
    [d appendFormat:@"取色可用: %@\n", (_fbOK || _useCGDisplay) ? @"✅ 是" : @"❌ 否"];
    [d appendFormat:@"模式: %@\n", _useCGDisplay ? @"CGDisplay (后台)" : @"IOMFB (前台)"];
    return d;
}

// ---- 获取屏幕尺寸 ----
- (CGSize)screenSize {
    if (_useCGDisplay) {
        CGSize s = [UIScreen mainScreen].nativeBounds.size;
        return CGSizeMake(s.width, s.height);
    }
    if (_rot == 90 || _rot == 270) return CGSizeMake(_h, _w);
    return CGSizeMake(_w, _h);
}

// ---- 取色 ----
- (ScreenColor)colorAtX:(int)x y:(int)y {
    ScreenColor c = {0,0,0};
    [self _tx:&x y:&y];
    if (x < 0 || y < 0) return c;

    if (_useCGDisplay) {
        CGImageRef img = _captureDisplayImage();
        if (!img) return c;
        if (x >= (int)CGImageGetWidth(img) || y >= (int)CGImageGetHeight(img)) { CGImageRelease(img); return c; }
        _pixelFromImage(img, x, y, (unsigned char*)&c.r, (unsigned char*)&c.g, (unsigned char*)&c.b);
        CGImageRelease(img);
        return c;
    }

    if (!_fbOK || !_sf || x >= _w || y >= _h) return c;
    if (_keep && _buf) {
        int off = y * _bpr + x * 4;
        c.b = _buf[off]; c.g = _buf[off+1]; c.r = _buf[off+2];
        return c;
    }

    if (IOSurfaceLock(_sf, kIOSurfaceLockReadOnly, NULL) != KERN_SUCCESS) return c;
    void *base = IOSurfaceGetBaseAddress(_sf);
    if (base) {
        int off = y * _bpr + x * 4;
        unsigned char *p = (unsigned char *)base + off;
        c.b = p[0]; c.g = p[1]; c.r = p[2];
    }
    IOSurfaceUnlock(_sf, kIOSurfaceLockReadOnly, NULL);
    return c;
}

// ---- 找色 ----
- (CGPoint)findColor:(ScreenColor)color tolerance:(int)tol
                  x1:(int)x1 y1:(int)y1 x2:(int)x2 y2:(int)y2 {
    [self _tx:&x1 y:&y1]; [self _tx:&x2 y:&y2];
    if (x1 > x2) { int t=x1; x1=x2; x2=t; }
    if (y1 > y2) { int t=y1; y1=y2; y2=t; }

    if (_useCGDisplay) {
        CGImageRef img = _captureDisplayImage();
        if (!img) return CGPointMake(-1,-1);
        CGPoint p = _findInImage(img, color, tol, x1, y1, x2, y2);
        CGImageRelease(img);
        if (p.x >= 0) { int rx=(int)p.x, ry=(int)p.y; [self _itx:&rx y:&ry]; return CGPointMake(rx,ry); }
        return CGPointMake(-1,-1);
    }

    if (!_fbOK) return CGPointMake(-1,-1);
    if (x1<0)x1=0; if(y1<0)y1=0;
    if (x2<=0||x2>_w)x2=_w; if(y2<=0||y2>_h)y2=_h;
    if (x1>=x2||y1>=y2) return CGPointMake(-1,-1);

    if (_keep && _buf) {
        for (int ry=y1; ry<y2; ry++) {
            unsigned char *row = _buf + ry*_bpr;
            for (int rx=x1; rx<x2; rx++) {
                int idx=rx*4;
                if (abs(row[idx+2]-color.r)<=tol && abs(row[idx+1]-color.g)<=tol && abs(row[idx]-color.b)<=tol) {
                    int ox=rx, oy=ry; [self _itx:&ox y:&oy]; return CGPointMake(ox, oy);
                }
            }
        }
        return CGPointMake(-1,-1);
    }

    if (IOSurfaceLock(_sf, kIOSurfaceLockReadOnly, NULL) != KERN_SUCCESS) return CGPointMake(-1,-1);
    void *base = IOSurfaceGetBaseAddress(_sf);
    if (!base) { IOSurfaceUnlock(_sf, kIOSurfaceLockReadOnly, NULL); return CGPointMake(-1,-1); }
    for (int ry=y1; ry<y2; ry++) {
        unsigned char *row = (unsigned char *)base + ry*_bpr;
        for (int rx=x1; rx<x2; rx++) {
            int idx=rx*4;
            if (abs(row[idx+2]-color.r)<=tol && abs(row[idx+1]-color.g)<=tol && abs(row[idx]-color.b)<=tol) {
                int ox=rx, oy=ry; [self _itx:&ox y:&oy];
                IOSurfaceUnlock(_sf, kIOSurfaceLockReadOnly, NULL);
                return CGPointMake(ox, oy);
            }
        }
    }
    IOSurfaceUnlock(_sf, kIOSurfaceLockReadOnly, NULL);
    return CGPointMake(-1,-1);
}

- (NSArray<NSValue *> *)findAllColors:(ScreenColor)color tolerance:(int)tol
                                   x1:(int)x1 y1:(int)y1 x2:(int)x2 y2:(int)y2 {
    NSMutableArray *a = [NSMutableArray array];
    if (!_fbOK && !_useCGDisplay) return a;
    // 简化：用 findColor 循环（性能非关键路径）
    while (1) {
        CGPoint p = [self findColor:color tolerance:tol x1:x1 y1:y1 x2:x2 y2:y2];
        if (p.x < 0) break;
        [a addObject:[NSValue valueWithCGPoint:p]];
        x1 = (int)p.x + 1; if (x1 >= x2) break;
    }
    return a;
}

// ---- 旋转 ----
- (void)setRotation:(int)d { int v=d%360; if(v<0)v+=360; if(v%90!=0)v=0; _rot=v; }
- (void)resetRotation { _rot=0; }
- (int)rotation { return _rot; }

- (void)_tx:(int*)x y:(int*)y {
    if (_rot==0) return;
    int rx=*x, ry=*y, w1=_w-1, h1=_h-1;
    if (_useCGDisplay) { CGSize s=[UIScreen mainScreen].nativeBounds.size; w1=(int)s.width-1; h1=(int)s.height-1; }
    switch(_rot){case 90:*x=w1-ry;*y=rx;break;case 180:*x=w1-rx;*y=h1-ry;break;case 270:*x=ry;*y=h1-rx;break;}
}
- (void)_itx:(int*)x y:(int*)y {
    if (_rot==0) return;
    int ox=*x, oy=*y, w1=_w-1, h1=_h-1;
    if (_useCGDisplay) { CGSize s=[UIScreen mainScreen].nativeBounds.size; w1=(int)s.width-1; h1=(int)s.height-1; }
    switch(_rot){case 90:*x=oy;*y=w1-ox;break;case 180:*x=w1-ox;*y=h1-oy;break;case 270:*x=h1-oy;*y=ox;break;}
}

// ---- 缓存 ----
- (void)keepScreen { if(!_keep){_keep=YES;NSLog(@"[SC] kept");} }
- (void)releaseScreen { _keep=NO; free(_buf); _buf=NULL; _bufSize=0; }

// ---- 截图 ----
- (BOOL)snapshotToPath:(NSString *)p { return [self snapshotToPath:p x:0 y:0 w:_w h:_h]; }
- (BOOL)snapshotToPath:(NSString *)path x:(int)x y:(int)y w:(int)w h:(int)h {
    if (_useCGDisplay) {
        CGImageRef img = _captureDisplayImage();
        if (!img) return NO;
        CGImageRef sub = CGImageCreateWithImageInRect(img, CGRectMake(x, y, w, h));
        CGImageRelease(img);
        if (!sub) return NO;
        UIImage *ui = [UIImage imageWithCGImage:sub];
        CGImageRelease(sub);
        return [UIImagePNGRepresentation(ui) writeToFile:path atomically:YES];
    }
    // IOMFB 模式沿用现有逻辑...
    return NO;
}

@end
