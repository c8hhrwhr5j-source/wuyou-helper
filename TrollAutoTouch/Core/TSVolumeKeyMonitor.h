//
//  TSVolumeKeyMonitor.h
//  TrollAutoTouch
//
//  App 进程内音量键识别 (物理按键感知版):
//    双通道检测 ——
//    ① 私有通知 AVSystemController_VolumeChangedNotification (主通道):
//       iOS 音量键是"物理按键事件"广播, 与当前音量值是否变化无关。
//       因此音量已到 0 / 静音时按音量- 依然能收到事件, 与 TrollAutoScript 行为一致。
//    ② 200ms 轮询 AVAudioSession.outputVolume (兜底通道, 公开 API):
//       通知通道被系统屏蔽/未生效时的降级, 音量值变化即判定按键。
//
//  线程模型: 回调在任意线程触发 (通知线程/轮询线程), 调用方自行转主线程。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSVolumeKeyMonitor : NSObject

@property (nonatomic, readonly) BOOL running;
/// 音量键按下回调 (任意线程触发, 已做双通道去重与启动校准)。调用方负责防抖与转主线程。
@property (nonatomic, copy, nullable) void (^onVolumeKey)(void);

+ (instancetype)shared;

/// 开始监听 (TAS 服务开启时调用)。幂等。
- (void)start;

/// 停止监听 (TAS 服务关闭时调用)。幂等。
- (void)stop;

@end

NS_ASSUME_NONNULL_END
