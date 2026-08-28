//
//  TSDaemonManager.m
//  TrollAutoTouch
//
//  后台守护实现。
//  保活主通道: location 后台模式 + 持续定位 (TSLocationKeepAlive, 导航类机制,
//  iOS 16 官方认可无限后台, 无需 platform 身份, TrollStore 下可用)。
//  辅助: 静音音频 (TSAudioKeepAlive) + URLSession 认证挂起 (TSAuthKeepAlive) +
//  beginBackgroundTask + 系统级悬浮窗。
//

#import "TSDaemonManager.h"
#import "TSHUDWindow.h"
#import "TSHTTPServer.h"
#import "TSScreenCapture.h"
#import "TSDeviceInfo.h"
#import "TSLogStore.h"
#import "TSLuaBridge.h"
#import "TSAudioKeepAlive.h"
#import "TSAuthKeepAlive.h"
#import "TSLocationKeepAlive.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <math.h>

@interface TSDaemonManager ()
@property (nonatomic, assign) TSDaemonState state;
@property (nonatomic, assign) BOOL isInBackground;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTaskId;
@property (nonatomic, assign) BOOL hudVisible;
@property (nonatomic, assign) BOOL silentStarted;  // 静音保活是否已启动(幂等保护)
@end

@implementation TSDaemonManager

+ (instancetype)shared {
    static TSDaemonManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[TSDaemonManager alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = TSDaemonStateStopped;
        _bgTaskId = UIBackgroundTaskInvalid;
        _hudVisible = NO;
        [self registerNotifications];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopAll];
}

#pragma mark - 应用生命周期监听

- (void)registerNotifications {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(appDidEnterBackground:)
               name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(appWillEnterForeground:)
               name:UIApplicationWillEnterForegroundNotification object:nil];
    [nc addObserver:self selector:@selector(appWillTerminate:)
               name:UIApplicationWillTerminateNotification object:nil];
    // 音频中断/重置/前后台自愈统一由 TSAudioKeepAlive 处理, 此处不再重复注册
}

- (void)appDidEnterBackground:(NSNotification *)note {
    // TAS 服务开关关闭时不做后台保活 (用户明确停用服务)
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL tasOn = [ud objectForKey:@"TASServiceEnabled"] ? [ud boolForKey:@"TASServiceEnabled"] : YES;
    if (!tasOn) {
        NSLog(@"[Daemon] TAS 服务已关闭, 跳过后台保活");
        [self log:@"TAS 服务已关闭, 跳过后台保活"];
        return;
    }

    NSLog(@"[Daemon] 应用进入后台");
    [self log:@"应用进入后台"];
    _isInBackground = YES;
    _state = TSDaemonStateBackground;

    // 自动开始后台保活: 定位持续保活(主) + 静音音频(辅) + network-authentication 认证挂起 + 后台任务兜底。
    // 对齐 AutoGoRunner(无忧IOS, iOS 16.x 实测有效)的保活组合, 查证结论见 project.yml:
    //   (1) location 后台模式 + 持续定位(TSLocationKeepAlive) —— 导航类机制,
    //       iOS 16 官方认可后台无限运行, 无需 platform 身份, 保活主通道;
    //   (2) audio 静音 AVAudioPlayer(TSAudioKeepAlive) —— 辅助(已被 iOS 16 静音
    //       审计判定为无声播放, 不提供持续后台, 保留作无定位场景兜底);
    //   (3) network-authentication(TSAuthKeepAlive) —— 辅助认证挑战挂起。
    // 注意: 不注册 PushKit — iOS 16 起声明 voip 后台模式但 PushKit 注册失败
    // 的 app 会被系统启动时强制终止(TrollStore 下 aps-environment 无效必然失败)。
    [[TSLocationKeepAlive shared] start];
    [[TSAuthKeepAlive shared] start];
    [self startSilentAudio];
    [self beginBackgroundTask];
}

- (void)appWillEnterForeground:(NSNotification *)note {
    _isInBackground = NO;
    _state = TSDaemonStateRunning;
    [self endBackgroundTask];
}

- (void)appWillTerminate:(NSNotification *)note {
    NSLog(@"[Daemon] 应用即将终止");
    [self stopAll];
}

#pragma mark - 服务控制

- (void)startAll {
    if (_state == TSDaemonStateRunning) return;

    _state = TSDaemonStateStarting;
    NSLog(@"[Daemon] 启动所有后台服务...");

    // 静默检查通知权限状态（不弹窗，依赖 entitlements 预授权）
    [self checkNotificationPermission];

    // 悬浮窗默认关闭，用户可通过界面手动开启

    _state = TSDaemonStateRunning;
    NSLog(@"[Daemon] 所有服务已启动");
}

- (void)stopAll {
    [self stopSilentAudio];
    [[TSAuthKeepAlive shared] stop];
    [[TSLocationKeepAlive shared] stop];
    [self endBackgroundTask];
    [self hideHUD];
    _state = TSDaemonStateStopped;
    NSLog(@"[Daemon] 所有服务已停止");
    [self log:@"所有服务已停止"];
}

#pragma mark - 后台保活

- (void)beginBackgroundTask {
    if (_bgTaskId != UIBackgroundTaskInvalid) return;

    _bgTaskId = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"TrollAutoTouch.Daemon"
                                                              expirationHandler:^{
        NSLog(@"[Daemon] 后台任务即将到期，重新申请...");
        [[TSDaemonManager shared] log:@"后台任务即将到期, 重新申请"];
        [[TSDaemonManager shared] endBackgroundTask];
        [[TSDaemonManager shared] beginBackgroundTask];
    }];

    NSLog(@"[Daemon] 后台任务已开始: %lu", (unsigned long)_bgTaskId);
    [self log:[NSString stringWithFormat:@"后台任务已开始: %lu", (unsigned long)_bgTaskId]];
}

- (void)endBackgroundTask {
    if (_bgTaskId == UIBackgroundTaskInvalid) return;

    [[UIApplication sharedApplication] endBackgroundTask:_bgTaskId];
    NSLog(@"[Daemon] 后台任务已结束: %lu", (unsigned long)_bgTaskId);
    [self log:[NSString stringWithFormat:@"后台任务已结束: %lu", (unsigned long)_bgTaskId]];
    _bgTaskId = UIBackgroundTaskInvalid;
}

// 静默音频保活: 委托给 TSAudioKeepAlive(单例 + 引用计数)。
// 对齐 AutoGoRunner(无忧IOS): AVAudioPlayer 无限循环播放运行时生成的
// 16kHz 全零静音 WAV(volume=0.0), iOS 16.6 实测保活有效。
// TSAudioKeepAlive 内部处理音频中断/服务重置/前后台自愈, 这里只负责
// 进入后台时启动、服务停止时关闭, 用 silentStarted 保证引用计数平衡。
- (void)startSilentAudio {
    if (_silentStarted) return;
    _silentStarted = YES;
    [[TSAudioKeepAlive shared] start];
    NSLog(@"[Daemon] 静默音频保活已启动 (AVAudioPlayer, 对齐 AutoGoRunner)");
    [self log:@"静默音频保活已启动 (AVAudioPlayer 16kHz 全零 WAV)"];
}

- (void)stopSilentAudio {
    if (!_silentStarted) return;
    _silentStarted = NO;
    [[TSAudioKeepAlive shared] stop];
    NSLog(@"[Daemon] 静默音频保活已停止");
}

// 探针 timer 与 writeProbe 已移除(2026-08-28): 每 5s 一条 [保活] 探针日志写入
// TSLogStore 属纯诊断输出, 高频写日志浪费 CPU/IO/内存, 用户确认删除。保活机制
// 本身(location/audio/auth/后台任务)不受影响。

- (void)log:(NSString *)msg {
    [[TSLogStore shared] append:[NSString stringWithFormat:@"[守护] %@", msg]];
}

#pragma mark - HUD 控制

- (void)showHUD {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_hudVisible) return;
        [[TSHUDWindow shared] show];
        self->_hudVisible = YES;
        NSLog(@"[Daemon] HUD 已显示");
    });
}

- (void)hideHUD {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_hudVisible) return;
        [[TSHUDWindow shared] hide];
        self->_hudVisible = NO;
        NSLog(@"[Daemon] HUD 已隐藏");
    });
}

- (BOOL)isHUDVisible {
    return _hudVisible;
}

- (NSTimeInterval)backgroundTimeRemaining {
    return [[UIApplication sharedApplication] backgroundTimeRemaining];
}

#pragma mark - 通知

/// 静默检查通知权限状态（绝对不弹窗询问用户，权限由 entitlements 预授权）
- (void)checkNotificationPermission {
    if (@available(iOS 10.0, *)) {
        [[UNUserNotificationCenter currentNotificationCenter]
            getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            switch (settings.authorizationStatus) {
                case UNAuthorizationStatusAuthorized:
                case UNAuthorizationStatusProvisional:
                    NSLog(@"[Daemon] 通知已授权 (status=%ld)", (long)settings.authorizationStatus);
                    break;
                case UNAuthorizationStatusDenied:
                    NSLog(@"[Daemon] 通知被拒绝，entitlements 可能未生效");
                    break;
                case UNAuthorizationStatusNotDetermined:
                    // 不调用 requestAuthorization！依赖 entitlements 预授权
                    // 如果 entitlements 生效，此处正常应为 Authorized
                    NSLog(@"[Daemon] 通知状态未确定，依赖 com.apple.private.tcc.allow 预授权");
                    break;
                default:
                    NSLog(@"[Daemon] 通知状态未知: %ld", (long)settings.authorizationStatus);
                    break;
            }
        }];
    }
}

- (void)postLocalNotification:(NSString *)title body:(NSString *)body {
    if (@available(iOS 10.0, *)) {
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = title;
        content.body = body;
        content.sound = [UNNotificationSound defaultSound];

        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger
            triggerWithTimeInterval:1 repeats:NO];

        UNNotificationRequest *request = [UNNotificationRequest
            requestWithIdentifier:@"TrollAutoTouch.Daemon"
            content:content trigger:trigger];

        [[UNUserNotificationCenter currentNotificationCenter]
            addNotificationRequest:request withCompletionHandler:nil];
    }
}

@end
