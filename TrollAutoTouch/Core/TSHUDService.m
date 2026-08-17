//
//  TSHUDService.m — HUD 全局弹窗服务客户端
//
//  架构 (与原版 TrollAutoScript 的 HUDServices 一致):
//  主 App ──(CPDistributedMessagingCenter)──> HUDServices (独立隐藏 app)
//    1. 主 App 把随包分发的 HUD/HUDServices.app 复制出来并用 MobileInstallation 安装
//    2. 启动 HUD (LSApplicationWorkspace / SBSLaunchApplicationWithIdentifier)
//    3. 通过 CPDistributedMessagingCenter 发送 "sysAlertRequest:" 消息
//    4. HUD 把自己激活到前台, 在高 windowLevel 窗口上 present UIAlertController
//    5. 用户点击后 HUD 通过 sendReplyForMessage: 同步回复结果, 并把前台交还给原 app
//    6. 主 App 恢复脚本继续执行
//

#import "TSHUDService.h"
#import "TSHUDPrivate.h"
#import "TSAppManager.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <unistd.h>

static NSString *const kHUDBundleIdentifier = @"com.trollautotouch.HUDServices";
static NSString *const kHUDCenterName = @"com.trollautotouch.HUDMessaging";
static NSString *const kAlertRequestName = @"sysAlertRequest:";

@interface TSHUDService ()
- (BOOL)_installWithMobileInstallation:(NSString *)appPath;
- (NSDictionary *)_sendRequest:(NSDictionary *)userInfo timeout:(NSTimeInterval)timeout;
@end

@implementation TSHUDService

+ (instancetype)sharedInstance {
    static TSHUDService *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

#pragma mark - 部署

- (BOOL)isHUDInstalled {
    return [[TSAppManager shared] isInstalled:kHUDBundleIdentifier];
}

- (BOOL)installHUD {
    // 1. 定位随主包分发的 HUD/HUDServices.app
    NSString *sourcePath = [[NSBundle mainBundle] pathForResource:@"HUDServices"
                                                          ofType:@"app"
                                                     inDirectory:@"HUD"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
        NSLog(@"[TSHUDService] 主 bundle 中未找到 HUD/HUDServices.app (%@)", sourcePath);
        return NO;
    }

    // 2. 复制到本 App 数据容器 (no-sandbox 下可写)
    NSString *docDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *destPath = [docDir stringByAppendingPathComponent:@"HUDServices.app"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:destPath error:nil];
    if (![fm copyItemAtPath:sourcePath toPath:destPath error:nil]) {
        NSLog(@"[TSHUDService] 复制 HUD.app 到 %@ 失败", destPath);
        return NO;
    }

    // 3. 用 MobileInstallation 注册安装 (InstallForLaunchServices 变体优先)
    if ([self _installWithMobileInstallation:destPath]) {
        NSLog(@"[TSHUDService] HUD 安装成功: %@", destPath);
        return YES;
    }

    // 4. 回退: LSApplicationWorkspace 直接注册
    BOOL ok = [[TSAppManager shared] installIPA:destPath];
    NSLog(@"[TSHUDService] HUD 安装(%@): %d", ok ? @"LSWorkspace" : @"失败", ok);
    return ok;
}

- (BOOL)_installWithMobileInstallation:(NSString *)appPath {
    static void (*installForLS)(NSString *, NSDictionary *, void (^)(NSDictionary *)) = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation",
                              RTLD_LAZY);
        if (handle) {
            installForLS = dlsym(handle, "MobileInstallationInstallForLaunchServices");
        }
    });
    if (!installForLS) {
        return NO;
    }

    __block BOOL success = NO;
    __block BOOL finished = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    installForLS(appPath, @{}, ^(NSDictionary *result) {
        if (result[@"Success"] || result[@"Error"] == nil) {
            success = YES;
        } else {
            NSLog(@"[TSHUDService] MobileInstallation 返回错误: %@", result[@"Error"]);
        }
        finished = YES;
        dispatch_semaphore_signal(sem);
    });

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
    return finished && success;
}

- (BOOL)ensureHUDRunning {
    // 未安装则先安装
    if (![self isHUDInstalled]) {
        if (![self installHUD]) {
            return NO;
        }
    }
    // 每次请求都激活 HUD: 对未运行进程=启动; 对后台挂起进程=恢复运行并带到前台。
    // 激活后 HUD 才处于前台并运行 runloop, 才能处理消息中心的弹窗请求。
    if (![[TSAppManager shared] openApp:kHUDBundleIdentifier]) {
        NSLog(@"[TSHUDService] 启动/激活 HUD 失败");
        return NO;
    }
    // 等待 HUD 完成启动与消息中心注册 (首次启动较慢)
    usleep(600000);
    return YES;
}

#pragma mark - 全局弹窗

- (NSString *)showAlertWithTitle:(NSString *)title
                         message:(NSString *)message
                         buttons:(NSArray<NSString *> *)buttons
                         timeout:(NSTimeInterval)timeout {
    if (![self ensureHUDRunning]) {
        NSLog(@"[TSHUDService] HUD 不可用, 全局弹窗失败");
        return nil;
    }

    // 记录当前前台 app, 弹窗结束后由 HUD 交还前台
    NSString *frontBid = [[TSAppManager shared] frontBid];
    if ([frontBid isEqualToString:kHUDBundleIdentifier]) {
        frontBid = nil;
    }

    NSDictionary *userInfo = @{
        @"title"       : title ?: @"",
        @"message"     : message ?: @"",
        @"buttons"     : buttons ?: @[],
        @"timeout"     : @(timeout),
        @"previousApp" : frontBid ?: @"",
    };

    // 发送请求并等待回复; 首次失败(HUD 尚未注册中心)时重新激活后重试一次。
    NSDictionary *reply = [self _sendRequest:userInfo timeout:timeout];
    if (!reply) {
        NSLog(@"[TSHUDService] HUD 未响应, 重新激活后重试");
        [[TSAppManager shared] openApp:kHUDBundleIdentifier];
        usleep(800000);
        reply = [self _sendRequest:userInfo timeout:timeout];
    }

    NSString *result = reply[@"result"];
    return (result.length > 0) ? result : nil;
}

// 在后台线程发送并同步等待回复, 避免阻塞 Lua 脚本线程过久;
// 上层 Lua 线程用超时兜底, 防止 HUD 无响应时挂死脚本。
- (NSDictionary *)_sendRequest:(NSDictionary *)userInfo timeout:(NSTimeInterval)timeout {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *reply = nil;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            CPDistributedMessagingCenter *center =
                [CPDistributedMessagingCenter centerNamed:kHUDCenterName];
            reply = [center sendMessageAndReceiveReplyName:kAlertRequestName userInfo:userInfo];
        } @catch (NSException *exception) {
            NSLog(@"[TSHUDService] 发送弹窗请求异常: %@", exception);
        }
        dispatch_semaphore_signal(sem);
    });

    // 等待上限: 弹窗超时 + 15s 缓冲; 永久弹窗等待 60s 后放弃
    NSTimeInterval maxWait = (timeout > 0 ? timeout : 60) + 15;
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(maxWait * NSEC_PER_SEC)));
    return reply;
}

@end
