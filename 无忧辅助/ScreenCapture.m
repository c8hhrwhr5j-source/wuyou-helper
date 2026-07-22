//
//  ScreenCapture.m
//  无忧辅助 - IOMFB 直读 + roothelper 回退
//

#import "ScreenCapture.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <unistd.h>
#import <spawn.h>
#import <sys/wait.h>
#import <IOSurface/IOSurfaceRef.h>

// ---- IOMFB 直连 ----
typedef struct __IOMobileFramebuffer *IMFBRef;
static kern_return_t (*_fbMain)(IMFBRef*)=NULL;
static kern_return_t (*_fbSurf)(IMFBRef,int,IOSurfaceRef*)=NULL;

static void _fbload(void){static dispatch_once_t o;dispatch_once(&o,^{
    _fbMain=(kern_return_t(*)(IMFBRef*))dlsym(RTLD_DEFAULT,"IOMobileFramebufferGetMainDisplay");
    _fbSurf=(kern_return_t(*)(IMFBRef,int,IOSurfaceRef*))dlsym(RTLD_DEFAULT,"IOMobileFramebufferGetLayerDefaultSurface");
});}

// ---- roothelper 通信 ----
static BOOL _rhCall(NSString *cmd, NSString *arg, char *out, size_t sz){
    NSString *hp=[[NSBundle mainBundle]pathForResource:@"roothelper" ofType:nil];
    if(!hp)hp=[[[NSBundle mainBundle]bundlePath]stringByAppendingPathComponent:@"roothelper"];
    if(![[NSFileManager defaultManager]fileExistsAtPath:hp])return NO;
    const char *av[4]={[hp UTF8String],[cmd UTF8String],[arg UTF8String],NULL};
    pid_t pid;int fd[2];pipe(fd);
    posix_spawn_file_actions_t a;posix_spawn_file_actions_init(&a);
    posix_spawn_file_actions_adddup2(&a,fd[1],STDOUT_FILENO);posix_spawn_file_actions_addclose(&a,fd[0]);
    int r=posix_spawn(&pid,[hp UTF8String],&a,NULL,(char*const*)av,NULL);
    posix_spawn_file_actions_destroy(&a);close(fd[1]);
    if(r!=0){close(fd[0]);return NO;}
    int s;waitpid(pid,&s,0);ssize_t n=read(fd[0],out,sz-1);close(fd[0]);
    if(n>0){out[n]='\0';return YES;}return NO;
}

@implementation ScreenCapture {
    IMFBRef _fb; IOSurfaceRef _sf; int _bpr,_w,_h; BOOL _fbOK;
    int _rw,_rh,_rbpr; BOOL _rhOK;
    int _rot; BOOL _keep; unsigned char *_buf; size_t _bsz;
}
+ (instancetype)sharedInstance{static ScreenCapture*i;static dispatch_once_t t;dispatch_once(&t,^{i=[[ScreenCapture alloc]init];});return i;}
- (instancetype)init{if(self=[super init]){_fbOK=NO;_rhOK=NO;_rot=0;[self _con];}return self;}
- (void)dealloc{[self releaseScreen];}

// ---- 双模连接 ----
- (void)_con{
    _fbload();
    if(_fbMain&&_fbSurf&&_fbMain(&_fb)==KERN_SUCCESS&&_fb){
        for(int l=0;l<=2;l++){if(_fbSurf(_fb,l,&_sf)==KERN_SUCCESS&&_sf){_w=(int)IOSurfaceGetWidth(_sf);_h=(int)IOSurfaceGetHeight(_sf);
        if(_w>0&&_h>0){_bpr=(int)IOSurfaceGetBytesPerRow(_sf);_fbOK=YES;break;}CFRelease(_sf);_sf=NULL;}}
        if(!_fbOK){_fb=NULL;}
    }
    // roothelper 尺寸
    char b[128]={0};if(_rhCall(@"size",@"",b,sizeof(b))){
        sscanf(b,"SIZE %d %d %d",&_rw,&_rh,&_rbpr);
        if(_rw>0&&_rh>0)_rhOK=YES;
    }
    if(!_fbOK&&!_rhOK){CGSize s=[UIScreen mainScreen].nativeBounds.size;_w=(int)s.width;_h=(int)s.height;_bpr=_w*4;}
    if(!_rhOK){_rw=_w;_rh=_h;_rbpr=_bpr;}
}
- (BOOL)isConnected{return _fbOK||_rhOK||_w>0;}
- (NSString*)diagnosticDescription{
    NSString *mode=_fbOK?[NSString stringWithFormat:@"IOMFB 直连 %dx%d",_w,_h]:
                   _rhOK?[NSString stringWithFormat:@"roothelper %dx%d",_rw,_rh]:
                   [NSString stringWithFormat:@"回退 %dx%d",_w,_h];
    return [NSString stringWithFormat:@"屏幕捕获: %@\n安装方式: %@\n分辨率: %dx%d\n取色可用: %@\n",
            mode,access("/var/mobile/Library",F_OK)==0?@"✅ TrollStore":@"❌ 沙盒内",
            _rhOK?_rw:_w,_rhOK?_rh:_h,(_fbOK||_rhOK||_w>0)?@"✅ 是":@"❌ 否"];
}
- (CGSize)screenSize{int w=_rhOK?_rw:_w,h=_rhOK?_rh:_h;return(_rot==90||_rot==270)?CGSizeMake(h,w):CGSizeMake(w,h);}

// ---- 取色：IOMFB → roothelper → 回退 ----
- (ScreenColor)colorAtX:(int)x y:(int)y {
    ScreenColor c={0,0,0};[self _tx:&x y:&y];if(x<0||y<0)return c;
    unsigned char r=0,g=0,b=0;

    // 1. IOMFB 直读
    if(_fbOK&&_sf&&x>=0&&x<_w&&y>=0&&y<_h){
        if(_keep&&_buf){int o=y*_bpr+x*4;b=_buf[o];g=_buf[o+1];r=_buf[o+2];}
        else{if(IOSurfaceLock(_sf,1,NULL)==KERN_SUCCESS){void*ba=IOSurfaceGetBaseAddress(_sf);
            if(ba){int o=y*_bpr+x*4;unsigned char*p=(unsigned char*)ba+o;b=p[0];g=p[1];r=p[2];}
            IOSurfaceUnlock(_sf,1,NULL);}}
        c.r=r;c.g=g;c.b=b;if(r||g||b)return c;
    }

    // 2. roothelper
    if(_rhOK&&x>=0&&x<_rw&&y>=0&&y<_rh){
        char buf[128]={0};NSString*coord=[NSString stringWithFormat:@"%d,%d",x,y];
        if(_rhCall(@"pixel",coord,buf,sizeof(buf))){int rr=0,gg=0,bb=0;
            if(sscanf(buf,"OK %d %d %d",&rr,&gg,&bb)==3){c.r=(unsigned char)rr;c.g=(unsigned char)gg;c.b=(unsigned char)bb;}
        }
        if(c.r||c.g||c.b)return c;
    }

    return c;
}

// ---- 找色 ----
- (CGPoint)findColor:(ScreenColor)c tolerance:(int)tol x1:(int)x1 y1:(int)y1 x2:(int)x2 y2:(int)y2{
    [self _tx:&x1 y:&y1];[self _tx:&x2 y:&y2];if(x1>x2){int t=x1;x1=x2;x2=t;}if(y1>y2){int t=y1;y1=y2;y2=t;}
    if(x1<0)x1=0;if(y1<0)y1=0;

    // IOMFB
    if(_fbOK&&x1<x2&&y1<y2){
        if(x2>_w)x2=_w;if(y2>_h)y2=_h;
        if(_keep&&_buf){for(int ry=y1;ry<y2;ry++){unsigned char*row=_buf+ry*_bpr;
            for(int rx=x1;rx<x2;rx++){int i=rx*4;if(abs(row[i+2]-c.r)<=tol&&abs(row[i+1]-c.g)<=tol&&abs(row[i]-c.b)<=tol)
            {int ox=rx,oy=ry;[self _itx:&ox y:&oy];return CGPointMake(ox,oy);}}}}
        else if(IOSurfaceLock(_sf,1,NULL)==KERN_SUCCESS){void*ba=IOSurfaceGetBaseAddress(_sf);
            if(ba){for(int ry=y1;ry<y2;ry++){unsigned char*row=(unsigned char*)ba+ry*_bpr;
            for(int rx=x1;rx<x2;rx++){int i=rx*4;if(abs(row[i+2]-c.r)<=tol&&abs(row[i+1]-c.g)<=tol&&abs(row[i]-c.b)<=tol)
            {int ox=rx,oy=ry;[self _itx:&ox y:&oy];IOSurfaceUnlock(_sf,1,NULL);return CGPointMake(ox,oy);}}}}
            IOSurfaceUnlock(_sf,1,NULL);}
    }

    // roothelper capture
    if(_rhOK){
        NSString *tf=[NSTemporaryDirectory() stringByAppendingPathComponent:@"sc_cap.dat"];
        [[NSFileManager defaultManager]removeItemAtPath:tf error:nil];
        char db[256]={0};
        if(_rhCall(@"capture",tf,db,sizeof(db))){
            NSData *d=[NSData dataWithContentsOfFile:tf];
            [[NSFileManager defaultManager]removeItemAtPath:tf error:nil];
            size_t total=(size_t)_rh*_rbpr;
            if(d.length>=total){
                unsigned char *m=(unsigned char*)d.bytes;
                for(int ry=y1;ry<y2&&ry<_rh;ry++){unsigned char*row=m+ry*_rbpr;
                for(int rx=x1;rx<x2&&rx<_rw;rx++){int i=rx*4;if(abs(row[i+2]-c.r)<=tol&&abs(row[i+1]-c.g)<=tol&&abs(row[i]-c.b)<=tol)
                {int ox=rx,oy=ry;[self _itx:&ox y:&oy];return CGPointMake(ox,oy);}}}
            }
        }
    }

    return CGPointMake(-1,-1);
}

- (NSArray*)findAllColors:(ScreenColor)c tolerance:(int)t x1:(int)x1 y1:(int)y1 x2:(int)x2 y2:(int)y2{NSMutableArray*a=[NSMutableArray array];while(1){CGPoint p=[self findColor:c tolerance:t x1:x1 y1:y1 x2:x2 y2:y2];if(p.x<0)break;[a addObject:[NSValue valueWithCGPoint:p]];x1=(int)p.x+1;if(x1>=x2)break;}return a;}

- (void)setRotation:(int)d{int v=d%360;if(v<0)v+=360;if(v%90)v=0;_rot=v;}
- (void)resetRotation{_rot=0;}
- (int)rotation{return _rot;}
- (void)_tx:(int*)x y:(int*)y{if(!_rot)return;int w=_rhOK?_rw:_w,h=_rhOK?_rh:_h,w1=w-1,h1=h-1;int rx=*x,ry=*y;switch(_rot){case 90:*x=w1-ry;*y=rx;break;case 180:*x=w1-rx;*y=h1-ry;break;case 270:*x=ry;*y=h1-rx;break;}}
- (void)_itx:(int*)x y:(int*)y{if(!_rot)return;int w=_rhOK?_rw:_w,h=_rhOK?_rh:_h,w1=w-1,h1=h-1;int ox=*x,oy=*y;switch(_rot){case 90:*x=oy;*y=w1-ox;break;case 180:*x=w1-ox;*y=h1-oy;break;case 270:*x=h1-oy;*y=ox;break;}}
- (void)keepScreen{if(!_keep){[self colorAtX:0 y:0];_keep=YES;}}
- (void)releaseScreen{_keep=NO;free(_buf);_buf=NULL;_bsz=0;}
- (BOOL)snapshotToPath:(NSString*)p{return NO;}-(BOOL)snapshotToPath:(NSString*)p x:(int)x y:(int)y w:(int)w h:(int)h{return NO;}
@end
