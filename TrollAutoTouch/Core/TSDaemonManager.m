//
//  TSDaemonManager.m
//  TrollAutoTouch
//
//  后台守护实现。
//  通过音频后台模式 + beginBackgroundTask + 系统级悬浮窗实现持久化后台服务。
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
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <math.h>

@interface TSDaemonManager ()
@property (nonatomic, assign) TSDaemonState state;
@property (nonatomic, assign) BOOL isInBackground;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTaskId;
@property (nonatomic, strong) dispatch_source_t probeSource;   // GCD 探针 timer (后台可靠)
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

    // 自动开始后台保活: 静音 AVAudioPlayer + network-authentication 认证挂起 + 后台任务兜底。
    // 对齐 AutoGoRunner(无忧IOS, iOS 16.6 实测有效): UIBackgroundModes 声明 audio,
    // AVAudioPlayer 无限循环播放 16kHz 全零静音 WAV(volume=0), 系统据此豁免挂起。
    // network-authentication(TSAuthKeepAlive) 作为补充的认证挑战挂起。
    // 注意: 不注册 PushKit — iOS 16 起声明 voip 后台模式但 PushKit 注册失败
    // 的 app 会被系统启动时强制终止(TrollStore 下 aps-environment 无效必然失败)。
    [[TSAuthKeepAlive shared] start];
    [self startSilentAudio];
    [self beginBackgroundTask];
    [self startHeartbeat];
}

- (void)appWillEnterForeground:(NSNotification *)note {
    NSLog(@"[Daemon] 应用回到前台");
    [self log:@"应用回到前台"];
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

    // 启动心跳
    [self startHeartbeat];

    // 悬浮窗默认关闭，用户可通过界面手动开启

    _state = TSDaemonStateRunning;
    NSLog(@"[Daemon] 所有服务已启动");
}

- (void)stopAll {
    [self stopHeartbeat];
    [self stopSilentAudio];
    [[TSAuthKeepAlive shared] stop];
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

// GCD 探针 timer: 后台 run loop 不跑时 NSTimer 不触发(iOS 16 上几秒内被挂起),
// 必须用 GCD timer。每 5s 在主线程写一条保活状态到 touch.log。
// 脚本停止后看最后几条探针:
//   - 探针一直写到停止前一刻 → 进程仍在跑, 是脚本 Lua 报错或 app 崩溃;
//   - 探针提前中断(进入后台后很快没新行) → 进程已被挂起/回收, 后台保活失效。
- (void)startHeartbeat {
    [self stopHeartbeat];
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    _probeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(_probeSource,
                              dispatch_time(DISPATCH_TIME_NOW, 5.0 * NSEC_PER_SEC),
                              5.0 * NSEC_PER_SEC,
                              1.0 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_probeSource, ^{
        [weakSelf probeTick];
    });
    dispatch_resume(_probeSource);
    NSLog(@"[Daemon] 保活探针已启动(5s)");
    [self log:@"保活探针已启动(每5s一条)"];
}

- (void)stopHeartbeat {
    if (_probeSource) {
        dispatch_source_cancel(_probeSource);
        _probeSource = nil;
    }
}

- (void)probeTick {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf writeProbe];
    });
}

// 主线程写探针: backgroundTimeRemaining 必须主线程读。
// raw < 0 = 前台或已获无限后台豁免(iOS 15 音频 / 特权 entitlements), 此时显示 -1 属正常。
- (void)writeProbe {
    @autoreleasepool {
        NSTimeInterval raw = [[UIApplication sharedApplication] backgroundTimeRemaining];
        NSInteger remain = (NSInteger)(raw < 0 ? -1 : raw);
        // 静音播放器与引擎为同一 AVAudioPlayer (TSAudioKeepAlive)
        BOOL silent = [TSAudioKeepAlive engineRunning];
        BOOL engine = silent;
        BOOL script = [TSLuaBridge shared].isRunning;
        BOOL auth = [[TSAuthKeepAlive shared] challengePending];
        [[TSLogStore shared] append:[NSString stringWithFormat:
            @"[保活] 探针 %@ 剩余%d秒 AVPlayer静音=%d 引擎=%d 脚本=%d Auth=%d",
            _isInBackground ? @"后台" : @"前台",
            (int)remain, silent, engine, script, auth]];
    }
}

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
