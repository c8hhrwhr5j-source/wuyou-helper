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
#import "Script/TSLuaBridge.h"
#import "Script/TSHTTPServer.h"
#import "Common/TSPaths.h"

// TAS 服务开关 key (与 TSSettingsViewController 一致, 默认开)
static NSString *const kTASServiceEnabledKey = @"TASServiceEnabled";

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
    // TAS 服务开关(默认开)决定服务是否启动:
    //   开 → startAll + 常驻音量键监听 + 远程访问 HTTP 服务(默认常开);
    //   关 → 不启动, 用户可在设置页手动开启。
    // 远程访问端口跟随 TAS 服务联动: TAS 开启即监听 8080, 关闭即停止。
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL tasOn = [ud objectForKey:kTASServiceEnabledKey] ? [ud boolForKey:kTASServiceEnabledKey] : YES;
    if (tasOn) {
        [[TSDaemonManager shared] startAll];
        [[TSLuaBridge shared] startGlobalVolumeMonitoring];
        [[TSHTTPServer shared] start];
    }

    // ── 预热进程内 HUD 宿主（单 App 架构）──
    // 提前创建 HUD 全屏透明窗口 (窗口内 hitTest 穿透, 不托管时不影响触摸)。
    // SBS 系统级托管为惰性注册: 仅在弹出弹窗/toast/承载 UI 时注册,
    // 内容清空即注销, 避免后台时全屏托管窗口吞掉整个屏幕的触摸。
    [[TSHUDHost shared] start];
    // 冷启动预热: 预创建 SBS 托管所需的 CAContext (contextId 非零)。
    // 否则冷启动后首次按音量键时, 托管注册首次创建 CAContext 常失败
    // (app 刚启动 CA/WindowServer 管线未就绪), 而弹窗又因"未注册且后台"
    // 立即中止注册重试 → 前几次按键弹窗被静默跳过,
    // 表现为"启动 App 后要按 4 次音量键才弹出暂停/运行按钮"。
    // 预热成功后首次按键即秒开弹窗 (只预创建 context, 不注册托管)。
    [[TSHUDHost shared] prepareOverlayContext];

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
