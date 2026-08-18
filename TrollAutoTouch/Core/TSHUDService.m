//
//  TSHUDService.m — HUD 全局弹窗服务客户端
//
//  架构 (与原版 TrollAutoScript 的 HUDServices 一致):
//  主 App ──(CPDistributedMessagingCenter)──> HUDServices (独立隐藏 app)
//    1. 主 App 把随包分发的 HUD/HUDServices.app 复制出来并安装
//       (经 TSAppManager, 内部探测 MobileInstallation 权限: 未生效时
//        自动跳过该私有 API 以免崩溃, 回退 LSApplicationWorkspace)
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

// 运行时获取 CPDistributedMessagingCenter 类 (来自私有框架 AppSupport)。
// 主 App 未开启 -Wl,-undefined,dynamic_lookup, 直接引用类会产生链接错误,
// 因此必须通过 NSClassFromString 在运行时查找, 编译期不产生类符号引用。
static id HUDMessagingCenter(void) {
    Class cls = NSClassFromString(@"CPDistributedMessagingCenter");
    if (!cls) {
        NSLog(@"[TSHUDService] 未找到 CPDistributedMessagingCenter 类");
        return nil;
    }
    return [cls centerNamed:kHUDCenterName];
}

@interface TSHUDService ()
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
    // 安装节流: 失败后 30 秒内不重复尝试 (音量键连按时避免反复复制/安装)
    static NSTimeInterval s_lastAttempt = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if ((now - s_lastAttempt) < 30) {
        NSLog(@"[TSHUDService] 距上次安装尝试不足 30s, 跳过 (节流)");
        return NO;
    }
    s_lastAttempt = now;

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

    // 3. 经 TSAppManager 安装。注意: 不能直接调 MobileInstallation 私有 API ——
    //    该 API 要求调用者实际拥有 MobileInstallationHelper 权限, 而
    //    iOS 15.5+ 的 TrollStore 无法授予 platform 身份, 无权限直接调用
    //    会崩溃 (此前线上版本正是因此闪退)。TSAppManager 内部会用
    //    canUseMobileInstallation 探测, 未生效时自动回退 LSApplicationWorkspace
    //    (不崩溃, 失败仅返回 NO)。
    BOOL ok = [[TSAppManager shared] installIPA:destPath];
    if (ok) {
        NSLog(@"[TSHUDService] HUD 安装成功: %@", destPath);
    } else {
        NSLog(@"[TSHUDService] HUD 安装失败 (MobileInstallation 权限不可用, 已安全回退)");
    }
    return ok;
}

- (BOOL)ensureHUDRunning {
    // 未安装则先安装
    if (![self isHUDInstalled]) {
        if (![self installHUD]) {
            return NO;
        }
    }
    // 已在运行则直接复用, 避免重复 SBS launch 与额外等待 (音量键连按时秒弹窗)
    if ([[TSAppManager shared] isRunning:kHUDBundleIdentifier]) {
        return YES;
    }
    // 后台启动 HUD (suspended=YES, 不抢前台)。HUD 通过
    // SBSAccessibilityWindowHostingController 把窗口托管到系统级,
    // 在后台即可显示全局弹窗, 无需位于前台。
    if (![[TSAppManager shared] launchAppInBackground:kHUDBundleIdentifier]) {
        NSLog(@"[TSHUDService] 后台启动 HUD 失败, 回退前台启动");
        if (![[TSAppManager shared] openApp:kHUDBundleIdentifier]) {
            return NO;
        }
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

    // 记录当前前台 app: HUD 仅在系统级托管失败的兜底路径下,
    // 才会把自己激活到前台, 此时弹窗结束后需交还前台。
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
            id center = HUDMessagingCenter();
            if (center) {
                reply = [center sendMessageAndReceiveReplyName:kAlertRequestName userInfo:userInfo];
            }
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
