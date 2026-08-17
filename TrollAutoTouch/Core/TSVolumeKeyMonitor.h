//
//  TSVolumeKeyMonitor.h
//  TrollAutoTouch
//
//  App 进程内音量键识别 (借鉴 AutoGo/CGO 方案):
//    200ms 轮询 AVAudioSession.outputVolume (公开只读 API), 音量值变化 = 音量键被按下。
//    不依赖注入 SpringBoard、不依赖私有通知、不依赖 IOHID 权限 ——
//    注入失败时音量键控制仍可用 (App 内直接暂停/继续脚本兜底)。
//
//  线程模型: 轮询在后台队列, onVolumeKey 在轮询线程回调, 调用方自行转主线程。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSVolumeKeyMonitor : NSObject

@property (nonatomic, readonly) BOOL running;
/// 音量键按下回调 (任意线程触发)。调用方负责防抖与转主线程。
@property (nonatomic, copy, nullable) void (^onVolumeKey)(void);

+ (instancetype)shared;

/// 开始轮询 (脚本运行时调用)。幂等。
- (void)start;

/// 停止轮询 (脚本结束/停止时调用)。幂等。
- (void)stop;

@end

NS_ASSUME_NONNULL_END
