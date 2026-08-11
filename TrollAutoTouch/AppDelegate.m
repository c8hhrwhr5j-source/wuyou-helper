//
//  AppDelegate.m
//  TrollAutoTouch
//
//  旧式 UIApplicationDelegate — 不使用 SceneDelegate，
//  与 TrollServer 架构一致，避免 UIScene 生命周期冲突。
//

#import "AppDelegate.h"
#import "ViewController.h"
#import "HUD/TSHUDWindow.h"
#import "Core/TSDaemonManager.h"
#import "Core/TSKeyboardInjector.h"
#import "Core/TSToolExecutor.h"

@interface AppDelegate ()
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // ── 创建主窗口（旧式 UIWindow，不依赖 UIScene）──
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor colorWithRed:0.059 green:0.078 blue:0.125 alpha:1.0]; // #0F1420
    self.window.rootViewController = [[ViewController alloc] init];
    [self.window makeKeyAndVisible];

    // ── 启动核心服务 ──
    [[TSDaemonManager shared] startKeepAlive];
    [[TSKeyboardInjector shared] start];

    // ── 创建 HUD 悬浮窗（延迟到主循环下一帧，确保窗口层级正确）──
    dispatch_async(dispatch_get_main_queue(), ^{
        [[TSHUDWindow shared] show];
    });

    appLog(@"App 启动完成 ✓");
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    // 保持后台活
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [[TSDaemonManager shared] enterBackground];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    [[TSDaemonManager shared] enterForeground];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // HUD 恢复显示
    if (![TSHUDWindow shared].hidden) {
        [[TSHUDWindow shared] show];
    }
}

@end
