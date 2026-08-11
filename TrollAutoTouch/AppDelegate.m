//
//  AppDelegate.m
//  TrollAutoTouch
//
//  旧式 UIApplicationDelegate — 不使用 SceneDelegate，
//  与 TrollServer 架构一致，避免 UIScene 生命周期冲突。
//

#import "AppDelegate.h"
#import "MainTabBarController.h"
#import "HUD/TSHUDWindow.h"
#import "Core/TSDaemonManager.h"
#import "Common/TSPaths.h"
#import "Common/TSTCCInjector.h"
#import <dlfcn.h>

@interface AppDelegate ()
@end

@implementation AppDelegate

/// 运行时验证关键 entitlements 是否被 ldid/TrollStore 正确注入
- (void)verifyEntitlements {
    // 检查 1：无沙盒（能读 /var 下文件）
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL canReachTCC = [fm fileExistsAtPath:@"/var/mobile/Library/TCC/TCC.db"];
    NSLog(@"[Entitle] no-sandbox 检查(%@): %@",
          canReachTCC ? @"OK" : @"FAIL",
          canReachTCC ? @"可访问 /var/mobile/Library/TCC/TCC.db" : @"沙盒限制中！entitlements 可能未注入");

    // 检查 2：platform-application（影响所有 com.apple.private.* 权限）
    NSBundle *b = [NSBundle mainBundle];
    NSLog(@"[Entitle] bundleID=%@, 路径=%@", b.bundleIdentifier, b.bundlePath);

    // 检查 3：com.apple.private.tcc.allow 是否生效
    // 通过检查 TCC.db 中是否已有本 app 的授权记录来间接验证
    NSLog(@"[Entitle] TCC 注入将在后台线程执行，请关注后续 [TCC] 日志");
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // ── 确保目录存在 ──
    [TSPaths ensureDirectoriesExist];

    // ── 运行时验证 entitlements ──
    [self verifyEntitlements];

    // ── 运行时注入 TCC 权限（直接写 TCC.db + 重启 tccd）──
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [TSTCCInjector grantAllPermissions];
    });

    // ── 创建主窗口（旧式 UIWindow，不依赖 UIScene）──
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [TSColors bg];
    self.window.rootViewController = [[MainTabBarController alloc] init];
    [self.window makeKeyAndVisible];

    // ── 启动核心服务（悬浮窗默认关闭，用户手动开启）──
    [[TSDaemonManager shared] startAll];

    NSLog(@"[TrollAutoTouch] App 启动完成");
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [[TSDaemonManager shared] beginBackgroundTask];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    [[TSDaemonManager shared] endBackgroundTask];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
}

@end
