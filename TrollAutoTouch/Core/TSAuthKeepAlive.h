//
//  TSAuthKeepAlive.h
//  TrollAutoTouch
//
//  network-authentication 后台模式的实际使用。
//
//  原理: 保持一个"未决的 URLSession HTTP/TLS 认证挑战" —— 收到 401(HTTP Basic)
//  或 TLS 信任挑战后, 故意不调用 didReceiveChallenge 的 completionHandler, 让
//  挑战持续挂起。系统网络栈据此认为 app 正在进行网络身份验证, 授予后台持续执行
//  时间(iOS 16 上 network-authentication 是唯一被实际使用才生效的后台模式)。
//
//  对齐原版 TrollAutoScript 2.3.6: 原版 UIBackgroundModes 仅声明
//  network-authentication, 并实现了完整的 URLSession auth challenge 委托
//  (URLSession:didReceiveChallenge:completionHandler: 等)。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSAuthKeepAlive : NSObject <NSURLSessionDelegate, NSURLSessionTaskDelegate>

+ (instancetype)shared;

/// 开始认证挂起会话(幂等)。iOS 16+ 与 iOS 15 均可调用。
- (void)start;

/// 停止会话, 取消未决任务并清理定时器。
- (void)stop;

/// 当前是否有未决(挂起中)的认证挑战 —— 保活探针可读, 用于确认豁免是否生效。
@property (nonatomic, assign, readonly) BOOL challengePending;

/// 最近一次挑战挂起时间(reference date), 从未挂起则为 0。
@property (nonatomic, assign, readonly) NSTimeInterval lastChallengeTime;

@end

NS_ASSUME_NONNULL_END
