//
//  ScreenCapture.m
//  无忧辅助 - IOMFB + CGDisplay 双模屏幕取色（运行时自动切换）
//

#import "ScreenCapture.h"
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <IOSurface/IOSurfaceRef.h>

// ============================================================
// CGDisplay — dlsym 动态加载
// ============================================================
static CGImageRef (*_cgCreate)(uint32_t) = NULL;
static uint32_t   (*_cgMain)(void) = NULL;

static void _cgLoad(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *paths[] = {
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
        };
        for (int i = 0; i < 2; i++) {
            void *h = dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
            if (h) {
                _cgCreate = (CGImageRef(*)(uint32_t))dlsym(h, "CGDisplayCreateImage");
                _cgMain   = (uint32_t(*)(void))   dlsym(h, "CGMainDisplayID");
                if (_cgCreate && _cgMain) return;
            }
        }
    });
}
static CGImageRef _cap(void) { _cgLoad(); return (_cgCreate&&_cgMain) ? _cgCreate(_cgMain()) : NULL; }

// 从 CGImage 取单像素 BGRA
static void _px(CGImageRef img, int x, int y, unsigned char *r, unsigned char *g, unsigned char *b) {
    *r=*g=*b=0; if(!img)return;
    CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB(); unsigned char p[4]={0};
    CGContextRef ctx=CGBitmapContextCreate(p,1,1,8,4,cs,kCGImageAlphaNoneSkipFirst|kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs); if(!ctx)return;
    CGContextDrawImage(ctx,CGRectMake(x,y,1,1),img); CGContextRelease(ctx);
    *b=p[0];*g=p[1];*r=p[2];
}

static CGPoint _findIn(CGImageRef img, ScreenColor t, int tol, int x1,int y1,int x2,int y2) {
    if(!img) return CGPointMake(-1,-1);
    size_t iw=CGImageGetWidth(img),ih=CGImageGetHeight(img);
    if(x1<0)x1=0;if(y1<0)y1=0;if(x2<=0||x2>(int)iw)x2=(int)iw;if(y2<=0||y2>(int)ih)y2=(int)ih;
    if(x1>=x2||y1>=y2) return CGPointMake(-1,-1);
    int rw=x2-x1,rh=y2-y1; size_t rb=(size_t)rw*4;
    unsigned char *buf=malloc((size_t)rh*rb); if(!buf) return CGPointMake(-1,-1);
    CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx=CGBitmapContextCreate(buf,rw,rh,8,rb,cs,kCGImageAlphaNoneSkipFirst|kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs); if(!ctx){free(buf);return CGPointMake(-1,-1);}
    CGContextDrawImage(ctx,CGRectMake(-x1,-y1,iw,ih),img);CGContextRelease(ctx);
    for(int row=0;row<rh;row++){unsigned char*ln=buf+row*rb;for(int col=0;col<rw;col++){int b=ln[col*4],g=ln[col*4+1],r=ln[col*4+2];
    if(abs(r-t.r)<=tol&&abs(g-t.g)<=tol&&abs(b-t.b)<=tol){free(buf);return CGPointMake(x1+col,y1+row);}}}
    free(buf);return CGPointMake(-1,-1);
}

// ============================================================
// IOMobileFramebuffer
// ============================================================
typedef struct __IOMobileFramebuffer *IMFBRef;
extern kern_return_t IOMobileFramebufferGetMainDisplay(IMFBRef *);
extern kern_return_t IOMobileFramebufferGetLayerDefaultSurface(IMFBRef,int,IOSurfaceRef*);

@implementation ScreenCapture {
    IMFBRef _fb; IOSurfaceRef _sf;
    int _bpr,_w,_h; BOOL _fbOK;
    int _rot; NSString *_diag;
    BOOL _keep; unsigned char *_buf; size_t _bufSz;
}

+ (instancetype)sharedInstance { static ScreenCapture *i;static dispatch_once_t t;dispatch_once(&t,^{i=[[ScreenCapture alloc]init];});return i;}

- (instancetype)init {
    if(self=[super init]){_fbOK=NO;_w=_h=0;_rot=0;_diag=@"(初始化中...)";[self _con];}return self;
}
- (void)dealloc{[self releaseScreen];[self _dis];}

// ---- FB 连接 ----
- (void)_con {
    if(_fbOK)return;
    if(!IOMobileFramebufferGetMainDisplay||!IOMobileFramebufferGetLayerDefaultSurface){_diag=@"IOMFB 符号缺失";_w=0;_h=0;return;}
    if(IOMobileFramebufferGetMainDisplay(&_fb)!=KERN_SUCCESS||!_fb){_diag=@"GetMainDisplay 失败";return;}
    for(int l=0;l<=2;l++){
        if(IOMobileFramebufferGetLayerDefaultSurface(_fb,l,&_sf)==KERN_SUCCESS&&_sf){_w=(int)IOSurfaceGetWidth(_sf);_h=(int)IOSurfaceGetHeight(_sf);
        if(_w>0&&_h>0){_bpr=(int)IOSurfaceGetBytesPerRow(_sf);_fbOK=YES;_diag=[NSString stringWithFormat:@"IOMFB %dx%d bpr=%d (L%d)",_w,_h,_bpr,l];return;}
        CFRelease(_sf);_sf=NULL;}}
    _diag=@"无有效 Surface";
}
- (void)_dis { if(_sf){CFRelease(_sf);_sf=NULL;} _fb=NULL; _fbOK=NO; }

// ---- 诊断 ----
- (BOOL)isConnected{return _fbOK;}
- (NSString*)diagnosticDescription{return [NSString stringWithFormat:@"屏幕捕获: %@\n安装方式: %@\n分辨率: %dx%d\n取色可用: %@\n",
    _diag,(access("/var/mobile/Library",F_OK)==0?@"✅ TrollStore":@"❌ 沙盒内"),_w,_h,_fbOK?@"✅ 是":@"❌ 否"];}

- (CGSize)screenSize{return (_rot==90||_rot==270)?CGSizeMake(_h,_w):CGSizeMake(_w,_h);}

// ============================================================
// 核心取色：IOMFB → 若全0 → CGDisplay
// ============================================================
- (ScreenColor)colorAtX:(int)x y:(int)y {
    ScreenColor c={0,0,0}; [self _tx:&x y:&y]; if(x<0||y<0)return c;
    unsigned char r=0,g=0,b=0;

    // 尝试 IOMFB
    if(_fbOK&&_sf&&x>=0&&x<_w&&y>=0&&y<_h){
        if(_keep&&_buf){int off=y*_bpr+x*4;b=_buf[off];g=_buf[off+1];r=_buf[off+2];}
        else{if(IOSurfaceLock(_sf,kIOSurfaceLockReadOnly,NULL)==KERN_SUCCESS){void*base=IOSurfaceGetBaseAddress(_sf);
            if(base){int off=y*_bpr+x*4;unsigned char*p=(unsigned char*)base+off;b=p[0];g=p[1];r=p[2];}
            IOSurfaceUnlock(_sf,kIOSurfaceLockReadOnly,NULL);}}
        c.r=r;c.g=g;c.b=b;
        if(r||g||b) return c; // 非全0说明获取到了真实像素
    }

    // 回退 CGDisplay
    CGImageRef img=_cap(); if(!img) return c;
    if(x>=0&&y>=0&&x<(int)CGImageGetWidth(img)&&y<(int)CGImageGetHeight(img)) _px(img,x,y,&r,&g,&b);
    CGImageRelease(img);
    c.r=r;c.g=g;c.b=b; return c;
}

// ---- 找色 ----
- (CGPoint)findColor:(ScreenColor)c tolerance:(int)tol x1:(int)x1 y1:(int)y1 x2:(int)x2 y2:(int)y2 {
    [self _tx:&x1 y:&y1];[self _tx:&x2 y:&y2]; if(x1>x2){int t=x1;x1=x2;x2=t;} if(y1>y2){int t=y1;y1=y2;y2=t;}

    // IOMFB
    if(_fbOK){
        if(x1<0)x1=0;if(y1<0)y1=0;if(x2<=0||x2>_w)x2=_w;if(y2<=0||y2>_h)y2=_h;
        if(x1<x2&&y1<y2){
            if(_keep&&_buf){
                for(int ry=y1;ry<y2;ry++){unsigned char*row=_buf+ry*_bpr;
                    for(int rx=x1;rx<x2;rx++){int idx=rx*4;
                    if(abs(row[idx+2]-c.r)<=tol&&abs(row[idx+1]-c.g)<=tol&&abs(row[idx]-c.b)<=tol)
                    {int ox=rx,oy=ry;[self _itx:&ox y:&oy];return CGPointMake(ox,oy);}}}
            }else if(IOSurfaceLock(_sf,kIOSurfaceLockReadOnly,NULL)==KERN_SUCCESS){
                void*base=IOSurfaceGetBaseAddress(_sf);
                if(base){for(int ry=y1;ry<y2;ry++){unsigned char*row=(unsigned char*)base+ry*_bpr;
                    for(int rx=x1;rx<x2;rx++){int idx=rx*4;
                    if(abs(row[idx+2]-c.r)<=tol&&abs(row[idx+1]-c.g)<=tol&&abs(row[idx]-c.b)<=tol)
                    {int ox=rx,oy=ry;[self _itx:&ox y:&oy];IOSurfaceUnlock(_sf,kIOSurfaceLockReadOnly,NULL);return CGPointMake(ox,oy);}}}}
                IOSurfaceUnlock(_sf,kIOSurfaceLockReadOnly,NULL);
            }
        }
    }

    // CGDisplay 回退
    CGImageRef img=_cap(); if(!img)return CGPointMake(-1,-1);
    CGPoint p=_findIn(img,c,tol,x1>=0?x1:0,y1>=0?y1:0,x2>0?x2:(int)CGImageGetWidth(img),y2>0?y2:(int)CGImageGetHeight(img));
    CGImageRelease(img);
    if(p.x>=0){int rx=(int)p.x,ry=(int)p.y;[self _itx:&rx y:&ry];return CGPointMake(rx,ry);}
    return CGPointMake(-1,-1);
}

// ---- 旋转 ----
- (void)setRotation:(int)d { int v=d%360;if(v<0)v+=360;if(v%90)v=0; _rot=v; }
- (void)resetRotation {_rot=0;}
- (int)rotation{return _rot;}
- (void)_tx:(int*)x y:(int*)y{if(!_rot)return;int rx=*x,ry=*y,w1=_w-1,h1=_h-1;switch(_rot){case 90:*x=w1-ry;*y=rx;break;case 180:*x=w1-rx;*y=h1-ry;break;case 270:*x=ry;*y=h1-rx;break;}}
- (void)_itx:(int*)x y:(int*)y{if(!_rot)return;int ox=*x,oy=*y,w1=_w-1,h1=_h-1;switch(_rot){case 90:*x=oy;*y=w1-ox;break;case 180:*x=w1-ox;*y=h1-oy;break;case 270:*x=h1-oy;*y=ox;break;}}

- (void)keepScreen{if(!_keep){[self colorAtX:0 y:0];_keep=YES;}}
- (void)releaseScreen{_keep=NO;free(_buf);_buf=NULL;_bufSz=0;}
- (NSArray*)findAllColors:(ScreenColor)c tolerance:(int)t x1:(int)x1 y1:(int)y1 x2:(int)x2 y2:(int)y2{NSMutableArray*a=[NSMutableArray array];while(1){CGPoint p=[self findColor:c tolerance:t x1:x1 y1:y1 x2:x2 y2:y2];if(p.x<0)break;[a addObject:[NSValue valueWithCGPoint:p]];x1=(int)p.x+1;if(x1>=x2)break;}return a;}
- (BOOL)snapshotToPath:(NSString*)p{return NO;}-(BOOL)snapshotToPath:(NSString*)p x:(int)x y:(int)y w:(int)w h:(int)h{return NO;}
@end
