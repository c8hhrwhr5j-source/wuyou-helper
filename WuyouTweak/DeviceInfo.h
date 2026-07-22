//
//  DeviceInfo.h
//  无忧辅助
//
//  设备信息获取（IOKit 桥接）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DeviceInfo : NSObject

+ (instancetype)sharedInstance;

@property (nonatomic, readonly) NSString *description;

+ (NSString *)deviceUUID;

+ (NSString *)hwModel;

+ (NSString *)resolutionDescription;

@end

NS_ASSUME_NONNULL_END