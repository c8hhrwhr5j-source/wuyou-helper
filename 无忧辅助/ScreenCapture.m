//
//  ScreenCapture.m
//  无忧辅助 - 三重取色策略（IOMFB → _UICreateScreenUIImage → IOSurface）
//

#import "ScreenCapture.h"
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <IOSurface/IOSurfaceRef.h>

// ============================================================
// _UICreateScreenUIImage — iOS 系统截图 API（后台可用）
// ============================================================
static UIImage *(*_uiScreenImage)(void) = NULL;

static void _loadUIScreenImage(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _uiScreenImage = (UIImage*(*)(void))dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
        if (!_uiScreenImage) {
            void *h = dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore", RTLD_NOW);
            if (h) _uiScreenImage = (UIImage*(*)(void))dlsym(h, "_UICreateScreenUIImage");
        }
        if (_uiScreenImage) NSLog(@"[SC] ✅ _UICreateScreenUIImage 已加载");
    });
}

static UIImage *_screenShot(void) { _loadUIScreenImage(); return _uiScreenImage ? _uiScreenImage() : nil; }

// ============================================================
// IOMobileFramebuffer
// ============================================================
typedef struct __IOMobileFramebuffer *IMFBRef;
extern kern_return_t IOMobileFramebufferGetMainDisplay(IMFBRef *);
extern kern_return_t IOMobileFramebufferGetLayerDefaultSurface(IMFBRef,int,IOSurfaceRef*);

@implementation ScreenCapture {
    IMFBRef _fb; IOSurfaceRef _sf;
    int _bpr,_w,_h; BOOL _fbOK;
    int _rot;
    BOOL _keep; unsigned char *_cbuf; size_t _csz;
}

+ (instancetype)sharedInstance { static ScreenCapture *i;static dispatch_once_t t;dispatch_once(&t,^{i=[[ScreenCapture alloc]init];});return i;}

- (instancetype)init {
    if(self=[super init]){_fbOK=NO;_w=_h=0;_rot=0;[self _con];}return self;
}
- (void)dealloc{[self releaseScreen];[self _dis];}

- (void)_con {
    if(_fbOK)return;
    if(!IOMobileFramebufferGetMainDisplay||!IOMobileFramebufferGetLayerDefaultSurface)return;
    if(IOMobileFramebufferGetMainDisplay(&_fb)!=KERN_SUCCESS||!_fb)return;
    for(int l=0;l<=2;l++){
        if(IOMobileFramebufferGetLayerDefaultSurface(_fb,l,&_sf)==KERN_SUCCESS&&_sf){_w=(int)IOSurfaceGetWidth(_sf);_h=(int)IOSurfaceGetHeight(_sf);
        if(_w>0&&_h>0){_bpr=(int)IOSurfaceGetBytesPerRow(_sf);_fbOK=YES;return;}
        CFRelease(_sf);_sf=NULL;}}
}
- (void)_dis { if(_sf){CFRelease(_sf);_sf=NULL;} _fb=NULL; _fbOK=NO; }

- (BOOL)isConnected{return _fbOK;}
- (NSString*)diagnosticDescription{
    return [NSString stringWithFormat:@"屏幕捕获: %@\n安装方式: %@\n分辨率: %dx%d\n取色可用: %@\n",
        _fbOK?[NSString stringWithFormat:@"IOMFB %dx%d bpr=%d",_w,_h,_bpr]:@"未连接",
        access("/var/mobile/Library",F_OK)==0?@"✅ TrollStore":@"❌ 沙盒内",
        _w,_h,_fbOK?@"✅ 是":@"❌ 否"];
}

- (CGSize)screenSize{return (_rot==90||_rot==270)?CGSizeMake(_h,_w):CGSizeMake(_w,_h);}

// ============================================================
// 核心：IOMFB → 全0则 _UICreateScreenUIImage
// ============================================================
- (ScreenColor)colorAtX:(int)x y:(int)y {
    ScreenColor c={0,0,0}; [self _tx:&x y:&y]; if(x<0||y<0)return c;
    unsigned char r=0,g=0,b=0;

    // IOMFB
    if(_fbOK&&_sf&&x>=0&&x<_w&&y>=0&&y<_h){
        if(_keep&&_cbuf){int off=y*_bpr+x*4;b=_cbuf[off];g=_cbuf[off+1];r=_cbuf[off+2];}
        else{if(IOSurfaceLock(_sf,kIOSurfaceLockReadOnly,NULL)==KERN_SUCCESS){void*ba=IOSurfaceGetBaseAddress(_sf);
            if(ba){int off=y*_bpr+x*4;unsigned char*p=(unsigned char*)ba+off;b=p[0];g=p[1];r=p[2];}
            IOSurfaceUnlock(_sf,kIOSurfaceLockReadOnly,NULL);}}
        c.r=r;c.g=g;c.b=b;
        if(r||g||b) return c;
    }

    // 回退：_UICreateScreenUIImage
    UIImage *ui=_screenShot(); if(!ui) return c;
    CGImageRef img=ui.CGImage; if(!img) return c;
    size_t iw=CGImageGetWidth(img),ih=CGImageGetHeight(img);
    if(x<0||y<0||x>=(int)iw||y>=(int)ih) return c;

    CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB(); unsigned char p[4]={0};
    CGContextRef ctx=CGBitmapContextCreate(p,1,1,8,4,cs,kCGImageAlphaNoneSkipFirst|kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs); if(!ctx)return c;
    CGContextDrawImage(ctx,CGRectMake(x,y,1,1),img);CGContextRelease(ctx);
    c.r=p[2];c.g=p[1];c.b=p[0]; return c;
}

- (CGPoint)findColor:(ScreenColor)c tolerance:(int)tol x1:(int)x1 y1:(int)y1 x2:(int)x2 y2:(int)y2 {
    [self _tx:&x1 y:&y1];[self _tx:&x2 y:&y2]; if(x1>x2){int t=x1;x1=x2;x2=t;} if(y1>y2){int t=y1;y1=y2;y2=t;}

    if(_fbOK&&x1<x2&&y1<y2){
        if(x1<0)x1=0;if(y1<0)y1=0;if(x2>_w)x2=_w;if(y2>_h)y2=_h;
        if(_keep&&_cbuf){for(int ry=y1;ry<y2;ry++){unsigned char*row=_cbuf+ry*_bpr;
            for(int rx=x1;rx<x2;rx++){int i=rx*4;if(abs(row[i+2]-c.r)<=tol&&abs(row[i+1]-c.g)<=tol&&abs(row[i]-c.b)<=tol)
            {int ox=rx,oy=ry;[self _itx:&ox y:&oy];return CGPointMake(ox,oy);}}}}
        else if(IOSurfaceLock(_sf,kIOSurfaceLockReadOnly,NULL)==KERN_SUCCESS){void*ba=IOSurfaceGetBaseAddress(_sf);
            if(ba){for(int ry=y1;ry<y2;ry++){unsigned char*row=(unsigned char*)ba+ry*_bpr;
            for(int rx=x1;rx<x2;rx++){int i=rx*4;if(abs(row[i+2]-c.r)<=tol&&abs(row[i+1]-c.g)<=tol&&abs(row[i]-c.b)<=tol)
            {int ox=rx,oy=ry;[self _itx:&ox y:&oy];IOSurfaceUnlock(_sf,kIOSurfaceLockReadOnly,NULL);return CGPointMake(ox,oy);}}}}
            IOSurfaceUnlock(_sf,kIOSurfaceLockReadOnly,NULL);}
    }

    // _UICreateScreenUIImage 回退
    UIImage *ui=_screenShot(); if(!ui)return CGPointMake(-1,-1);
    CGImageRef img=ui.CGImage; if(!img)return CGPointMake(-1,-1);
    size_t iw=CGImageGetWidth(img),ih=CGImageGetHeight(img);
    if(x1<0)x1=0;if(y1<0)y1=0;if(x2<=0||x2>(int)iw)x2=(int)iw;if(y2<=0||y2>(int)ih)y2=(int)ih;
    CGPoint ret=CGPointMake(-1,-1);
    if(x1<x2&&y1<y2){
        int rw=x2-x1,rh=y2-y1; size_t rb=(size_t)rw*4;
        unsigned char *buf=malloc(rh*rb); if(buf){
            CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
            CGContextRef ctx=CGBitmapContextCreate(buf,rw,rh,8,rb,cs,kCGImageAlphaNoneSkipFirst|kCGBitmapByteOrder32Little);
            CGColorSpaceRelease(cs); if(ctx){
                CGContextDrawImage(ctx,CGRectMake(-x1,-y1,iw,ih),img);CGContextRelease(ctx);
                for(int ry=0;ry<rh;ry++){unsigned char*ln=buf+ry*rb;for(int rx=0;rx<rw;rx++){int _b=ln[rx*4],_g=ln[rx*4+1],_r=ln[rx*4+2];
                if(abs(_r-c.r)<=tol&&abs(_g-c.g)<=tol&&abs(_b-c.b)<=tol){int ox=x1+rx,oy=y1+ry;[self _itx:&ox y:&oy];free(buf);return CGPointMake(ox,oy);}}}
            }else CGContextRelease(ctx);
            free(buf);}}
    return ret;
}

- (NSArray*)findAllColors:(ScreenColor)c tolerance:(int)t x1:(int)x1 y1:(int)y1 x2:(int)x2 y2:(int)y2{NSMutableArray*a=[NSMutableArray array];while(1){CGPoint p=[self findColor:c tolerance:t x1:x1 y1:y1 x2:x2 y2:y2];if(p.x<0)break;[a addObject:[NSValue valueWithCGPoint:p]];x1=(int)p.x+1;if(x1>=x2)break;}return a;}

- (void)setRotation:(int)d { int v=d%360;if(v<0)v+=360;if(v%90)v=0; _rot=v; }
- (void)resetRotation {_rot=0;}
- (int)rotation{return _rot;}
- (void)_tx:(int*)x y:(int*)y{if(!_rot)return;int rx=*x,ry=*y,w1=_w-1,h1=_h-1;switch(_rot){case 90:*x=w1-ry;*y=rx;break;case 180:*x=w1-rx;*y=h1-ry;break;case 270:*x=ry;*y=h1-rx;break;}}
- (void)_itx:(int*)x y:(int*)y{if(!_rot)return;int ox=*x,oy=*y,w1=_w-1,h1=_h-1;switch(_rot){case 90:*x=oy;*y=w1-ox;break;case 180:*x=w1-ox;*y=h1-oy;break;case 270:*x=h1-oy;*y=ox;break;}}
- (void)keepScreen{if(!_keep){[self colorAtX:0 y:0];_keep=YES;}}
- (void)releaseScreen{_keep=NO;free(_cbuf);_cbuf=NULL;_csz=0;}
- (BOOL)snapshotToPath:(NSString*)p{return NO;}-(BOOL)snapshotToPath:(NSString*)p x:(int)x y:(int)y w:(int)w h:(int)h{return NO;}
@end
