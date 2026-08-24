//
//  TSDeviceInfo.h
//  TrollAutoTouch
//
//  设备信息查询 —— 对应原版 device.info() / sys.getScreenSize() 等。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSDeviceInfo : NSObject

+ (instancetype)shared;

/// 完整设备信息字典
- (NSDictionary *)fullInfo;

/// 屏幕分辨率(逻辑点)
- (CGSize)screenSize;

/// 屏幕缩放
- (CGFloat)screenScale;

/// 设备型号名(如 "iPhone14,2")
- (NSString *)modelIdentifier;

/// 系统版本
- (NSString *)osVersion;

/// 设备名称
- (NSString *)deviceName;

/// 电量 0~1
- (float)batteryLevel;

/// 充电状态
- (NSInteger)batteryState;

/// WiFi IP 地址
- (nullable NSString *)wifiIPAddress;

/// 设备标识
- (NSString *)identifierForVendor;

/// 设备 UDID (通过 MobileGestalt 私有 API 读取, 需 entitlements
/// com.apple.private.MobileGestalt.AllowedProtectedKeys=true; 沙盒/非 TrollStore 环境返回 nil)
- (nullable NSString *)udid;

/// 设备序列号 (同上, 通过 MobileGestalt 读取)
- (nullable NSString *)serialNumber;

/// 启用辅助触控 (AssistiveTouch/小白点)
/// 通过修改 Accessibility.plist + 广播 Darwin 通知让 SpringBoard 重新加载
/// @return 是否修改成功 (plist 写入 + 通知发送均成功才返回 YES)
- (BOOL)enableAssistiveTouch;

/// 停用辅助触控
- (BOOL)disableAssistiveTouch;

/// 查询辅助触控当前是否启用 (读取 Accessibility.plist)
- (BOOL)isAssistiveTouchEnabled;

/// 屏幕是否锁定 (通过 Darwin 通知 com.apple.springboard.lockstate 状态查询)
- (BOOL)isScreenLocked;

/// 解锁屏幕 (唤醒屏幕 + 发 Home 键事件取消锁屏)
/// 设备有密码时无法完全解锁到桌面, 调用方自行处理
/// @return 唤醒+事件注入成功返回 YES, 失败返回 NO
- (BOOL)unlockScreen;

/// 设备类型: "iPhone" / "iPad" / "TV" / "CarPlay" / "Unspecified"
- (NSString *)deviceType;

/// 当前屏幕亮度 [0, 1] (UIScreen.mainScreen.brightness)
- (CGFloat)backlightLevel;

/// 设置屏幕亮度 [0, 1]
- (void)setBacklightLevel:(CGFloat)level;

/// 锁定屏幕 (复用 TSKeyboardInjector 的 GSEventLockDevice / Lock 键)
- (void)lockScreen;

/// 震动 (系统默认震动反馈)
- (void)vibrate;

/// 设置系统音量 [0, 1] (通过 MPVolumeView 滑块 hack)
- (void)setSystemVolume:(float)volume;

@end

NS_ASSUME_NONNULL_END
