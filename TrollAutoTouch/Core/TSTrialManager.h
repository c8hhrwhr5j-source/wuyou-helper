//
//  TSTrialManager.h
//  TrollAutoTouch
//
//  未激活设备的 15 分钟试用管理:
//    - App 每次启动(进程重启)重新获得一个 15 分钟试用窗口
//    - 试用到期 → 强制停止当前运行的所有脚本, 并阻止后续脚本启动
//    - 激活成功 → 取消试用, 恢复正常使用
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 试用状态变化通知 (object = TSTrialManager), 供 UI 刷新
FOUNDATION_EXPORT NSNotificationName const TSTrialStateChangedNotification;

@interface TSTrialManager : NSObject

+ (instancetype)shared;

/// App 启动时调用: 已激活则无限制; 未激活则启动 15 分钟试用倒计时(幂等, 不重置已有窗口)
- (void)startIfNeeded;

/// 激活成功时调用: 取消试用倒计时, 解除过期锁定
- (void)cancelTrial;

/// 试用是否已到期(未激活且 15 分钟已用完)
@property (nonatomic, readonly) BOOL isExpired;

/// 是否处于试用期(未激活且倒计时未结束)
@property (nonatomic, readonly) BOOL isTrialActive;

/// 当前试用剩余秒数(未激活时); 已激活或未在计时返回 0
@property (nonatomic, readonly) NSTimeInterval remainingSeconds;

@end

NS_ASSUME_NONNULL_END
