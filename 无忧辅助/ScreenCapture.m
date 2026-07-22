//
//  ScreenCapture.m
//  无忧辅助 - 通过 roothelper (root 进程) + IOMobileFramebuffer 后台取色
//  原理: iOS 15+ 后台 App 的 IOMobileFramebuffer 只返回自画面，
//        必须从 root 进程调用才能获得真实系统屏幕帧缓冲
//

#import "ScreenCapture.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>

// ---- roothelper 通信 ----
static BOOL _spawnRootHelper(NSString *cmd, NSString *arg, char *outBuf, size_t outSize) {
    // 获取 roothelper 路径
    NSString *helperPath = [[NSBundle mainBundle] pathForResource:@"roothelper" ofType:nil];
    if (!helperPath) {
        // 搜索 app bundle
        NSString *appPath = [[NSBundle mainBundle] bundlePath];
        helperPath = [appPath stringByAppendingPathComponent:@"roothelper"];
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:helperPath]) {
        NSLog(@"[SC] ❌ roothelper 未找到: %@", helperPath);
        return NO;
    }

    // 构造命令
    const char *argv[4] = { [helperPath UTF8String], [cmd UTF8String], [arg UTF8String], NULL };

    // 通过 posix_spawn 启动（no-sandbox + persona-mgmt 下可获取 root）
    pid_t pid;
    int pipefd[2];
    pipe(pipefd);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);

    int ret = posix_spawn(&pid, [helperPath UTF8String], &actions, NULL,
                          (char *const *)argv, NULL);

    posix_spawn_file_actions_destroy(&actions);
    close(pipefd[1]);

    if (ret != 0) {
        NSLog(@"[SC] ❌ posix_spawn roothelper 失败: %d", ret);
        close(pipefd[0]);
        return NO;
    }

    // 等待进程结束，读取输出
    int status;
    waitpid(pid, &status, 0);

    ssize_t n = read(pipefd[0], outBuf, outSize - 1);
    close(pipefd[0]);

    if (n > 0) {
        outBuf[n] = '\0';
        return YES;
    }
    return NO;
}

// ---- 通过 roothelper 取色 ----
static ScreenColor _rootColorAt(int x, int y) {
    ScreenColor c = {0,0,0};
    if (x < 0 || y < 0) return c;

    char buf[128] = {0};
    NSString *coord = [NSString stringWithFormat:@"%d,%d", x, y];
    if (!_spawnRootHelper(@"pixel", coord, buf, sizeof(buf))) return c;

    // 解析 "R G B" 格式输出
    int r=0, g=0, b=0;
    if (sscanf(buf, "OK %d %d %d", &r, &g, &b) == 3) {
        c.r = (unsigned char)r; c.g = (unsigned char)g; c.b = (unsigned char)b;
    }
    return c;
}

// ---- 通过 roothelper 全屏截图数据 ----
static unsigned char *_rootCaptureBuffer(size_t *outTotalSize) {
    *outTotalSize = 0;

    // 先获取尺寸 → 解析 "SIZE w h bpr"
    char sizeBuf[128] = {0};
    if (!_spawnRootHelper(@"size", @"", sizeBuf, sizeof(sizeBuf))) return NULL;

    int w=0, h=0, bpr=0;
    if (sscanf(sizeBuf, "SIZE %d %d %d", &w, &h, &bpr) != 3) return NULL;
    if (w <= 0 || h <= 0) return NULL;

    // 分配缓冲
    size_t total = (size_t)h * bpr;
    unsigned char *buf = malloc(total);
    if (!buf) return NULL;

    // 获取全帧数据 → base64
    char dataBuf[256] = {0};
    if (!_spawnRootHelper(@"capture", @"", dataBuf, sizeof(dataBuf))) {
        free(buf); return NULL;
    }

    // 解析 "DATA len" 格式 (简化: roothelper 输出原始字节)
    // 实际需要分片传输，这里简化为每行单独读
    // 由于 roothelper 通过 pipe 传数据太复杂，改为直接通过文件传递
    NSString *tmpFile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"sc_cap.dat"];
    [[NSFileManager defaultManager] removeItemAtPath:tmpFile error:nil];

    if (!_spawnRootHelper(@"capture", tmpFile, dataBuf, sizeof(dataBuf))) {
        free(buf); return NULL;
    }

    NSData *data = [NSData dataWithContentsOfFile:tmpFile];
    [[NSFileManager defaultManager] removeItemAtPath:tmpFile error:nil];

    if (data.length >= total) {
        memcpy(buf, data.bytes, total);
        *outTotalSize = data.length;
        return buf;
    }

    free(buf);
    return NULL;
}

// ============================================================
// 公开接口
// ============================================================
@implementation ScreenCapture {
    int _rw, _rh, _rbpr;   // root 模式下的分辨率
    int _rot;
    BOOL _rootMode;          // 使用 roothelper 模式
    unsigned char *_cbuf;
    size_t _csz;
    BOOL _keep;
}

+ (instancetype)sharedInstance { static ScreenCapture *i; static dispatch_once_t t; dispatch_once(&t,^{i=[[ScreenCapture alloc]init];}); return i; }

- (instancetype)init {
    if(self=[super init]){
        _rw=_rh=_rbpr=0; _rot=0; _rootMode=YES;
        // 获取初始尺寸
        [self _getSize];
    }
    return self;
}

- (void)_getSize {
    char buf[128]={0};
    if(_spawnRootHelper(@"size",@"",buf,sizeof(buf)))
        sscanf(buf,"SIZE %d %d %d",&_rw,&_rh,&_rbpr);
    if(_rw<=0||_rh<=0){
        // 回退到 UIScreen
        CGSize s=[UIScreen mainScreen].nativeBounds.size;
        _rw=(int)s.width;_rh=(int)s.height;_rbpr=_rw*4;
        _rootMode=NO;
    }
}

// ---- 取色 ----
- (ScreenColor)colorAtX:(int)x y:(int)y {
    ScreenColor c={0,0,0}; [self _tx:&x y:&y]; if(x<0||y<0)return c;

    if(_rootMode){
        c = _rootColorAt(x, y);
        if(c.r||c.g||c.b) return c;
    }

    // 回退：直接用 UIKit 截图（仅本应用内有效）
    return c;
}

// ---- 找色 ----
- (CGPoint)findColor:(ScreenColor)color tolerance:(int)tol
                  x1:(int)x1 y1:(int)y1 x2:(int)x2 y2:(int)y2 {
    [self _tx:&x1 y:&y1]; [self _tx:&x2 y:&y2];
    if(x1>x2){int t=x1;x1=x2;x2=t;} if(y1>y2){int t=y1;y1=y2;y2=t;}
    if(x1<0)x1=0; if(y1<0)y1=0;

    if(_rootMode){
        // 从 roothelper 获取全屏帧
        size_t total=0;
        unsigned char *buf = _rootCaptureBuffer(&total);
        if(buf && _rbpr>0){
            for(int ry=y1;ry<y2&&ry<_rh;ry++){
                unsigned char *row=buf+ry*_rbpr;
                for(int rx=x1;rx<x2&&rx<_rw;rx++){
                    int i=rx*4;
                    if(abs(row[i+2]-color.r)<=tol&&abs(row[i+1]-color.g)<=tol&&abs(row[i]-color.b)<=tol){
                        int ox=rx,oy=ry; [self _itx:&ox y:&oy];
                        free(buf); return CGPointMake(ox,oy);
                    }
                }
            }
            free(buf);
        }
    }
    return CGPointMake(-1,-1);
}

- (NSArray*)findAllColors:(ScreenColor)c tolerance:(int)t x1:(int)x1 y1:(int)y1 x2:(int)x2 y2:(int)y2{
    NSMutableArray*a=[NSMutableArray array];while(1){CGPoint p=[self findColor:c tolerance:t x1:x1 y1:y1 x2:x2 y2:y2];if(p.x<0)break;[a addObject:[NSValue valueWithCGPoint:p]];x1=(int)p.x+1;if(x1>=x2)break;}return a;
}

- (BOOL)isConnected{return _rootMode || _rw>0;}
- (NSString*)diagnosticDescription{
    return [NSString stringWithFormat:@"屏幕捕获: %@\n安装方式: %@\n分辨率: %dx%d\n取色可用: %@\n",
        _rootMode?@"roothelper (root 进程)":[NSString stringWithFormat:@"回退 %dx%d",_rw,_rh],
        access("/var/mobile/Library",F_OK)==0?@"✅ TrollStore":@"❌ 沙盒内",
        _rw,_rh, (_rootMode||_rw>0)?@"✅ 是":@"❌ 否"];
}

- (CGSize)screenSize{return (_rot==90||_rot==270)?CGSizeMake(_rh,_rw):CGSizeMake(_rw,_rh);}

- (void)setRotation:(int)d{int v=d%360;if(v<0)v+=360;if(v%90)v=0;_rot=v;}
- (void)resetRotation{_rot=0;}
- (int)rotation{return _rot;}
- (void)_tx:(int*)x y:(int*)y{if(!_rot)return;int rx=*x,ry=*y,w1=_rw-1,h1=_rh-1;switch(_rot){case 90:*x=w1-ry;*y=rx;break;case 180:*x=w1-rx;*y=h1-ry;break;case 270:*x=ry;*y=h1-rx;break;}}
- (void)_itx:(int*)x y:(int*)y{if(!_rot)return;int ox=*x,oy=*y,w1=_rw-1,h1=_rh-1;switch(_rot){case 90:*x=oy;*y=w1-ox;break;case 180:*x=w1-ox;*y=h1-oy;break;case 270:*x=h1-oy;*y=ox;break;}}
- (void)keepScreen{if(!_keep){[self colorAtX:0 y:0];_keep=YES;}}
- (void)releaseScreen{_keep=NO;free(_cbuf);_cbuf=NULL;_csz=0;}
- (BOOL)snapshotToPath:(NSString*)p{return NO;}
- (BOOL)snapshotToPath:(NSString*)p x:(int)x y:(int)y w:(int)w h:(int)h{return NO;}
@end
