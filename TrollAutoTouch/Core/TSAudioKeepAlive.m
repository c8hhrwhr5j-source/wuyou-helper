//
//  TSAudioKeepAlive.m
//  TrollAutoTouch
//
//  实现: AVAudioEngine + 0.1s 静音 PCM buffer 循环播放。
//  需要 Info.plist 的 UIBackgroundModes 含 audio, 且 AVFoundation 已弱链接。
//

#import "TSAudioKeepAlive.h"
#import <AVFoundation/AVFoundation.h>

@implementation TSAudioKeepAlive {
    AVAudioEngine *_engine;
    AVAudioPlayerNode *_player;
}

+ (instancetype)shared {
    static TSAudioKeepAlive *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [TSAudioKeepAlive new];
    });
    return inst;
}

- (void)start {
    @synchronized (self) {
        if (_engine) return; // 已在运行

        NSError *err = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        // Playback + MixWithOthers: 静音混播, 不独占音频, 不打断游戏/音乐 app
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

        _engine = [AVAudioEngine new];
        _player = [AVAudioPlayerNode new];
        [_engine attachNode:_player];
        AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithStandardFormatWithSampleRate:44100 channels:1];
        [_engine connect:_player to:_engine.mainMixerNode format:fmt];

        // 0.1 秒静音 buffer, 循环播放 (不产生声音, 只维持后台音频运行状态)
        AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:4410];
        buf.frameLength = 4410;
        memset(buf.floatChannelData[0], 0, 4410 * sizeof(float));
        [_player scheduleBuffer:buf atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];

        if (![_engine startAndReturnError:&err]) {
            NSLog(@"[TSAudioKeepAlive] 启动音频引擎失败: %@", err);
            _player = nil;
            _engine = nil;
            return;
        }
        [_player play];
        NSLog(@"[TSAudioKeepAlive] 静音保活已启动 (后台运行保护)");
    }
}

- (void)stop {
    @synchronized (self) {
        if (!_engine) return;
        [_player stop];
        [_engine stop];
        _player = nil;
        _engine = nil;
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:nil];
        NSLog(@"[TSAudioKeepAlive] 静音保活已停止");
    }
}

@end
