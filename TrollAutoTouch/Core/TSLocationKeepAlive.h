//
//  TSLocationKeepAlive.h
//  TrollAutoTouch
//
//  后台定位保活。
//
//  查证结论(2026-08-28, 逆向 AutoGoRunner/app-release.ipa):
//  AutoGoRunner 的 UIBackgroundModes 声明了 9 个模式(含 location),
//  其保活主通道是 "location 后台模式 + 持续定位" —— iOS 16 上持续
//  startUpdatingLocation + Always 授权的 app 后台无限运行(导航类机制,
//  苹果官方认可, 不需要 platform 身份)。静音音频 / URLSession 认证挂起 /
//  NEHotspotHelper 都只是辅助。
//
//  本类对齐该机制: 进后台时 start, 回前台时 stop。entitlements 已含
//  com.apple.private.tcc.allow 的 kTCCServiceLocation 预授权 + locationd
//  全套权限, 正常情况下授权自动为 "始终允许", 无需用户弹窗操作。
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

@interface TSLocationKeepAlive : NSObject <CLLocationManagerDelegate>

+ (instancetype)shared;

// 启动持续定位(后台保活主通道), 幂等;
// 同时注册 SLC(重大位置变化)监听 —— 系统级注册跨终止/重启持久,
// 设备重启后首次基站切换/移动时系统自动后台拉起 app, 无需手动点开图标
// (didFinishLaunching 无条件启动 TAS 服务 + 8080 端口, 保活链自动接管)。
- (void)start;

// 停止持续定位(回到前台时调用, 省电)。
// 刻意不注销 SLC —— SLC 需在 app 被终止/设备重启后保持注册才能自动拉起。
- (void)stop;

// 注销 SLC 重启自启监听: 仅在用户于设置页明确关闭 TAS 服务时调用。
- (void)stopSystemRelaunchWatch;

// 是否正在持续定位
- (BOOL)isRunning;

// 当前定位授权状态
- (CLAuthorizationStatus)authorizationStatus;

@end
