//
//  DeviceInfo.h
//  无忧辅助
//
//  设备信息获取（IOKit 桥接）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DeviceInfo : NSObject

/// 获取设备 UUID（通过 IOKit IOPlatformUUID）
+ (NSString *)deviceUUID;

/// 获取硬件型号（如 iPhone12,1）
+ (NSString *)hwModel;

/// 获取屏幕分辨率描述
+ (NSString *)resolutionDescription;

@end

NS_ASSUME_NONNULL_END
