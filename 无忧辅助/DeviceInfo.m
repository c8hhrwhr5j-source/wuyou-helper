//
//  DeviceInfo.m
//  无忧辅助
//
//  设备信息获取实现
//

#import "DeviceInfo.h"
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <dlfcn.h>

@implementation DeviceInfo

+ (NSString *)deviceUUID {
    void* handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!handle) return @"无权限";
    
    typedef kern_return_t (*IOMasterPortFn)(mach_port_t bootstrapPort, mach_port_t *masterPort);
    IOMasterPortFn IOMasterPort = dlsym(handle, "IOMasterPort");
    if (!IOMasterPort) {
        dlclose(handle);
        return @"无权限";
    }
    
    mach_port_t masterPort;
    kern_return_t result = IOMasterPort(MACH_PORT_NULL, &masterPort);
    if (result != KERN_SUCCESS) {
        dlclose(handle);
        return @"无权限";
    }
    
    typedef io_service_t (*IOServiceGetMatchingServiceFn)(mach_port_t masterPort, CFDictionaryRef matching);
    IOServiceGetMatchingServiceFn IOServiceGetMatchingService = dlsym(handle, "IOServiceGetMatchingService");
    
    typedef CFDictionaryRef (*IOServiceMatchingFn)(const char *name);
    IOServiceMatchingFn IOServiceMatching = dlsym(handle, "IOServiceMatching");
    
    typedef CFTypeRef (*IORegistryEntryCreateCFPropertyFn)(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options);
    IORegistryEntryCreateCFPropertyFn IORegistryEntryCreateCFProperty = dlsym(handle, "IORegistryEntryCreateCFProperty");
    
    typedef void (*IOObjectReleaseFn)(io_object_t object);
    IOObjectReleaseFn IOObjectRelease = dlsym(handle, "IOObjectRelease");
    
    if (!IOServiceGetMatchingService || !IOServiceMatching || !IORegistryEntryCreateCFProperty || !IOObjectRelease) {
        dlclose(handle);
        return @"无权限";
    }
    
    io_service_t service = IOServiceGetMatchingService(masterPort, IOServiceMatching("IOPlatformExpertDevice"));
    NSString *uuid = @"无权限";
    
    if (service != IO_OBJECT_NULL) {
        CFTypeRef cfUUID = IORegistryEntryCreateCFProperty(service, CFSTR("IOPlatformUUID"), kCFAllocatorDefault, 0);
        if (cfUUID) {
            uuid = (__bridge_transfer NSString *)cfUUID;
        }
        IOObjectRelease(service);
    }
    
    dlclose(handle);
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
