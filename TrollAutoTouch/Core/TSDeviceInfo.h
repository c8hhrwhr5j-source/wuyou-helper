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

@end

NS_ASSUME_NONNULL_END
