//
//  TSAudioKeepAlive.h
//  TrollAutoTouch
//
//  后台保活: 脚本运行期间用"静音音频循环播放"阻止 App 被系统挂起。
//
//  背景: 用户在游戏/其他 app 里跑脚本时, TrollAutoTouch 处于后台。
//  iOS 默认几秒后挂起后台 App, 导致 App 进程内的音量键轮询
//  (TSVolumeKeyMonitor) 与 IOHID 直发触摸 (TSHIDEventTouch) 全部停摆,
//  表现就是"游戏里按音量键没反应 / 脚本点击失效"。
//
//  原理: Info.plist 声明 UIBackgroundModes=audio 后, App 只要在持续播放
//  音频就不会被挂起。这里播放 0.1s 的静音 PCM 循环 (MixWithOthers),
//  不产生任何声音, 也不抢占其他 app 的音频焦点。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSAudioKeepAlive : NSObject

+ (instancetype)shared;

/// 启动静音保活 (脚本开始时调用; 幂等, 已在运行则无操作)
- (void)start;

/// 停止静音保活 (脚本结束时调用; 幂等)
- (void)stop;

/// 保活引擎当前是否在运行(供后台保活探针日志查询)
+ (BOOL)engineRunning;

@end

NS_ASSUME_NONNULL_END
