//
//  TSVolumeKeyMonitor.h
//  TrollAutoTouch
//
//  App 进程内音量键识别 (iOS 15 物理按键感知版):
//    iOS 15 起 AVSystemController 私有通知停发, 主通道改为 KVO 监听
//    AVAudioSession.outputVolume (公开 API, 真机有效)。
//    空音量检测核心: 音量贴 0/1 边界时用 Celestial AVSystemController
//    setVolumeTo:forCategory: 悄悄拉回 0.05/0.95, 使物理按键每次都能
//    产生真实音量变化 (0.05→0), 空音量按音量- 也持续触发回调。
//    另保留 200ms 轮询 + 私有通知作为兜底, 多通道去重。
//
//  线程模型: 回调在任意线程触发 (KVO/通知/轮询线程), 调用方自行转主线程。

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
