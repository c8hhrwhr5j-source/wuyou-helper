//
//  TSAudioKeepAlive.m
//  TrollAutoTouch
//
//  实现: AVAudioPlayer + 运行时生成的 16kHz 全零静音 WAV 无限循环播放。
//  完全复刻 AutoGoRunner(无忧IOS, app-release.ipa) 在 iOS 16.6 上实测有效的保活方式:
//    - 静音 WAV: 16000Hz / 单声道 / 16bit PCM / 2 秒全零 (44 头 + 64000 数据 = 64044 字节),
//      运行时在内存生成(_createSilentWAVData), 不依赖资源文件;
//    - AVAudioPlayer initWithData:(内存 WAV) → numberOfLoops=-1 → volume=0.0
//      → prepareToPlay → play。volume=0.0 仍属于"播放中", 系统据此豁免挂起;
//    - AVAudioSession setCategory:Playback mode:Default options:MixWithOthers
//      → setActive:YES;
//    - 4 个通知自愈(全部重入 ensurePlaying, isPlaying 检查保证幂等):
//      * UIApplicationDidEnterBackgroundNotification     (进后台, 确保播放)
//      * UIApplicationDidBecomeActiveNotification       (回前台, 兜底重启)
//      * AVAudioSessionInterruptionNotification         (Ended 时重启, 对齐原版)
//      * AVAudioSessionMediaServicesWereResetNotification (重建播放器后重启)
//    - 15s 看门狗兜底。
//
//  历史结论纠正(2026-08-28 逆向 AutoGoRunner @ _AGStartDebugAudioKeepAlive):
//  之前误以为 "iOS 16+ 播放静音音频会被系统判定滥用快速挂起" —— 该结论错误。
//  AutoGoRunner 正是靠 volume=0.0 的静音 AVAudioPlayer 在 iOS 16.6 上保活成功,
//  且其 Info.plist 的 UIBackgroundModes 声明了 audio。原版 TrollAutoScript 2.3.6
//  只声明 network-authentication 是另一条路线(特权 entitlements + HotspotHelper),
//  但 iOS 16.6 TrollStore 下 platform 身份不可用, 该路线实测失败(后台 30s 被杀)。
//  故 TrollAutoTouch 采用 AutoGoRunner 路线: audio 后台模式 + 静音 AVAudioPlayer。
//
//  ⚠️ 关键差异(与旧实现): AVAudioPlayer(非 AVAudioEngine); WAV 为 16kHz 全零静音
//  (非 44100Hz 1kHz 正弦); volume=0.0(非 0.01); 不区分 iOS 15/16(统一启用);
//  UIBackgroundModes 声明 audio(见 project.yml)。

#import "TSAudioKeepAlive.h"
#import "TSLogStore.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <math.h>

// 与 AutoGoRunner _AGCreateSilentWAVData 完全一致的参数:
//   16000Hz / 1ch / 16bit / 2 秒全零
//   dataSize = 16000 * 2 * 2 = 64000 (0xFA00)
//   byteRate = 16000 * 2 = 32000 (0x7D00)
//   总长 = 44 + 64000 = 64044 (0xFA2C)
static const uint32_t kSilentSampleRate   = 16000;
static const uint16_t kSilentChannels     = 1;
static const uint16_t kSilentBitDepth     = 16;
static const uint32_t kSilentDataBytes    = 64000; // 2 秒

@implementation TSAudioKeepAlive {
    AVAudioPlayer *_player;
    NSData *_silentWAV;
    NSInteger _refCount;
    NSTimer *_watchdogTimer;
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
        _silentWAV = [self createSilentWAVData];
        [self installNotifications];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_watchdogTimer invalidate];
    _watchdogTimer = nil;
}

#pragma mark - 通知监听(对齐 AutoGoRunner: 4 个观察者全部重入 ensurePlaying)

- (void)installNotifications {
    if (_notificationsInstalled) return;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    // 进入后台: 确保静音播放器持续播放(系统据此豁免挂起)
    [nc addObserver:self selector:@selector(rebuildIfNeeded)
               name:UIApplicationDidEnterBackgroundNotification object:nil];
    // 回到前台: 兜底重启
    [nc addObserver:self selector:@selector(rebuildIfNeeded)
               name:UIApplicationDidBecomeActiveNotification object:nil];
    // 音频中断: 对齐原版仅处理 Ended(值 0)。Began 在 MixWithOthers 混音模式下
    // 一般不会触发(与其他 app 混音而非抢占); 来电等硬中断结束时恢复即可。
    [nc addObserver:self selector:@selector(onAudioInterruption:)
               name:AVAudioSessionInterruptionNotification object:nil];
    // 音频服务重置(崩溃恢复): 播放器对象失效, 需重建后再启动
    [nc addObserver:self selector:@selector(onMediaServicesReset:)
               name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    _notificationsInstalled = YES;
}

- (void)onAudioInterruption:(NSNotification *)note {
    NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue != AVAudioSessionInterruptionTypeEnded) return;
    NSLog(@"[TSAudioKeepAlive] 音频中断结束, 恢复播放");
    [self log:@"音频中断结束, 恢复播放"];
    [self rebuildIfNeeded];
}

- (void)onMediaServicesReset:(NSNotification *)note {
    NSLog(@"[TSAudioKeepAlive] 音频服务重置, 重建播放器");
    [self log:@"音频服务重置, 重建播放器"];
    @synchronized (self) {
        _player = nil; // 旧播放器随音频服务崩溃失效
    }
    [self rebuildIfNeeded];
}

#pragma mark - 对外接口(引用计数)

- (void)start {
    @synchronized (self) {
        _refCount++;
        [self ensurePlaying];
    }
}

- (void)stop {
    @synchronized (self) {
        if (_refCount > 0) _refCount--;
        if (_refCount > 0) return; // 仍有其他持有者, 保持播放
        [self stopWatchdog];
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self stopPlayerAndDeactivate];
            });
        } else {
            [self stopPlayerAndDeactivate];
        }
        NSLog(@"[TSAudioKeepAlive] 静音保活已停止");
    }
}

- (void)stopPlayerAndDeactivate {
    @synchronized (self) {
        [_player stop];
        _player = nil;
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:nil];
    }
}

#pragma mark - 播放核心(对齐 AutoGoRunner _AGStartDebugAudioKeepAlive)

// 幂等: 已在播放则无操作。非主线程时派发到主线程执行(AVAudioPlayer 主线程操作)。
- (void)ensurePlaying {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self ensurePlaying];
        });
        return;
    }
    @synchronized (self) {
        if (_refCount <= 0) return;
        if (_player && _player.isPlaying) return;

        NSError *err = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (![session setCategory:AVAudioSessionCategoryPlayback
                             mode:AVAudioSessionModeDefault
                          options:AVAudioSessionCategoryOptionMixWithOthers
                            error:&err]) {
            NSLog(@"[TSAudioKeepAlive] 设置 audio session 失败: %@", err);
            [self log:[NSString stringWithFormat:@"设置 audio session 失败: %@", err]];
            return;
        }
        if (![session setActive:YES error:&err]) {
            NSLog(@"[TSAudioKeepAlive] 激活 audio session 失败: %@", err);
            [self log:[NSString stringWithFormat:@"激活 audio session 失败: %@", err]];
            return;
        }

        if (!_player) {
            _player = [[AVAudioPlayer alloc] initWithData:_silentWAV error:&err];
            if (!_player) {
                NSLog(@"[TSAudioKeepAlive] 创建 AVAudioPlayer 失败: %@", err);
                [self log:[NSString stringWithFormat:@"创建 AVAudioPlayer 失败: %@", err]];
                return;
            }
            _player.numberOfLoops = -1; // 无限循环
            _player.volume = 0.0;       // 对齐原版: 全零静音 + volume=0
            [_player prepareToPlay];
        }

        [_player play];
        [self startWatchdog];
        NSLog(@"[TSAudioKeepAlive] 静音保活已启动 (AVAudioPlayer 16kHz 全零 WAV, 对齐 AutoGoRunner)");
        [self log:@"静音保活已启动 (AVAudioPlayer 16kHz 全零 WAV, 对齐 AutoGoRunner)"];
    }
}

// 若仍被持有但播放器未在播放, 重建(供通知自愈/看门狗调用)
- (void)rebuildIfNeeded {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensurePlaying];
    });
}

#pragma mark - 静音 WAV 生成(对齐 AutoGoRunner _AGCreateSilentWAVData @ 0x100018974)

// 构造 44 字节 RIFF 头 + 64000 字节全零 PCM。iOS 为小端, 直接 memcpy 各字段。
- (NSData *)createSilentWAVData {
    NSMutableData *wav = [NSMutableData dataWithLength:44 + kSilentDataBytes];
    Byte *b = (Byte *)wav.mutableBytes;

    uint32_t chunkSize = 36 + kSilentDataBytes;        // 0xFA24
    uint32_t fmtSize   = 16;
    uint16_t audioFormat = 1;                          // PCM
    uint16_t numChannels = kSilentChannels;
    uint32_t sampleRate  = kSilentSampleRate;          // 0x3E80
    uint32_t byteRate    = kSilentSampleRate * kSilentChannels * (kSilentBitDepth / 8); // 0x7D00
    uint16_t blockAlign  = kSilentChannels * (kSilentBitDepth / 8);                      // 2
    uint16_t bitsPerSample = kSilentBitDepth;          // 0x10
    uint32_t dataSize    = kSilentDataBytes;           // 0xFA00

    memcpy(b + 0,  "RIFF", 4);
    memcpy(b + 4,  &chunkSize, 4);
    memcpy(b + 8,  "WAVE", 4);
    memcpy(b + 12, "fmt ", 4);
    memcpy(b + 16, &fmtSize, 4);
    memcpy(b + 20, &audioFormat, 2);
    memcpy(b + 22, &numChannels, 2);
    memcpy(b + 24, &sampleRate, 4);
    memcpy(b + 28, &byteRate, 4);
    memcpy(b + 32, &blockAlign, 2);
    memcpy(b + 34, &bitsPerSample, 2);
    memcpy(b + 36, "data", 4);
    memcpy(b + 40, &dataSize, 4);
    // b+44 起 64000 字节由 dataWithLength 保证全零(静音)

    return wav;
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

#pragma mark - 日志 / 状态查询

- (void)log:(NSString *)msg {
    [[TSLogStore shared] append:[NSString stringWithFormat:@"[保活] %@", msg]];
}

+ (BOOL)engineRunning {
    TSAudioKeepAlive *ka = [TSAudioKeepAlive shared];
    @synchronized (ka) {
        return ka->_player && ka->_player.isPlaying;
    }
}

@end
