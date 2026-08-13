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
//  (backboardd 只接受 SpringBoard 等受信进程的 IOHID 事件,
//   app 进程直接 dispatch 会被丢弃 —— 之前点击无效的根因)

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSInjectedTouchClient : NSObject

+ (instancetype)shared;

/// 确保已注入 SpringBoard 且 socket 已连接 (幂等, 内部自动重试)
- (BOOL)ensureInjected;

/// 发送单指触摸指令 (point 为逻辑点, 内部归一化为 0~1)
- (void)sendTouchType:(uint8_t)type index:(uint8_t)index point:(CGPoint)point;

/// 当前注入/连接状态描述 (供日志与调试)
@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly) pid_t springBoardPid;
@property (nonatomic, copy, readonly) NSString *statusDescription;

@end

NS_ASSUME_NONNULL_END
