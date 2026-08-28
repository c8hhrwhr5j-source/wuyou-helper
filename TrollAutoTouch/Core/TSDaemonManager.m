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
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <math.h>

@interface TSDaemonManager ()
@property (nonatomic, assign) TSDaemonState state;
@property (nonatomic, assign) BOOL isInBackground;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTaskId;
@property (nonatomic, strong) AVAudioPlayer *silentPlayer;
@property (nonatomic, strong) dispatch_source_t probeSource;   // GCD 探针 timer (后台可靠)
@property (nonatomic, assign) BOOL hudVisible;
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
    // 音频被其他 app(如游戏)抢占时恢复静默保活
    [nc addObserver:self selector:@selector(onAudioInterruption:)
               name:AVAudioSessionInterruptionNotification object:nil];
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

    // 自动开始后台保活: 静音音频 + 后台任务双保险。
    // 注意: 不注册 PushKit — iOS 16 起声明 voip 后台模式但 PushKit 注册失败
    // 的 app 会被系统启动时强制终止(TrollStore 下 aps-environment 无效必然失败)。
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

- (void)startSilentAudio {
    // iOS 16+: 对齐原版 TrollAutoScript 2.3.6 —— 系统对后台音频 app 审计严格,
    // "无意义音频"会被判定滥用并快速挂起, 音频保活失效且有害。
    // 保活改靠签名内嵌特权 entitlements(platform-application / no-sandbox /
    // multitasking.termination / systemappassertions / private.kernel.jetsam) 豁免。
    // iOS 15 保留音频保活(系统不审计, 豁免仍有效)。
    if (@available(iOS 16.0, *)) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSLog(@"[Daemon] iOS 16+ 已禁用静默音频保活 (对齐原版, 靠 entitlement 豁免)");
            [self log:@"iOS 16+ 已禁用静默音频保活 (对齐原版, 靠 entitlement 豁免)"];
        });
        return;
    }
    if (_silentPlayer && _silentPlayer.isPlaying) return;

    // 使用静默 WAV 文件(1 秒静默循环)
    NSString *path = [[NSBundle mainBundle] pathForResource:@"silence" ofType:@"wav"];
    if (!path) {
        // 动态生成静默音频文件
        path = [self createSilentWAV];
    }

    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error];
    [session setActive:YES error:&error];

    NSURL *url = [NSURL fileURLWithPath:path];
    _silentPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
    if (_silentPlayer) {
        _silentPlayer.numberOfLoops = -1; // 无限循环
        _silentPlayer.volume = 0.5;       // WAV 已含 -50dB 信号, 保持极低音量
        [_silentPlayer prepareToPlay];
        [_silentPlayer play];
        NSLog(@"[Daemon] 静默音频已开始(后台保活)");
        [self log:@"静默音频(AVAudioPlayer)已开始"];
    } else {
        NSLog(@"[Daemon] 静默音频启动失败: %@", error);
        [self log:[NSString stringWithFormat:@"静默音频(AVAudioPlayer)启动失败: %@", error]];
    }
}

- (void)stopSilentAudio {
    if (_silentPlayer) {
        [_silentPlayer stop];
        _silentPlayer = nil;
        NSLog(@"[Daemon] 静默音频已停止");
    }
}

// 音频被游戏等抢占时 AVAudioPlayer 会停止, 必须恢复否则保活失效。
// 与 TSAudioKeepAlive 同理: 不能只等 Ended(Began 后对方持续播放期间
// 系统不会发 Ended), Began 后要主动重试。iOS 16 上不恢复会被快速挂起。
- (void)onAudioInterruption:(NSNotification *)note {
    NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan) {
        if (!_isInBackground || !_silentPlayer) return;
        NSLog(@"[Daemon] 音频中断开始, 调度静默音频恢复");
        [self log:@"音频中断开始, 调度静默音频恢复"];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [weakSelf tryResumeSilentAudio];
        });
    } else if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
        [self tryResumeSilentAudio];
    }
}

// 若仍在后台且静默播放器已停止, 重新激活 session 并播放; 激活失败则 1s 后重试
- (void)tryResumeSilentAudio {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_isInBackground) return;
        if (!self->_silentPlayer || self->_silentPlayer.isPlaying) return;
        NSError *err = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (![session setActive:YES error:&err]) {
            NSLog(@"[Daemon] 恢复静默音频: 激活 session 失败 %@, 1s 后重试", err);
            [self log:[NSString stringWithFormat:@"恢复静默音频失败: %@, 1s 后重试", err]];
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC),
                           dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                [weakSelf tryResumeSilentAudio];
            });
            return;
        }
        [self->_silentPlayer play];
        NSLog(@"[Daemon] 静默音频已恢复播放");
        [self log:@"静默音频(AVAudioPlayer)已恢复播放"];
    });
}

/// 动态生成 1 秒静默 WAV 文件缓存
- (NSString *)createSilentWAV {
    // WAV 头 + 静默采样数据
    int sampleRate = 44100;
    int bitsPerSample = 16;
    int channels = 1;
    int bytesPerSample = bitsPerSample / 8;
    int dataSize = sampleRate * bytesPerSample * channels; // 1 秒

    NSMutableData *wav = [NSMutableData data];

    // RIFF header
    uint32_t chunkSize = 36 + dataSize;
    [wav appendBytes:"RIFF" length:4];
    [wav appendBytes:&chunkSize length:4];
    [wav appendBytes:"WAVE" length:4];

    // fmt subchunk
    [wav appendBytes:"fmt " length:4];
    uint32_t fmtSize = 16;
    uint16_t audioFormat = 1; // PCM
    uint16_t numChannels = channels;
    uint32_t sr = sampleRate;
    uint32_t byteRate = sampleRate * numChannels * bytesPerSample;
    uint16_t blockAlign = numChannels * bytesPerSample;
    uint16_t bps = bitsPerSample;
    [wav appendBytes:&fmtSize length:4];
    [wav appendBytes:&audioFormat length:2];
    [wav appendBytes:&numChannels length:2];
    [wav appendBytes:&sr length:4];
    [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&blockAlign length:2];
    [wav appendBytes:&bps length:2];

    // data subchunk
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataSize length:4];

    // 极低电平 1kHz 正弦 PCM 数据(约 -40dB)。
    // iOS 16 起纯静音(全零)不被认可为实际音频输出, 后台豁免失效会快速被杀;
    // 音量取 0.01(-40dB) 比纯静音更能被系统认可, 同时人耳几乎不可闻。
    int16_t *pcm = (int16_t *)malloc(dataSize);
    for (int i = 0; i < sampleRate; i++) {
        double t = (double)i / sampleRate;
        pcm[i] = (int16_t)(0.01 * 32767.0 * sin(2.0 * M_PI * 1000.0 * t));
    }
    [wav appendBytes:pcm length:dataSize];
    free(pcm);

    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"silence.wav"];
    [wav writeToFile:tmpPath atomically:YES];
    return tmpPath;
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
        BOOL silent = _silentPlayer.isPlaying;
        BOOL engine = [TSAudioKeepAlive engineRunning];
        BOOL script = [TSLuaBridge shared].isRunning;
        [[TSLogStore shared] append:[NSString stringWithFormat:
            @"[保活] 探针 %@ 剩余%d秒 AVPlayer静音=%d 引擎=%d 脚本=%d",
            _isInBackground ? @"后台" : @"前台",
            (int)remain, silent, engine, script]];
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
