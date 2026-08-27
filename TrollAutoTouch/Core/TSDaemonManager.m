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
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

@interface TSDaemonManager ()
@property (nonatomic, assign) TSDaemonState state;
@property (nonatomic, assign) BOOL isInBackground;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTaskId;
@property (nonatomic, strong) AVAudioPlayer *silentPlayer;
@property (nonatomic, strong) NSTimer *heartbeatTimer;
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
        return;
    }

    NSLog(@"[Daemon] 应用进入后台");
    _isInBackground = YES;
    _state = TSDaemonStateBackground;

    // 自动开始后台保活
    [self startSilentAudio];
    [self beginBackgroundTask];
    [self startHeartbeat];
}

- (void)appWillEnterForeground:(NSNotification *)note {
    NSLog(@"[Daemon] 应用回到前台");
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
    [_heartbeatTimer invalidate];
    _heartbeatTimer = nil;
    [self stopSilentAudio];
    [self endBackgroundTask];
    [self hideHUD];
    _state = TSDaemonStateStopped;
    NSLog(@"[Daemon] 所有服务已停止");
}

#pragma mark - 后台保活

- (void)beginBackgroundTask {
    if (_bgTaskId != UIBackgroundTaskInvalid) return;

    _bgTaskId = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"TrollAutoTouch.Daemon"
                                                              expirationHandler:^{
        NSLog(@"[Daemon] 后台任务即将到期，重新申请...");
        [[TSDaemonManager shared] endBackgroundTask];
        [[TSDaemonManager shared] beginBackgroundTask];
    }];

    NSLog(@"[Daemon] 后台任务已开始: %lu", (unsigned long)_bgTaskId);
}

- (void)endBackgroundTask {
    if (_bgTaskId == UIBackgroundTaskInvalid) return;

    [[UIApplication sharedApplication] endBackgroundTask:_bgTaskId];
    NSLog(@"[Daemon] 后台任务已结束: %lu", (unsigned long)_bgTaskId);
    _bgTaskId = UIBackgroundTaskInvalid;
}

- (void)startSilentAudio {
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
        _silentPlayer.volume = 0.0;       // 静默播放
        [_silentPlayer prepareToPlay];
        [_silentPlayer play];
        NSLog(@"[Daemon] 静默音频已开始(后台保活)");
    } else {
        NSLog(@"[Daemon] 静默音频启动失败: %@", error);
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
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC),
                           dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                [weakSelf tryResumeSilentAudio];
            });
            return;
        }
        [self->_silentPlayer play];
        NSLog(@"[Daemon] 静默音频已恢复播放");
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

    // 静默 PCM 数据
    uint8_t *silence = calloc(dataSize, 1);
    [wav appendBytes:silence length:dataSize];
    free(silence);

    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"silence.wav"];
    [wav writeToFile:tmpPath atomically:YES];
    return tmpPath;
}

- (void)startHeartbeat {
    [_heartbeatTimer invalidate];
    _heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // 发送心跳日志，保持 app 活跃
            NSLog(@"[Daemon] ♥ 心跳 —— 后台剩余 %.1fs",
                  [[UIApplication sharedApplication] backgroundTimeRemaining]);
        });
    }];
    // 允许在后台模式下运行 timer
    [[NSRunLoop mainRunLoop] addTimer:_heartbeatTimer forMode:NSRunLoopCommonModes];
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
