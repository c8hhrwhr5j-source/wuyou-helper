//
//  TSDeviceInfo.m
//  TrollAutoTouch
//

#import "TSDeviceInfo.h"
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <sys/socket.h>

@implementation TSDeviceInfo

+ (instancetype)shared {
    static TSDeviceInfo *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[TSDeviceInfo alloc] init]; });
    return instance;
}

- (NSDictionary *)fullInfo {
    UIDevice *d = [UIDevice currentDevice];
    CGSize ss = [UIScreen mainScreen].bounds.size;
    CGFloat scale = [UIScreen mainScreen].scale;
    
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    
    return @{
        @"name":            d.name ?: @"",
        @"model":           d.model ?: @"",
        @"localizedModel":  d.localizedModel ?: @"",
        @"systemName":      d.systemName ?: @"",
        @"systemVersion":   d.systemVersion ?: @"",
        @"identifier":      d.identifierForVendor.UUIDString ?: @"",
        @"modelIdentifier": [self modelIdentifier],
        // Lua 脚本统一使用物理像素坐标
        @"screenWidth":     @(ss.width * scale),
        @"screenHeight":    @(ss.height * scale),
        @"screenScale":     @(scale),
        @"screenNativeWidth":   @(ss.width * scale),
        @"screenNativeHeight":  @(ss.height * scale),
        @"batteryLevel":    @(d.batteryLevel),
        @"batteryState":    @(d.batteryState),
        @"wifiIP":          [self wifiIPAddress] ?: @"",
        @"userInterfaceIdiom": @([UIDevice currentDevice].userInterfaceIdiom),
    };
}

- (CGSize)screenSize {
    CGSize s = [UIScreen mainScreen].bounds.size;
    CGFloat scale = [UIScreen mainScreen].scale;
    return CGSizeMake(s.width * scale, s.height * scale);
}

- (CGFloat)screenScale {
    return [UIScreen mainScreen].scale;
}

- (NSString *)modelIdentifier {
    size_t size = 0;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char *machine = malloc(size);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    NSString *platform = [NSString stringWithUTF8String:machine];
    free(machine);
    return platform;
}

- (NSString *)osVersion {
    return [UIDevice currentDevice].systemVersion;
}

- (NSString *)deviceName {
    return [UIDevice currentDevice].name;
}

- (float)batteryLevel {
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    return [UIDevice currentDevice].batteryLevel;
}

- (NSInteger)batteryState {
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    return [UIDevice currentDevice].batteryState;
}

- (NSString *)wifiIPAddress {
    struct ifaddrs *interfaces = NULL;
    NSString *address = nil;
    if (getifaddrs(&interfaces) == 0) {
        struct ifaddrs *temp = interfaces;
        while (temp) {
            if (temp->ifa_addr->sa_family == AF_INET &&
                [[NSString stringWithUTF8String:temp->ifa_name] isEqualToString:@"en0"]) {
                char addrBuf[INET_ADDRSTRLEN];
                inet_ntop(AF_INET, &((struct sockaddr_in *)temp->ifa_addr)->sin_addr, addrBuf, sizeof(addrBuf));
                address = [NSString stringWithUTF8String:addrBuf];
                break;
            }
            temp = temp->ifa_next;
        }
        freeifaddrs(interfaces);
    }
    return address;
}

- (NSString *)identifierForVendor {
    return [UIDevice currentDevice].identifierForVendor.UUIDString;
}

@end
