//
//  DeviceInfo.m
//  无忧辅助
//
//  设备信息获取实现
//

#import "DeviceInfo.h"
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>

@implementation DeviceInfo

+ (instancetype)sharedInstance {
    static DeviceInfo *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DeviceInfo alloc] init];
    });
    return instance;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"设备: %@ | UUID: %@ | 分辨率: %@",
            [self.class hwModel],
            [self.class deviceUUID],
            [self.class resolutionDescription]];
}

+ (NSString *)deviceUUID {
    NSUUID *uuid = [[UIDevice currentDevice] identifierForVendor];
    return uuid ? [uuid UUIDString] : @"无权限";
}

+ (NSString *)hwModel {
    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char *buf = malloc(size);
    if (!buf) return @"?";
    sysctlbyname("hw.machine", buf, &size, NULL, 0);
    NSString *model = [NSString stringWithUTF8String:buf];
    free(buf);
    return model ?: @"?";
}

+ (NSString *)resolutionDescription {
    CGRect bounds = [UIScreen mainScreen].bounds;
    CGRect native = [UIScreen mainScreen].nativeBounds;
    CGFloat scale = [UIScreen mainScreen].scale;
    return [NSString stringWithFormat:@"%.0f×%.0f (%.0f×%.0f @%.1fx)",
            bounds.size.width, bounds.size.height,
            native.size.width, native.size.height, scale];
}

@end