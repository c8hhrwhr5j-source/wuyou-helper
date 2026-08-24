//
//  TSVolumeKeyMonitor.h
//  TrollAutoTouch
//
//  App 进程内音量键识别 (iOS 15+ 物理按键感知版):
//    【多通道架构 - 按优先级排序】
//    ① BKS 硬件事件路由 (BackBoardServices.framework) — 核心通道:
//       使用 BKSHIDEventDeliveryManager 直接拦截硬件按键事件, 绕过音频系统,
//       音量为 0 时仍能检测到物理按键 (TrollAutoScript 逆向确认的核心机制)。
//    ② SpringBoard 硬件按键推送 (CPDistributedMessagingCenter)
//    ③ IOHIDEventSystemClient 全局 HID 事件
//    ④ KVO + 边界回弹 (主通道兜底): 音量贴 0/1 边界时用 AVSystemController
//       悄悄拉回 0.05/0.95, 保证按键产生真实音量变化。
//    ⑤ 200ms 轮询 + AVSystemController 私有通知 (最终兜底)
//
//  线程模型: 回调在任意线程触发 (BKS/KVO/通知/轮询线程), 已做双通道去重与启动校准。

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
