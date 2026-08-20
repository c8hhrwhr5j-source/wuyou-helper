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
#import "HUD/TSHUDHost.h"
#import "Core/TSDaemonManager.h"
#import "Common/TSPaths.h"

@interface AppDelegate ()
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // ── 屏幕常亮: 打开 app 即禁止系统自动锁屏, 直到 app 退出 ──
    // (脚本挂机/网页设置 UI 操作期间均保持屏幕点亮)
    application.idleTimerDisabled = YES;

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

    // ── 预热进程内 HUD 宿主（单 App 架构）──
    // 提前创建全屏透明窗口并注册 SBS 系统级托管, 使脚本音量键弹窗/
    // 阻塞确认等全局弹窗即时可用; 失败仅降级, 不影响主流程。
    [[TSHUDHost shared] start];

    NSLog(@"[TrollAutoTouch] App 启动完成");
    return YES;
}

// 把打包进 App 的内置脚本(bundle 的 lua/ 目录)同步到 /var/mobile/touch/lua/
// 策略: 若目标已存在且内容与内置版本不一致，也用内置版本覆盖——
// 因为内置 main.lua 是随包发布的既定脚本，旧的手动上传/损坏版本必须被纠正。
- (void)_syncBuiltinScripts {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *src = [[NSBundle mainBundle] pathForResource:@"main" ofType:@"lua" inDirectory:@"lua"];
    if (!src) return;

    NSString *dst = [TSPaths pathForLua:@"main.lua"];
    NSError *err = nil;

    if ([fm fileExistsAtPath:dst]) {
        NSData *srcData = [NSData dataWithContentsOfFile:src];
        NSData *dstData = [NSData dataWithContentsOfFile:dst];
        if (srcData && dstData && [srcData isEqualToData:dstData]) {
            return; // 已是最新，无需同步
        }
        // 内容不一致: 删除旧文件后重新复制
        if (![fm removeItemAtPath:dst error:&err]) {
            NSLog(@"[TrollAutoTouch] 删除旧脚本失败: %@", err);
            return;
        }
        NSLog(@"[TrollAutoTouch] 旧脚本与内置版本不一致，已删除待更新: %@", dst);
    }

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
