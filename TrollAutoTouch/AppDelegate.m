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

@interface AppDelegate ()
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // ── 确保目录存在 ──
    [TSPaths ensureDirectoriesExist];

    // ── 同步内置脚本到脚本目录(不覆盖用户已有文件) ──
    [self _syncBuiltinScripts];

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

// 把打包进 App 的内置脚本(bundle 的 lua/ 目录)首次同步到 /var/mobile/touch/lua/
- (void)_syncBuiltinScripts {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *src = [[NSBundle mainBundle] pathForResource:@"main" ofType:@"lua" inDirectory:@"lua"];
    if (!src) return;

    NSString *dst = [TSPaths pathForLua:@"main.lua"];
    if ([fm fileExistsAtPath:dst]) return; // 用户已有则保留用户版本

    NSError *err = nil;
    if ([fm copyItemAtPath:src toPath:dst error:&err]) {
        NSLog(@"[TrollAutoTouch] 已同步内置脚本: %@", dst);
    } else {
        NSLog(@"[TrollAutoTouch] 同步内置脚本失败: %@", err);
    }
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
