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
#import "Core/TSAuthKeepAlive.h"
#import "Core/TSNetworkAuth.h"
#import "Core/TSLicense.h"
#import "Core/TSTrialManager.h"
#import "Core/TSToolExecutor.h"
#import "Script/TSLuaBridge.h"
#import "Script/TSHTTPServer.h"
#import "Common/TSPaths.h"
#import "Common/TSLogStore.h"
#import "Core/TSScreenCapture.h"
#import <mach/mach.h>
#import <malloc/malloc.h>

// TAS 服务开关 key (与 TSSettingsViewController 一致, 默认开)
static NSString *const kTASServiceEnabledKey = @"TASServiceEnabled";

@interface AppDelegate ()
- (void)_logMemoryDiag:(NSString *)tag;
- (void)_startMemoryDiag;
- (void)_startControlServer;
@property (nonatomic, strong, nullable) TSHTTPServer *controlServer;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // ── 屏幕常亮: 打开 app 即禁止系统自动锁屏, 直到 app 退出 ──
    // (脚本挂机/网页设置 UI 操作期间均保持屏幕点亮)
    application.idleTimerDisabled = YES;

    // ── 确保目录存在 ──
    [TSPaths ensureDirectoriesExist];

    // ── 冷启动清空 runtime: 清除加密项目(.tas)上次运行留下的临时资源目录,
    //    以及旧版本曾解密滞留的明文残留, 保证设备上不长期保留任何解密产物 ──
    [TSPaths cleanupRuntimeDirectory];

    // ── 同步内置脚本到脚本目录(不覆盖用户已有文件) ──
    [self _syncBuiltinScripts];

    // ── 创建主窗口（旧式 UIWindow，不依赖 UIScene）──
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [TSColors bg];
    self.window.rootViewController = [[MainTabBarController alloc] init];
    [self.window makeKeyAndVisible];
    [self _startCoreServices];
    [self _startControlServer];

    // ── 卡密: 已激活无限制; 未激活设备每次启动获得 15 分钟试用窗口,
    //    到期强制停止脚本并阻止新脚本 (可在 设置-卡密 中输入卡密激活) ──
    [[TSTrialManager shared] startIfNeeded];

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

    // ── 预热认证保活会话 ──
    // background session 标识符固定: 若上次运行有未完成任务, 系统冷启动时会恢复,
    // 必须在启动阶段用同一标识符创建 session 并设置 delegate, 否则系统丢弃事件。
    [TSAuthKeepAlive shared];
    // 注册为系统 Wi-Fi 热点认证助手(NEHotspotHelper),
    // 这是 network-authentication 后台豁免的判定依据(对齐原版)。
    [TSNetworkAuth registerHotspotHelper];

    // ── 启动记录版本/机型 + 一次内存基线 ──
    // (曾为定位 iOS16 挂机内存累积加过每 1 分钟周期采样; 20h 长跑实测稳定后
    //  2026-09-03 移除周期采样以消除 touch.log 噪音; 异常时
    //  didReceiveMemoryWarning 仍会带完整截屏统计记录) ──
    [self _startMemoryDiag];

    NSLog(@"[QQ音乐] App 启动完成");
    return YES;
}

// 进程物理内存占用(phys_footprint, 字节)
static unsigned long long TS_physFootprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &cnt) == KERN_SUCCESS) {
        return (unsigned long long)info.phys_footprint;
    }
    return 0;
}

// 进程 VM 细分: 返回 internal/external/compressor 字节
//   internal = 普通匿名内存(堆/malloc 之外的 VM, 含 autorelease 块、CG/图像缓存等)
//   external = IO/GPU 相关内存(IOKit/IOSurface/IOAccelerator 映射 —— createScreenIOSurface
//              系统侧 surface 若未回收, 主要体现为 external 增长)
//   compressor= 已压缩内存(内存压力时的压缩, 涨说明 dirty 内存持续产生)
// 注: iOS SDK 的 task_vm_info 仅含 rev1 字段(到 user_region_count),
//     internal/external/compressed 本身即为字节数; rev2 的 *_page_count 字段 iOS SDK 不存在。
static void TS_vmBreakdown(unsigned long long *internalBytes,
                           unsigned long long *externalBytes,
                           unsigned long long *compressorBytes) {
    task_vm_info_data_t info;
    mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &cnt) != KERN_SUCCESS) {
        *internalBytes = *externalBytes = *compressorBytes = 0;
        return;
    }
    *internalBytes = (unsigned long long)info.internal;
    *externalBytes = (unsigned long long)info.external;
    *compressorBytes = (unsigned long long)info.compressed;
}

// 进程 malloc 堆总占用(默认 zone size_in_use, 字节)
// 用于区分"进程内 malloc/ObjC 对象泄漏" vs "系统侧 IO/GPU surface 累积":
//   heap 涨而 external 不涨 → 进程内泄漏(对象/缓冲未释放)
//   external 涨而 heap 稳  → 系统侧 createScreenIOSurface 未回收(与日志 71MB/h 最吻合)
static unsigned long long TS_mallocInUse(void) {
    malloc_statistics_t stats;
    // malloc_zone_statistics 返回 void(无错误指示), 直接读取统计即可
    malloc_zone_statistics(malloc_default_zone(), &stats);
    return (unsigned long long)stats.size_in_use;
}

- (void)_logMemoryDiag:(NSString *)tag {
    unsigned long long fp = TS_physFootprint();
    unsigned long long internalBytes = 0, externalBytes = 0, compressorBytes = 0;
    TS_vmBreakdown(&internalBytes, &externalBytes, &compressorBytes);
    unsigned long long heap = TS_mallocInUse();
    unsigned long long uptime = (unsigned long long)[NSProcessInfo processInfo].systemUptime;
    [[TSLogStore shared] append:[NSString stringWithFormat:
        @"[内存] %@ t=%.1fh footprint=%.1fMB heap=%.1fMB vm内部=%.1fMB 外部=%.1fMB 压缩=%.1fMB",
        tag,
        uptime / 3600.0,
        fp / 1024.0 / 1024.0,
        heap / 1024.0 / 1024.0,
        internalBytes / 1024.0 / 1024.0,
        externalBytes / 1024.0 / 1024.0,
        compressorBytes / 1024.0 / 1024.0]];
}

- (void)_startMemoryDiag {
    NSDictionary *infoDict = [NSBundle mainBundle].infoDictionary;
    NSString *ver = infoDict[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = infoDict[@"CFBundleVersion"] ?: @"?";
    NSString *model = nil;
    @try {
        id m = [[UIDevice currentDevice] valueForKey:@"modelIdentifier"];
        if ([m isKindOfClass:[NSString class]] && [m length]) { model = m; }
    } @catch (NSException *e) {}
    if (!model) { model = [[UIDevice currentDevice] model]; }
    [[TSLogStore shared] append:[NSString stringWithFormat:@"[启动] v%@(b%@) iOS%@ %@",
        ver, build, [UIDevice currentDevice].systemVersion, model]];
    // 仅启动时记录一次精简内存基线(不再周期采样)
    [self _logMemoryDiag:@"启动基线"];
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
            NSLog(@"[QQ音乐] 删除旧脚本失败: %@", err);
            return;
        }
        NSLog(@"[QQ音乐] 旧脚本与内置版本不一致，已删除待更新: %@", dst);
    }

    if ([fm copyItemAtPath:src toPath:dst error:&err]) {
        NSLog(@"[QQ音乐] 已同步内置脚本: %@", dst);
    } else {
        NSLog(@"[QQ音乐] 同步内置脚本失败: %@", err);
    }
}

// ── 启动核心服务（悬浮窗默认关闭，用户手动开启）──
// TAS 服务开关(默认开)决定服务是否启动:
//   开 → startAll + 常驻音量键监听 + 远程访问 HTTP 服务(默认常开);
//   关 → 不启动, 用户可在设置页手动开启。
// 远程访问端口跟随 TAS 服务联动: TAS 开启即监听 8080, 关闭即停止。
- (void)_startCoreServices {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL tasOn = [ud objectForKey:kTASServiceEnabledKey] ? [ud boolForKey:kTASServiceEnabledKey] : YES;
    if (tasOn) {
        [[TSDaemonManager shared] startAll];
        [[TSLuaBridge shared] startGlobalVolumeMonitoring];
        if (![[TSHTTPServer shared] start]) {
            // 修复安装后"假开启": 首次启动 bind/listen 失败则延迟重试
            NSLog(@"[TAS] HTTP 服务启动失败, 1 秒后重试");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (![[TSHTTPServer shared] start]) {
                    NSLog(@"[TAS] HTTP 服务重试仍失败");
                }
            });
        }
    }
}

// ── 冷启动远程控制接口 (端口 TS_COLD_CONTROL_PORT, 默认 8686) ──
// 对齐原版(无忧/AutoGoRunner) 8989 的 /task 远程控制, 独立端口避免与原版工具冲突:
//   GET /task?cmd=start|stop|pause|resume  → 启停/暂停/恢复脚本
//   GET /float?x=0|1&y=<物理像素>           → 移动悬浮球
// 随 App 启动常驻(不依赖调试按钮/TAS 开关), 后台挂机时局域网设备也可随时控制脚本。
- (void)_startControlServer {
    if (!_controlServer) {
        _controlServer = [[TSHTTPServer alloc] initWithPort:TS_COLD_CONTROL_PORT];
        // 不设 delegate: /task 的 start/stop/pause/resume 由 TSHTTPServer 内部
        // 直接驱动 TSLuaBridge/TSScriptEngine, 无 UI 冷启动路径同样可用。
    }
    if (_controlServer.isRunning) return;
    if (![_controlServer start]) {
        [[TSLogStore shared] append:[NSString stringWithFormat:
            @"[HTTP] 远程控制接口启动失败(端口 %d 可能被占用)", TS_COLD_CONTROL_PORT]];
        return;
    }
    NSString *ip = [[TSToolExecutor shared] wifiIPAddress];
    if (ip.length == 0) ip = @"<设备IP>";
    [[TSLogStore shared] append:[NSString stringWithFormat:
        @"[HTTP] 远程控制接口已开启 → http://%@:%d/task?cmd=start|stop|pause|resume",
        ip, TS_COLD_CONTROL_PORT]];
}

- (void)applicationWillResignActive:(UIApplication *)application {
    [[TSLogStore shared] append:@"[App] willResignActive 即将失活"];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [[TSLogStore shared] append:@"[App] didEnterBackground 进入后台"];
    [[TSDaemonManager shared] beginBackgroundTask];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    [[TSLogStore shared] append:@"[App] willEnterForeground 回到前台"];
    [[TSDaemonManager shared] endBackgroundTask];
}

// background URLSession 事件: 系统在后台会话任务完成后唤醒/激活 app 时回调。
// 保活场景任务持续挂起, 此回调仅在任务意外完成时触发, 尽快收尾即可。
- (void)application:(UIApplication *)application
handleEventsForBackgroundURLSession:(NSString *)identifier
  completionHandler:(void (^)(void))completionHandler {
    [[TSLogStore shared] append:[NSString stringWithFormat:@"[认证保活] 后台会话事件: %@", identifier]];
    [TSAuthKeepAlive shared]; // 确保 session 已创建/关联
    if (completionHandler) completionHandler();
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // 激活诊断日志已移除(2026-08-28)
}

// iOS 16 上后台 app 被回收前系统常先发内存警告, 若日志停在内存警告之后
// 基本可判定进程是被 Jetsam 回收(后台保活失效), 而非脚本报错。
- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    unsigned long long fp = TS_physFootprint();
    [[TSLogStore shared] append:[NSString stringWithFormat:@"[App] didReceiveMemoryWarning 收到内存警告! footprint=%.1fMB %@",
        fp / 1024.0 / 1024.0, [[TSScreenCapture shared] statsLine]]];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [[TSLogStore shared] append:@"[App] willTerminate 即将终止"];
}

@end
