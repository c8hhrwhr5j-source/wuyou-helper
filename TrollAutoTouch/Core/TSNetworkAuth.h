//
//  TSNetworkAuth.h
//  TrollAutoTouch
//
//  network-authentication 保活 —— NEHotspotHelper 注册(对齐原版 TrollAutoScript)。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSNetworkAuth : NSObject

// 注册为系统 Wi-Fi 热点认证助手(NEHotspotHelper)。
// 需要 entitlement: com.apple.developer.networking.HotspotHelper +
// com.apple.wifi.manager-access + com.apple.wlan.authentication。
// 注册成功后, 系统将本 app 视为 network-authentication 应用,
// 配合 UIBackgroundModes=network-authentication 获得后台持续执行豁免。
// 返回是否注册成功。
+ (BOOL)registerHotspotHelper;

+ (BOOL)isRegistered;

@end

NS_ASSUME_NONNULL_END
