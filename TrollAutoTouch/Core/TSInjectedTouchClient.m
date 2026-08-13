//
//  TSInjectedTouchClient.m
//  TrollAutoTouch
//
//  app 端触摸注入客户端实现 (详见头文件)

#import "TSInjectedTouchClient.h"
#import "TSInjectedTouchService.h"

#include <spawn.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

extern char **environ;

@interface TSInjectedTouchClient () {
    int _socketFD;
    pid_t _springBoardPid;
    BOOL _injected;
    BOOL _injectFailed;
}
@end

@implementation TSInjectedTouchClient

+ (instancetype)shared {
    static TSInjectedTouchClient *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TSInjectedTouchClient alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _socketFD = -1;
        _springBoardPid = -1;
    }
    return self;
}

- (BOOL)isConnected {
    return _socketFD >= 0;
}

- (pid_t)springBoardPid {
    return _springBoardPid;
}

- (NSString *)statusDescription {
    if (_injectFailed) {
        return @"注入失败(无法注入 SpringBoard)";
    }
    if (!_injected) {
        return @"未注入";
    }
    if (_socketFD < 0) {
        return @"已注入但未连接";
    }
    return [NSString stringWithFormat:@"已注入 SpringBoard(pid=%d), socket 已连接", _springBoardPid];
}

#pragma mark - SpringBoard pid

- (pid_t)findSpringBoardPid {
    // launchctl list 输出: PID  Status  Label; SpringBoard 的 label 为 com.apple.SpringBoard
    FILE *fp = popen("launchctl list | grep com.apple.SpringBoard", "r");
    if (!fp) return -1;

    char line[256];
    pid_t pid = -1;
    while (fgets(line, sizeof(line), fp)) {
        int p = -1;
        if (sscanf(line, "%d", &p) == 1 && p > 0) {
            pid = p;
            break;
        }
    }
    pclose(fp);
    return pid;
}

#pragma mark - 文件部署 (opainject + dylib -> Documents)

- (BOOL)deployBinaries {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) return NO;
    NSString *binDir = [docs stringByAppendingPathComponent:@"bin"];
    [fm createDirectoryAtPath:binDir withIntermediateDirectories:YES attributes:nil error:NULL];

    // 注入器 (bundle/bin/opainject -> Documents/bin/opainject)
    NSString *injectorSrc = [[NSBundle mainBundle] pathForResource:@"opainject" ofType:nil inDirectory:@"bin"];
    NSString *injectorDst = [binDir stringByAppendingPathComponent:@"opainject"];
    if (!injectorSrc) {
        NSLog(@"[TSInjectedTouch] bundle 中找不到 opainject");
        return NO;
    }
    if (![fm fileExistsAtPath:injectorDst]) {
        [fm copyItemAtPath:injectorSrc toPath:injectorDst error:NULL];
    }
    chmod(injectorDst.UTF8String, 0755);

    // 触摸服务 dylib (bundle/bin/TSInjectedTouchService.dylib -> Documents/bin/)
    NSString *dylibSrc = [[NSBundle mainBundle] pathForResource:@"TSInjectedTouchService" ofType:@"dylib" inDirectory:@"bin"];
    NSString *dylibDst = [binDir stringByAppendingPathComponent:@"TSInjectedTouchService.dylib"];
    if (!dylibSrc) {
        NSLog(@"[TSInjectedTouch] bundle 中找不到 TSInjectedTouchService.dylib");
        return NO;
    }
    if (![fm fileExistsAtPath:dylibDst]) {
        [fm copyItemAtPath:dylibSrc toPath:dylibDst error:NULL];
    }
    chmod(dylibDst.UTF8String, 0755);

    NSLog(@"[TSInjectedTouch] 部署完成: %@", dylibDst);
    return YES;
}

#pragma mark - 注入

- (BOOL)injectSpringBoard {
    pid_t pid = [self findSpringBoardPid];
    if (pid <= 0) {
        NSLog(@"[TSInjectedTouch] 未找到 SpringBoard 进程");
        return NO;
    }
    _springBoardPid = pid;

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *injectorPath = [docs stringByAppendingPathComponent:@"bin/opainject"];
    NSString *dylibPath = [docs stringByAppendingPathComponent:@"bin/TSInjectedTouchService.dylib"];

    // opainject <pid> <dylib_path>
    const char *args[] = {
        injectorPath.UTF8String,
        [NSString stringWithFormat:@"%d", pid].UTF8String,
        dylibPath.UTF8String,
        NULL
    };

    pid_t child = -1;
    int rc = posix_spawn(&child, injectorPath.UTF8String, NULL, NULL,
                         (char *const *)args, environ);
    if (rc != 0) {
        NSLog(@"[TSInjectedTouch] posix_spawn opainject 失败: %d (%s)", rc, strerror(rc));
        return NO;
    }

    int status = 0;
    waitpid(child, &status, 0);
    NSLog(@"[TSInjectedTouch] opainject 退出, status=%d (pid=%d)", status, pid);
    // opainject 正常退出即注入完成 (注入错误会输出到 stderr)
    return WIFEXITED(status);
}

#pragma mark - socket

- (BOOL)connectSocket {
    if (_socketFD >= 0) return YES;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(TS_TOUCH_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    struct timeval tv = {1, 0}; // 1s 连接超时
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return NO;
    }
    _socketFD = fd;
    NSLog(@"[TSInjectedTouch] socket 已连接 127.0.0.1:%d", TS_TOUCH_PORT);
    return YES;
}

- (BOOL)ensureInjected {
    if (_injected && _socketFD >= 0) return YES;
    if (_injectFailed) return NO;

    if (![self deployBinaries]) {
        _injectFailed = YES;
        return NO;
    }

    // 注入 + 等待服务端就绪 (最多 ~4s)
    for (int attempt = 0; attempt < 3; attempt++) {
        if (![self injectSpringBoard]) {
            // opainject 本身失败, 不再重试
            _injectFailed = YES;
            return NO;
        }
        // 等待 dylib 加载 + socket server 启动
        for (int i = 0; i < 10; i++) {
            usleep(200 * 1000);
            if ([self connectSocket]) {
                _injected = YES;
                return YES;
            }
        }
        NSLog(@"[TSInjectedTouch] 第 %d 次注入后未连上服务, 重试", attempt + 1);
    }
    _injectFailed = YES;
    return NO;
}

#pragma mark - 发送

- (void)sendTouchType:(uint8_t)type index:(uint8_t)index point:(CGPoint)point {
    if (![self ensureInjected]) return;

    // 归一化坐标 (物理像素 / 屏幕物理尺寸)
    CGRect bounds = [UIScreen mainScreen].bounds;
    float x = bounds.size.width  > 0 ? (float)(point.x / bounds.size.width)  : 0.0f;
    float y = bounds.size.height > 0 ? (float)(point.y / bounds.size.height) : 0.0f;

    uint8_t cmd[2 + TS_TOUCH_PER_FINGER];
    cmd[0] = TS_TOUCH_MAGIC;
    cmd[1] = 1;                      // count
    cmd[2] = (uint8_t)(type & 0xFF); // type
    cmd[3] = (uint8_t)(index & 0xFF);// index
    memcpy(cmd + 4, &x, 4);
    memcpy(cmd + 8, &y, 4);

    ssize_t n = send(_socketFD, cmd, sizeof(cmd), 0);
    if (n < 0) {
        // 连接断开, 关闭以便下次重连
        close(_socketFD);
        _socketFD = -1;
    }
}

@end
