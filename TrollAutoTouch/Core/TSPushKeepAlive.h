//
//  TSPushKeepAlive.h
//  TrollAutoTouch
//
//  PushKit VoIP 后台保活。
//  iOS 13+ 上成功注册 PushKit VoIP 的 app 会被系统视为"持续在线"的 VoIP 应用,
//  进入后台后不会被挂起(无限后台豁免)。该豁免独立于音频保活 ——
//  即使游戏抢占 audio session 导致静音音频失效, VoIP 豁免仍然有效。
//  需要 entitlements 含 aps-environment, Info.plist 的 UIBackgroundModes 含 voip。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSPushKeepAlive : NSObject

+ (instancetype)shared;

/// 注册 PushKit VoIP(幂等)。系统给注册成功的 VoIP app 无限后台豁免。
- (void)start;
/// 注销(registry 置空)
- (void)stop;
/// 是否已成功注册(已拿到 VoIP token)
- (BOOL)isRegistered;

@end

NS_ASSUME_NONNULL_END
