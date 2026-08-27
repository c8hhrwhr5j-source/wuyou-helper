//
//  TSAudioKeepAlive.m
//  TrollAutoTouch
//
//  实现: AVAudioEngine + 0.1s 静音 PCM buffer 循环播放。
//  需要 Info.plist 的 UIBackgroundModes 含 audio, 且 AVFoundation 已弱链接。
//
//  自愈机制:
//   - 监听音频中断(切到游戏等独占音频的 app / 来电), 中断结束后自动恢复;
//   - 监听 MediaServices 重置(音频服务崩溃恢复), 重建引擎;
//   - 15s 看门狗自检, 引擎意外停止时自动重启;
//   - 回前台时兜底重启。
//  防止保活引擎被系统打断后失效 → App 被挂起 → 8080 服务器随之不可达。
//

#import "TSAudioKeepAlive.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

@implementation TSAudioKeepAlive {
    AVAudioEngine *_engine;
    AVAudioPlayerNode *_player;
    NSInteger _refCount;
    NSTimer *_watchdogTimer;
    dispatch_source_t _recoverySource;   // 中断期间快速恢复 timer (GCD, 后台可靠触发)
    BOOL _notificationsInstalled;
}

+ (instancetype)shared {
    static TSAudioKeepAlive *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [TSAudioKeepAlive new];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self installNotifications];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_recoverySource) {
        dispatch_source_cancel(_recoverySource);
        _recoverySource = nil;
    }
    [_watchdogTimer invalidate];
    _watchdogTimer = nil;
}

#pragma mark - 通知监听(音频中断 / 服务重置 / 回前台)

- (void)installNotifications {
    if (_notificationsInstalled) return;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(onAudioInterruption:)
               name:AVAudioSessionInterruptionNotification object:nil];
    [nc addObserver:self selector:@selector(onMediaServicesReset:)
               name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    [nc addObserver:self selector:@selector(onDidBecomeActive:)
               name:UIApplicationDidBecomeActiveNotification object:nil];
    // iOS 12+: 其他 app(如游戏)的重要音频开始/结束时都会收到, 借此确认保活引擎存活
    [nc addObserver:self selector:@selector(onSecondaryAudioHint:)
               name:AVAudioSessionSilenceSecondaryAudioHintNotification object:nil];
    _notificationsInstalled = YES;
}

// 其他 app 抢占音频(如切到游戏)会触发中断。
// 关键: 对方持续播放期间系统不会发 Ended, 只发 Began。iOS 16 上不尽快恢复
// 音频输出, 后台 app 会在几秒内被挂起并遭 Jetsam 回收。所以 Began 即启动
// GCD 快速恢复(不等 Ended), Ended 时立即重建。
- (void)onAudioInterruption:(NSNotification *)note {
    NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan) {
        if (_refCount <= 0) return;   // 无持有者, 无需恢复
        NSLog(@"[TSAudioKeepAlive] 音频中断开始(被抢占), 启动快速恢复");
        [self startQuickRecovery];
    } else if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
        NSLog(@"[TSAudioKeepAlive] 音频中断结束, 停止快速恢复并重建");
        [self stopQuickRecovery];
        [self rebuildIfNeeded];
    }
}

// 游戏等重要音频开始/结束: 借机检查保活引擎是否仍在运行
- (void)onSecondaryAudioHint:(NSNotification *)note {
    [self rebuildIfNeeded];
}

// 音频服务崩溃后重建, 旧 engine/player 全部失效
- (void)onMediaServicesReset:(NSNotification *)note {
    NSLog(@"[TSAudioKeepAlive] 音频服务重置, 重建保活引擎");
    @synchronized (self) {
        [self teardownEngine];
    }
    [self rebuildIfNeeded];
}

// 回到前台: 若引擎意外停止则重启(兜底)
- (void)onDidBecomeActive:(NSNotification *)note {
    [self rebuildIfNeeded];
}

#pragma mark - 对外接口(引用计数)

- (void)start {
    @synchronized (self) {
        _refCount++;
        if (_engine && _engine.isRunning) {
            [self startWatchdog];
            return;
        }
        [self teardownEngine];
        [self buildAndStartEngine];
    }
}

- (void)stop {
    @synchronized (self) {
        if (_refCount > 0) _refCount--;
        if (_refCount > 0) return; // 仍有其他持有者, 保持引擎运行
        [self stopWatchdog];
        [self teardownEngine];
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:nil];
        NSLog(@"[TSAudioKeepAlive] 静音保活已停止");
    }
}

#pragma mark - 引擎构建

- (void)buildAndStartEngine {
    @synchronized (self) {
        NSError *err = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (![session setCategory:AVAudioSessionCategoryPlayback
                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                           error:&err]) {
            NSLog(@"[TSAudioKeepAlive] 设置 audio session 失败: %@", err);
            return;
        }
        if (![session setActive:YES error:&err]) {
            NSLog(@"[TSAudioKeepAlive] 激活 audio session 失败: %@", err);
            return;
        }

        AVAudioEngine *engine = [AVAudioEngine new];
        AVAudioPlayerNode *player = [AVAudioPlayerNode new];
        [engine attachNode:player];
        AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                              sampleRate:44100
                                                                channels:1
                                                             interleaved:NO];
        [engine connect:player to:engine.mainMixerNode format:fmt];

        // 0.1 秒静音 buffer, 循环播放 (不产生声音, 只维持后台音频运行状态)
        AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:4410];
        buf.frameLength = 4410;
        memset((void *)buf.floatChannelData[0], 0, 4410 * sizeof(float));
        [player scheduleBuffer:buf atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];

        if (![engine startAndReturnError:&err]) {
            NSLog(@"[TSAudioKeepAlive] 启动音频引擎失败: %@", err);
            return;
        }
        [player play];

        _engine = engine;
        _player = player;
        [self startWatchdog];
        NSLog(@"[TSAudioKeepAlive] 静音保活已启动 (后台运行保护)");
    }
}

- (void)teardownEngine {
    @synchronized (self) {
        [_player stop];
        [_engine stop];
        _player = nil;
        _engine = nil;
    }
}

// 若仍被持有但引擎不在运行, 重建(供中断恢复/回前台兜底/看门狗调用)
- (void)rebuildIfNeeded {
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self) {
            if (self->_refCount <= 0) return;
            BOOL ok = self->_engine && self->_engine.isRunning
                   && self->_player && self->_player.isPlaying;
            if (ok) return;
            NSLog(@"[TSAudioKeepAlive] 保活引擎未在运行, 自动重建");
            [self teardownEngine];
            [self buildAndStartEngine];
        }
    });
}

#pragma mark - 快速恢复(GCD, 后台可靠)

// 被抢占后每 0.5s 尝试重建保活引擎, 直到成功或中断结束。
// 用 dispatch_source 而非 NSTimer: 后台 run loop 不跑时 NSTimer 不触发,
// 15s 看门狗救不了"几秒内被挂起"的 iOS 16 场景, 必须用 GCD timer。
- (void)startQuickRecovery {
    @synchronized (self) {
        if (_recoverySource) return;
        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        _recoverySource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(_recoverySource,
                                  dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC),
                                  0.5 * NSEC_PER_SEC,
                                  0.1 * NSEC_PER_SEC);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_recoverySource, ^{
            [weakSelf quickRecoverTick];
        });
        dispatch_resume(_recoverySource);
    }
}

- (void)stopQuickRecovery {
    @synchronized (self) {
        if (_recoverySource) {
            dispatch_source_cancel(_recoverySource);
            _recoverySource = nil;
        }
    }
}

// 快速恢复节拍
- (void)quickRecoverTick {
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self) {
            if (self->_refCount <= 0) return;
            BOOL ok = self->_engine && self->_engine.isRunning
                   && self->_player && self->_player.isPlaying;
            if (ok) {
                NSLog(@"[TSAudioKeepAlive] 快速恢复: 保活引擎已恢复运行");
                [self stopQuickRecovery];
                return;
            }
            NSLog(@"[TSAudioKeepAlive] 快速恢复: 引擎未运行, 尝试重建");
            [self rebuildIfNeeded];
        }
    });
}

#pragma mark - 看门狗

- (void)startWatchdog {
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self) {
            if (self->_watchdogTimer) return;
            __weak typeof(self) weakSelf = self;
            self->_watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                                   repeats:YES
                                                                     block:^(NSTimer *timer) {
                [weakSelf rebuildIfNeeded];
            }];
        }
    });
}

- (void)stopWatchdog {
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self) {
            [self->_watchdogTimer invalidate];
            self->_watchdogTimer = nil;
        }
    });
}

@end
