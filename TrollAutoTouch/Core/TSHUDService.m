//
//  TSHUDService.m — HUD 全局弹窗服务客户端
//
//  架构 (与原版 TrollAutoScript 的 HUDServices 一致):
//  主 App ──(CPDistributedMessagingCenter)──> HUDServices (独立隐藏 app)
//    1. HUD 作为独立 app 随 tipa 一起由 TrollStore 安装注册 (多 app tipa,
//       与官方 TrollStore.tipa 同机制) —— iOS 15.5+ TrollStore 无 platform
//       身份, 主 App 运行时无法现场安装 .app (MobileInstallation XPC 被拒,
//       LSApplicationWorkspace 又不接受裸 .app 目录), TrollStore 自装是
//       唯一可靠途径; 老设备/越狱环境仍保留 MobileInstallation 现场安装后备
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
    // 新架构 (TrollStore 2.x 多 app tipa): HUD 已作为独立 app 随 tipa 由
    // TrollStore 安装注册到 LaunchServices, 这里直接复用即可。这也说明
    // 用户当前装的 tipa 已包含 HUD Services。
    if ([self isHUDInstalled]) {
        NSLog(@"[TSHUDService] HUD 已被 TrollStore 安装注册, 直接复用");
        return YES;
    }

    // 安装节流: 失败后 30 秒内不重复尝试 (音量键连按时避免反复复制/安装)
    static NSTimeInterval s_lastAttempt = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if ((now - s_lastAttempt) < 30) {
        NSLog(@"[TSHUDService] 距上次安装尝试不足 30s, 跳过 (节流)");
        return NO;
    }
    s_lastAttempt = now;

    // 未注册到 LaunchServices: 说明用户装的是旧版 tipa (不含 HUD Services)。
    // 现场安装不可行 —— iOS 15.5+ TrollStore 无 platform 身份, MobileInstallation
    // 私有 API 的 XPC 连接会被拒绝 (直接调用甚至崩溃); LSApplicationWorkspace
    // installApplication: 只接受 .ipa 文件, 不接受裸 .app 目录。唯一可靠途径是
    // 用 TrollStore 重新安装最新 tipa (内含 HUD Services 独立 app)。
    if (![TSAppManager canUseMobileInstallation]) {
        NSLog(@"[TSHUDService] HUD 未安装且 MobileInstallation 权限不可用, 现场安装不可行。"
              @"请用 TrollStore 重新安装最新 tipa (内含 HUD Services 独立 app), 重装后重启本 App。");
        return NO;
    }

    // 后备 (仅限 MobileInstallation 权限实际生效的设备: palera1n 越狱等):
    // 复制随包分发的 HUD/HUDServices.app 并经 TSAppManager 安装。
    NSString *sourcePath = [[NSBundle mainBundle] pathForResource:@"HUDServices"
                                                          ofType:@"app"
                                                     inDirectory:@"HUD"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
        NSLog(@"[TSHUDService] 主 bundle 中未找到 HUD/HUDServices.app (%@)", sourcePath);
        return NO;
    }
    NSString *docDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *destPath = [docDir stringByAppendingPathComponent:@"HUDServices.app"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:destPath error:nil];
    if (![fm copyItemAtPath:sourcePath toPath:destPath error:nil]) {
        NSLog(@"[TSHUDService] 复制 HUD.app 到 %@ 失败", destPath);
        return NO;
    }
    BOOL ok = [[TSAppManager shared] installIPA:destPath];
    if (ok) {
        NSLog(@"[TSHUDService] HUD 安装成功: %@", destPath);
    } else {
        NSLog(@"[TSHUDService] HUD 现场安装失败 (MobileInstallation 不可用), 请改用 TrollStore 安装最新 tipa");
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
