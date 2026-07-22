//
//  ScreenCapture.m
//  无忧辅助 - IOMFB 直读 + roothelper 回退
//

#import "ScreenCapture.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <signal.h>
#import <spawn.h>
#import <sys/wait.h>
#import <IOKit/IOKitLib.h>
#import <IOSurface/IOSurface.h>

// ---- IOMFB 直连 ----
typedef struct __IOMobileFramebuffer *IMFBRef;
static kern_return_t (*_fbMain)(IMFBRef*)=NULL;
static kern_return_t (*_fbSurf)(IMFBRef,int,IOSurfaceRef*)=NULL;

static void _fbload(void){static dispatch_once_t o;dispatch_once(&o,^{
    _fbMain=(kern_return_t(*)(IMFBRef*))dlsym(RTLD_DEFAULT,"IOMobileFramebufferGetMainDisplay");
    _fbSurf=(kern_return_t(*)(IMFBRef,int,IOSurfaceRef*))dlsym(RTLD_DEFAULT,"IOMobileFramebufferGetLayerDefaultSurface");
});}

// ---- 全局显示截取（com.apple.private.screen-capture 权限） ----
// 通过 IORegistry 查找 IOMFB 的显示 IOSurface，用 IOSurfaceLookup 直接映射
// 这个 surface 是全局显示缓冲，不限进程，始终反映物理屏幕内容
static void _initGlobalCapture(IOSurfaceRef *outSf, int *outW, int *outH, int *outBpr, NSString **diag) {
    // 策略 1：扫描 IOMFB 的 IORegistry 属性，查找 display_surface_id
    const char *svcNames[] = {"IOMobileFramebuffer","AppleCLCD","AppleMipiDSI","AppleDCP",NULL};
    for (int i = 0; svcNames[i]; i++) {
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
            IOServiceMatching(svcNames[i]));
        if (svc == MACH_PORT_NULL) continue;

        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) != KERN_SUCCESS || !props) {
            IOObjectRelease(svc); continue;
        }

        // 尝试多种可能的 surface ID 属性名
        const char *sidKeys[] = {
            "IOSurfaceID", "display-surface-id", "DisplaySurfaceID",
            "IOSurfaceCoreSurfaceID", "FBSystemSurfaceID", "ioSurfaceID", NULL
        };
        IOSurfaceRef found = NULL;
        for (int k = 0; sidKeys[k]; k++) {
            CFNumberRef sidNum = CFDictionaryGetValue(props, (__bridge CFStringRef)[NSString stringWithUTF8String:sidKeys[k]]);
            if (!sidNum) continue;
            uint32_t sid = 0;
            if (CFNumberGetValue(sidNum, kCFNumberSInt32Type, &sid) && sid > 0) {
                found = IOSurfaceLookup(sid);
                if (found) {
                    NSLog(@"[GS] ✅ IOMFB surface via %s: ID=%u w=%d h=%d",
                          sidKeys[k], sid,
                          (int)IOSurfaceGetWidth(found), (int)IOSurfaceGetHeight(found));
                    break;
                }
            }
        }

        if (!found) {
            // 策略 2：IOSurfaceRoot user client → create display console surface
            io_service_t rootSvc = IOServiceGetMatchingService(kIOMainPortDefault,
                IOServiceMatching("IOSurfaceRoot"));
            if (rootSvc != MACH_PORT_NULL) {
                io_connect_t conn = MACH_PORT_NULL;
                for (int t = 0; t <= 5; t++) {
                    if (IOServiceOpen(rootSvc, mach_task_self(), t, &conn) == KERN_SUCCESS) {
                        NSLog(@"[GS] IOSurfaceRoot type=%d opened", t);
                        break;
                    }
                }
                IOObjectRelease(rootSvc);
                if (conn != MACH_PORT_NULL) {
                    // 尝试创建显示表面：用 IOSurfaceCreate 带 display 标记
                    // IOSurfaceRoot 连接被保留，但 surface 通过 IOSurfaceCreate 创建
                    CGSize ns = [UIScreen mainScreen].nativeBounds.size;
                    int w = (int)ns.width, h = (int)ns.height;
                    int bpe = 4; uint32_t pf = (uint32_t)'BGRA';
                    CFMutableDictionaryRef dp = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
                    CFNumberRef wn = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &w);
                    CFNumberRef hn = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &h);
                    CFNumberRef bn = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bpe);
                    CFNumberRef pn = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pf);
                    CFDictionarySetValue(dp, kIOSurfaceWidth, wn);
                    CFDictionarySetValue(dp, kIOSurfaceHeight, hn);
                    CFDictionarySetValue(dp, kIOSurfaceBytesPerElement, bn);
                    CFDictionarySetValue(dp, kIOSurfacePixelFormat, pn);
                    CFDictionarySetValue(dp, CFSTR("IOSurfaceIsDisplayConsole"), kCFBooleanTrue);
                    found = IOSurfaceCreate(dp);
                    CFRelease(wn); CFRelease(hn); CFRelease(bn); CFRelease(pn); CFRelease(dp);
                    if (found) {
                        NSLog(@"[GS] ✅ IOSurfaceCreate+DisplayConsole w=%d h=%d",
                              (int)IOSurfaceGetWidth(found), (int)IOSurfaceGetHeight(found));
                    }
                    // 不关闭 conn，保持连接（surface 可能依赖它）
                }
            }
        }

        // 验证 surface 内容非全黑
        BOOL hasContent = NO;
        if (found) {
            int fw = (int)IOSurfaceGetWidth(found), fh = (int)IOSurfaceGetHeight(found);
            int fbpr = (int)IOSurfaceGetBytesPerRow(found);
            if (fw > 0 && fh > 0 && fbpr > 0) {
                if (IOSurfaceLock(found, 1/*readonly*/, NULL) == KERN_SUCCESS) {
                    void *base = IOSurfaceGetBaseAddress(found);
                    if (base) {
                        // 采样 5 个点检查是否全黑
                        int nz = 0, samples = 5;
                        for (int s = 0; s < samples; s++) {
                            int sx = fw * (s+1) / (samples+1);
                            int sy = fh / 2;
                            unsigned char *p = (unsigned char *)base + sy*fbpr + sx*4;
                            if (p[0] || p[1] || p[2]) nz++;
                        }
                        hasContent = (nz > 0);
                        NSLog(@"[GS] 内容检测: %d/%d 采样点非黑 %@",
                              nz, samples, hasContent?@"✅":@"⚠️ 全黑");
                    }
                    IOSurfaceUnlock(found, 1/*readonly*/, NULL);
                }
                if (fw > 0 && fh > 0) {
                    *outSf = found; *outW = fw; *outH = fh; *outBpr = fbpr;
                    *diag = hasContent ? @"OK (有内容)"
                           : [NSString stringWithFormat:@"OK %dx%d (全黑-可能需前台)", fw, fh];
                } else {
                    CFRelease(found);
                }
            } else {
                CFRelease(found);
            }
        }

        CFRelease(props); IOObjectRelease(svc);
        if (*outSf) return; // 找到了就返回
    }
    *diag = @"未找到显示 surface";
}

// ---- roothelper 通信 ----
// 注意：roothelper 现在把 kfd 调试输出重定向到 stderr，
// 只将 "OK/SIZE/ERR" 响应写到 stdout，管道不会被污染。
static NSString *_rhLastError = nil;
static BOOL _rhCall(NSString *cmd, NSString *arg, char *out, size_t sz){
    NSString *hp=[[NSBundle mainBundle]pathForResource:@"roothelper" ofType:nil];
    if(!hp)hp=[[[NSBundle mainBundle]bundlePath]stringByAppendingPathComponent:@"roothelper"];
    if(![[NSFileManager defaultManager]fileExistsAtPath:hp]){
        _rhLastError=[NSString stringWithFormat:@"binary not found at %@",hp];
        NSLog(@"[SCR] rhCall: %@",_rhLastError);
        return NO;
    }
    // 检查是否可执行
    if(access([hp UTF8String],X_OK)!=0){
        _rhLastError=[NSString stringWithFormat:@"binary not executable: %@ (errno=%d)",hp,errno];
        NSLog(@"[SCR] rhCall: %@",_rhLastError);
        return NO;
    }
    const char *av[4]={[hp UTF8String],[cmd UTF8String],[arg UTF8String],NULL};
    pid_t pid;int fd[2];pipe(fd);
    posix_spawn_file_actions_t a;posix_spawn_file_actions_init(&a);
    posix_spawn_file_actions_adddup2(&a,fd[1],STDOUT_FILENO);posix_spawn_file_actions_addclose(&a,fd[0]);
    int r=posix_spawn(&pid,[hp UTF8String],&a,NULL,(char*const*)av,NULL);
    posix_spawn_file_actions_destroy(&a);close(fd[1]);
    if(r!=0){close(fd[0]);_rhLastError=[NSString stringWithFormat:@"posix_spawn err=%d (%s)",r,strerror(r)];
        NSLog(@"[SCR] rhCall %@: %@",cmd,_rhLastError);return NO;}
    int s;waitpid(pid,&s,0);
    // 循环读取所有输出（防止大数据被截断），总上限 8KB
    ssize_t total=0,n;while((n=read(fd[0],out+total,((ssize_t)sz)-total-1))>0){total+=n;if(total>=((ssize_t)sz)-1)break;}
    close(fd[0]);
    if(total>0){out[total]='\0';
        if(!strncmp(out,"ERR",3)){
            _rhLastError=[NSString stringWithFormat:@"%@(%@) → %s",cmd,arg,out];
            NSLog(@"[SCR] rhCall %@",_rhLastError);
        }
        return YES;
    }
    // 无输出：子进程可能被 AMFI 杀死或崩溃
    if(WIFSIGNALED(s)){
        _rhLastError=[NSString stringWithFormat:@"%@(%@) killed by signal %d (SIGKILL=%d AMFI?)",
                      cmd,arg,WTERMSIG(s),SIGKILL];
    }else if(WIFEXITED(s)){
        _rhLastError=[NSString stringWithFormat:@"%@(%@) exit=%d no output",cmd,arg,WEXITSTATUS(s)];
    }else{
        _rhLastError=[NSString stringWithFormat:@"%@(%@) abnormal exit, status=0x%x",cmd,arg,s];
    }
    NSLog(@"[SCR] rhCall %@",_rhLastError);
    return NO;
}

@implementation ScreenCapture {
    IMFBRef _fb; IOSurfaceRef _sf; int _bpr,_w,_h; BOOL _fbOK;
    int _rw,_rh,_rbpr; BOOL _rhOK;
    // 全局显示截取（IOSurfaceLookup via IORegistry）
    IOSurfaceRef _gsf; int _gw,_gh,_gbpr; BOOL _gsOK;
    int _rot; BOOL _keep; unsigned char *_buf; size_t _bsz;
    int _blackStreak;
    NSString *_rhDiag;   // roothelper 诊断信息（最后错误原因）
    NSString *_gsDiag;   // 全局截取诊断信息
}
+ (instancetype)sharedInstance{static ScreenCapture*i;static dispatch_once_t t;dispatch_once(&t,^{i=[[ScreenCapture alloc]init];});return i;}
- (instancetype)init{if(self=[super init]){_fbOK=NO;_rhOK=NO;_gsOK=NO;_rot=0;_blackStreak=0;[self _con];}return self;}
- (void)dealloc{[self releaseScreen];}

// ---- 双模连接（全局截取优先） ----
- (void)_con{
    // 策略 1：全局显示截取（com.apple.private.screen-capture）
    {NSString *diag=nil;_initGlobalCapture(&_gsf,&_gw,&_gh,&_gbpr,&diag);_gsDiag=diag;}
    if(_gsf&&_gw>0&&_gh>0){_gsOK=YES;NSLog(@"[SCR] 全局截取: %dx%d bpr=%d",_gw,_gh,_gbpr);}

    // 策略 2：IOMFB 直连（per-process，权限提升后可能变全局）
    _fbload();
    if(_fbMain&&_fbSurf&&_fbMain(&_fb)==KERN_SUCCESS&&_fb){
        for(int l=0;l<=2;l++){if(_fbSurf(_fb,l,&_sf)==KERN_SUCCESS&&_sf){_w=(int)IOSurfaceGetWidth(_sf);_h=(int)IOSurfaceGetHeight(_sf);
        if(_w>0&&_h>0){_bpr=(int)IOSurfaceGetBytesPerRow(_sf);_fbOK=YES;NSLog(@"[SCR] IOMFB layer%d=%dx%d bpr=%d",l,_w,_h,_bpr);break;}CFRelease(_sf);_sf=NULL;}}
        if(!_fbOK){_fb=NULL;}
    }

    // 策略 3：roothelper kfd
    char b[128]={0};if(_rhCall(@"size",@"",b,sizeof(b))){
        sscanf(b,"SIZE %d %d %d",&_rw,&_rh,&_rbpr);
        if(_rw>0&&_rh>0){_rhOK=YES;_rhDiag=@"OK";NSLog(@"[SCR] roothelper size=%dx%d bpr=%d",_rw,_rh,_rbpr);}
        else{_rhDiag=[NSString stringWithFormat:@"parse failed: %s",b];NSLog(@"[SCR] roothelper %@",_rhDiag);}
    }else{_rhDiag=_rhLastError?_rhLastError:@"size call failed (unknown)";NSLog(@"[SCR] roothelper %@",_rhDiag);}
    if(!_gsOK&&!_fbOK&&!_rhOK){CGSize s=[UIScreen mainScreen].nativeBounds.size;_w=(int)s.width;_h=(int)s.height;_bpr=_w*4;NSLog(@"[SCR] fallback to UIScreen: %dx%d",_w,_h);}
    if(!_rhOK){_rw=_w;_rh=_h;_rbpr=_bpr;}
    if(!_gsOK){_gw=_w;_gh=_h;_gbpr=_bpr;}
    NSLog(@"[SCR] init done: gsOK=%d fbOK=%d rhOK=%d",_gsOK,_fbOK,_rhOK);
}
- (BOOL)isConnected{return _gsOK||_fbOK||_rhOK||_w>0;}
- (NSString*)diagnosticDescription{
    NSString *mode=_gsOK?[NSString stringWithFormat:@"全局截取 %dx%d",_gw,_gh]:
                   _fbOK?[NSString stringWithFormat:@"IOMFB 直连 %dx%d",_w,_h]:
                   _rhOK?[NSString stringWithFormat:@"roothelper %dx%d",_rw,_rh]:
                   [NSString stringWithFormat:@"回退 %dx%d",_w,_h];
    NSString *gsInfo=@"";
    if(_gsOK){gsInfo=[NSString stringWithFormat:@"\n全局截取: ✅ %dx%d %@",_gw,_gh,_gsDiag?:@""];}
    else{gsInfo=[NSString stringWithFormat:@"\n全局截取: ❌ %@",_gsDiag?:@"unknown"];}
    NSString *rhInfo=@"";
    if(!_rhOK && _rhDiag){
        rhInfo=[NSString stringWithFormat:@"\nroothelper: ❌ %@",_rhDiag];
    }else if(_rhOK){
        rhInfo=[NSString stringWithFormat:@"\nroothelper: ✅ %dx%d",_rw,_rh];
    }
    int rw=_gsOK?_gw:(_rhOK?_rw:_w),rh=_gsOK?_gh:(_rhOK?_rh:_h);
    return [NSString stringWithFormat:@"屏幕捕获: %@%@%@\n安装方式: %@\n分辨率: %dx%d\n取色可用: %@\n",
            mode,gsInfo,rhInfo,access("/var/mobile/Library",F_OK)==0?@"✅ TrollStore":@"❌ 沙盒内",
            rw,rh,(_gsOK||_fbOK||_rhOK||_w>0)?@"✅ 是":@"❌ 否"];
}

- (NSString*)testPixelAtX:(int)x y:(int)y{
    NSMutableString *s=[NSMutableString stringWithFormat:@"取色测试 @(%d,%d):\n",x,y];
    
    // 全局截取（优先）
    if(_gsOK&&_gsf&&x>=0&&x<_gw&&y>=0&&y<_gh){
        unsigned char r=0,g=0,b=0;
        if(IOSurfaceLock(_gsf,1/*readonly*/,NULL)==KERN_SUCCESS){
            void*ba=IOSurfaceGetBaseAddress(_gsf);
            if(ba){int o=y*_gbpr+x*4;unsigned char*p=(unsigned char*)ba+o;b=p[0];g=p[1];r=p[2];}
            IOSurfaceUnlock(_gsf,1/*readonly*/,NULL);
        }
        [s appendFormat:@"  全局截取: R=%d G=%d B=%d (0x%02X%02X%02X)%@\n",
         r,g,b,r,g,b,(r||g||b)?@"":@" ← 全黑!"];
    }else{
        [s appendFormat:@"  全局截取: %@\n",_gsOK?@"未就绪":_gsDiag?:@"未就绪"];
    }
    
    // IOMFB 直读
    if(_fbOK&&_sf&&x>=0&&x<_w&&y>=0&&y<_h){
        unsigned char r=0,g=0,b=0;
        if(IOSurfaceLock(_sf,1,NULL)==KERN_SUCCESS){
            void*ba=IOSurfaceGetBaseAddress(_sf);
            if(ba){int o=y*_bpr+x*4;unsigned char*p=(unsigned char*)ba+o;b=p[0];g=p[1];r=p[2];}
            IOSurfaceUnlock(_sf,1,NULL);
        }
        [s appendFormat:@"  IOMFB直连: R=%d G=%d B=%d (0x%02X%02X%02X)%@\n",
         r,g,b,r,g,b,(r||g||b)?@"":@" ← 全黑!"];
    }else{
        [s appendString:@"  IOMFB直连: 未就绪\n"];
    }
    
    // roothelper
    if(x>=0&&x<_rw&&y>=0&&y<_rh){
        char buf[128]={0};
        NSString*coord=[NSString stringWithFormat:@"%d,%d",x,y];
        if(_rhCall(@"pixel",coord,buf,sizeof(buf))){
            int rr=0,gg=0,bb=0;
            if(sscanf(buf,"OK %d %d %d",&rr,&gg,&bb)==3){
                [s appendFormat:@"  roothelper: R=%d G=%d B=%d (0x%02X%02X%02X)%@\n",
                 rr,gg,bb,rr,gg,bb,(rr||gg||bb)?@"":@" ← 全黑!"];
            }else{
                [s appendFormat:@"  roothelper: 解析失败: %s\n",buf];
            }
        }else{
            [s appendFormat:@"  roothelper: %@\n",_rhLastError?_rhLastError:@"调用失败"];
        }
    }else{
        [s appendFormat:@"  roothelper: 坐标越界 (尺寸=%dx%d)\n",_rw,_rh];
    }
    
    return s;
}
- (CGSize)screenSize{int w=_gsOK?_gw:(_rhOK?_rw:_w),h=_gsOK?_gh:(_rhOK?_rh:_h);return(_rot==90||_rot==270)?CGSizeMake(h,w):CGSizeMake(w,h);}

// ---- 取色：全局截取 → IOMFB → roothelper → 回退 ----
- (ScreenColor)colorAtX:(int)x y:(int)y {
    ScreenColor c={0,0,0};[self _tx:&x y:&y];if(x<0||y<0)return c;
    unsigned char r=0,g=0,b=0;

    // 0. 全局显示截取（优先，com.apple.private.screen-capture）
    if(_gsOK&&_gsf&&x>=0&&x<_gw&&y>=0&&y<_gh){
        if(IOSurfaceLock(_gsf,1/*readonly*/,NULL)==KERN_SUCCESS){
            void*ba=IOSurfaceGetBaseAddress(_gsf);
            if(ba){int o=y*_gbpr+x*4;unsigned char*p=(unsigned char*)ba+o;b=p[0];g=p[1];r=p[2];}
            IOSurfaceUnlock(_gsf,1/*readonly*/,NULL);
        }
        c.r=r;c.g=g;c.b=b;
        if(r||g||b){_blackStreak=0;return c;}
    }

    // 1. IOMFB 直读
    if(_fbOK&&_sf&&x>=0&&x<_w&&y>=0&&y<_h){
        if(_keep&&_buf){int o=y*_bpr+x*4;b=_buf[o];g=_buf[o+1];r=_buf[o+2];}
        else{if(IOSurfaceLock(_sf,1,NULL)==KERN_SUCCESS){void*ba=IOSurfaceGetBaseAddress(_sf);
            if(ba){int o=y*_bpr+x*4;unsigned char*p=(unsigned char*)ba+o;b=p[0];g=p[1];r=p[2];}
            IOSurfaceUnlock(_sf,1,NULL);}}
        c.r=r;c.g=g;c.b=b;
        if(r||g||b){_blackStreak=0;return c;}
        // 后天全黑检测 → 自愈重连
        _blackStreak++;
        if(_blackStreak<=2){
            if(IOSurfaceLock(_sf,1,NULL)==KERN_SUCCESS){void*ba=IOSurfaceGetBaseAddress(_sf);
                if(ba){int o=y*_bpr+x*4;unsigned char*p2=(unsigned char*)ba+o;b=p2[0];g=p2[1];r=p2[2];}
                IOSurfaceUnlock(_sf,1,NULL);}
            c.r=r;c.g=g;c.b=b;if(r||g||b){_blackStreak=0;return c;}
        }
        if(_blackStreak>=2){[self _reconnectIOMFB];_blackStreak=0;
            if(_fbOK&&_sf&&x>=0&&x<_w&&y>=0&&y<_h){r=0;g=0;b=0;
                if(IOSurfaceLock(_sf,1,NULL)==KERN_SUCCESS){void*ba=IOSurfaceGetBaseAddress(_sf);
                    if(ba){int o=y*_bpr+x*4;unsigned char*p3=(unsigned char*)ba+o;b=p3[0];g=p3[1];r=p3[2];}
                    IOSurfaceUnlock(_sf,1,NULL);}
                c.r=r;c.g=g;c.b=b;if(r||g||b)return c;
            }
        }
    }

    // 2. roothelper（独立后台进程，始终尝试）
    if(x>=0&&x<_rw&&y>=0&&y<_rh){
        char buf[128]={0};NSString*coord=[NSString stringWithFormat:@"%d,%d",x,y];
        if(_rhCall(@"pixel",coord,buf,sizeof(buf))){int rr=0,gg=0,bb=0;
            if(sscanf(buf,"OK %d %d %d",&rr,&gg,&bb)==3){c.r=(unsigned char)rr;c.g=(unsigned char)gg;c.b=(unsigned char)bb;
                if(rr||gg||bb){_rhOK=YES;NSLog(@"[SCR] rh pixel(%d,%d)=%d,%d,%d",x,y,rr,gg,bb);return c;}
            }
        }
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

    // roothelper capture（独立后台进程，始终尝试）
    {
        NSString *tf=[NSTemporaryDirectory() stringByAppendingPathComponent:@"sc_cap.dat"];
        [[NSFileManager defaultManager]removeItemAtPath:tf error:nil];
        char db[256]={0};
        if(_rhCall(@"capture",tf,db,sizeof(db))){
            NSData *d=[NSData dataWithContentsOfFile:tf];
            [[NSFileManager defaultManager]removeItemAtPath:tf error:nil];
            size_t total=(size_t)_rh*_rbpr;
            if(d.length>=total){
                _rhOK=YES;
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
- (void)releaseScreen{_keep=NO;free(_buf);_buf=NULL;_bsz=0;
    if(_gsf){CFRelease(_gsf);_gsf=NULL;}_gsOK=NO;_gsDiag=nil;}
- (void)_reconnectIOMFB{
    // 重连全局截取
    if(_gsf){CFRelease(_gsf);_gsf=NULL;}_gsOK=NO;
    {NSString *diag=nil;_initGlobalCapture(&_gsf,&_gw,&_gh,&_gbpr,&diag);_gsDiag=diag;}
    if(_gsf&&_gw>0&&_gh>0){_gsOK=YES;NSLog(@"[SCR] 全局截取重连: %dx%d",_gw,_gh);}
    // 重连 IOMFB
    if(_sf){CFRelease(_sf);_sf=NULL;}
    _fbOK=NO;
    _fbload();
    if(_fbMain&&_fbSurf&&_fbMain(&_fb)==KERN_SUCCESS&&_fb){
        for(int l=0;l<=2;l++){if(_fbSurf(_fb,l,&_sf)==KERN_SUCCESS&&_sf){_w=(int)IOSurfaceGetWidth(_sf);_h=(int)IOSurfaceGetHeight(_sf);
        if(_w>0&&_h>0){_bpr=(int)IOSurfaceGetBytesPerRow(_sf);_fbOK=YES;break;}CFRelease(_sf);_sf=NULL;}}
        if(!_fbOK){_fb=NULL;}
    }
    // 同时刷新 roothelper 尺寸
    char b[128]={0};
    if(_rhCall(@"size",@"",b,sizeof(b))){
        int rw2,rh2,rbpr2;
        if(sscanf(b,"SIZE %d %d %d",&rw2,&rh2,&rbpr2)==3&&rw2>0&&rh2>0){
            _rw=rw2;_rh=rh2;_rbpr=rbpr2;_rhOK=YES;_rhDiag=@"OK";
        }
    }else{
        _rhDiag=_rhLastError?_rhLastError:@"size call failed (unknown)";
    }
    if(!_rhOK){_rw=_w;_rh=_h;_rbpr=_bpr;}
    if(!_gsOK){_gw=_w;_gh=_h;_gbpr=_bpr;}
}
- (void)reconnectScreen{[self _reconnectIOMFB];}
- (BOOL)isScreenAlive{
    if(!_fbOK&&_w<=0)return NO;
    int tx=_w/2,ty=_h/2;
    ScreenColor c=[self colorAtX:tx y:ty];
    return (c.r>0||c.g>0||c.b>0);
}
- (BOOL)snapshotToPath:(NSString*)p{return NO;}-(BOOL)snapshotToPath:(NSString*)p x:(int)x y:(int)y w:(int)w h:(int)h{return NO;}
@end
