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
#import "Common/TSTCCRequestor.h"

@interface AppDelegate ()
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // ── 确保目录存在 ──
    [TSPaths ensureDirectoriesExist];

    // ── 创建主窗口（旧式 UIWindow，不依赖 UIScene）──
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [TSColors bg];
    self.window.rootViewController = [[MainTabBarController alloc] init];
    [self.window makeKeyAndVisible];

    // ── 启动核心服务 ──
    [[TSDaemonManager shared] startAll];

    // ── 创建 HUD 悬浮窗（延迟到主循环下一帧，确保窗口层级正确）──
    dispatch_async(dispatch_get_main_queue(), ^{
        [[TSHUDWindow shared] show];
    });

    // ── 首次启动时批量触发隐私权限请求，填充 iOS Settings 隐私列表 ──
    [TSTCCRequestor requestAllPermissionsIfNeeded];

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
    if ([[TSHUDWindow shared] isHidden]) {
        [[TSHUDWindow shared] show];
    }
}

@end
