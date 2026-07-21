//
//  DeviceInfo.m
//  无忧辅助
//
//  设备信息获取实现
//

#import "DeviceInfo.h"
#import <UIKit/UIKit.h>
#import <IOKit/IOKitLib.h>
#import <sys/sysctl.h>

@implementation DeviceInfo

+ (NSString *)deviceUUID {
    mach_port_t masterPort;
    if (@available(iOS 15.0, *)) {
        masterPort = kIOMainPortDefault;
    } else {
        IOMasterPort(MACH_PORT_NULL, &masterPort);
    }
    io_service_t service = IOServiceGetMatchingService(
        masterPort,
        IOServiceMatching("IOPlatformExpertDevice")
    );
    if (service == IO_OBJECT_NULL) return @"无权限";

    NSString *uuid = nil;
    CFTypeRef cfUUID = IORegistryEntryCreateCFProperty(
        service, CFSTR("IOPlatformUUID"),
        kCFAllocatorDefault, 0
    );
    if (cfUUID) {
        uuid = (__bridge_transfer NSString *)cfUUID;
    }
    IOObjectRelease(service);
    return uuid ?: @"无权限";
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
