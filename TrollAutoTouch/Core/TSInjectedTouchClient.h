//
//  TSInjectedTouchClient.h
//  TrollAutoTouch
//
//  app 端触摸注入客户端:
//    1. 用 opainject (OpenInject, PAC bypass) 把 TSInjectedTouchService.dylib
//       注入 SpringBoard 进程
//    2. 连接 SpringBoard 内触摸服务的 TCP socket (127.0.0.1:23333)
//    3. 把触摸指令通过 socket 发往 SpringBoard, 由服务端注入 IOHID 事件
//
//  注: 原版 TrollAutoScript 2.2.0 触摸并非注入实现, 而是 HUDServices 在
//  自己进程内直发 IOHID (research/zxtouch/Touch.xm)。此处保留注入链路
//  作为直发 (TSHIDEventTouch 第一通道) 不可用时的备选。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 控制事件回调 (主线程)。event 取 TSInjectedTouchService.h 中的
/// TS_EVENT_PAUSE / TS_EVENT_RESUME / TS_EVENT_STOP。
typedef void (^TSControlEventHandler)(uint8_t event);

@interface TSInjectedTouchClient : NSObject

+ (instancetype)shared;

/// 确保已注入 SpringBoard 且 socket 已连接 (幂等, 内部自动重试)
- (BOOL)ensureInjected;

/// 发送单指触摸指令 (point 为逻辑点, 内部归一化为 0~1)
- (void)sendTouchType:(uint8_t)type index:(uint8_t)index point:(CGPoint)point;

/// 启用/禁用音量键控制面板 (脚本运行时启用, 结束后禁用)。
/// 启用后, 在任意 app (如游戏) 前台按下音量键, SpringBoard 侧注入的
/// dylib 会弹出 暂停/继续·停止·取消 系统级菜单。
- (void)setVolumeKeyControlEnabled:(BOOL)enabled;

/// 通知 SpringBoard 侧 dylib 弹出音量键控制面板。
/// 音量键识别在 app 进程内完成 (TSVolumeKeyMonitor 轮询 outputVolume),
/// 识别到后调用本方法让 dylib 弹菜单 (注入失败时由 Lua 桥在 app 内直接暂停/继续兜底)。
- (void)presentVolumeControlPanel;

/// 控制事件回调: 用户在音量键菜单选择 暂停/继续/停止 时触发 (主线程)
@property (nonatomic, copy, nullable) TSControlEventHandler controlEventHandler;

/// 当前注入/连接状态描述 (供日志与调试)
@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly) pid_t springBoardPid;
@property (nonatomic, copy, readonly) NSString *statusDescription;

@end

NS_ASSUME_NONNULL_END
