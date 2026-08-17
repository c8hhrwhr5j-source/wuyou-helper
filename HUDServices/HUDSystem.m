//
//  HUDSystem.m
//  HUDServices
//
//  dlopen 加载 SpringBoardServices 私有框架, 提供 app 激活能力。
//

#import "HUDSystem.h"
#import <dlfcn.h>

typedef mach_port_t (*SBSSpringBoardServerPort_t)(void);
typedef int (*SBSLaunchApplicationWithIdentifier_t)(mach_port_t port, CFStringRef bundleIdentifier, Boolean suspended);
typedef CFStringRef (*SBSCopyFrontmostApplicationDisplayIdentifier_t)(mach_port_t port, Boolean *result);

@implementation HUDSystem

static SBSSpringBoardServerPort_t _SBSSpringBoardServerPort;
static SBSLaunchApplicationWithIdentifier_t _SBSLaunchApplicationWithIdentifier;
static SBSCopyFrontmostApplicationDisplayIdentifier_t _SBSCopyFrontmostApplicationDisplayIdentifier;

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        if (handle) {
            _SBSSpringBoardServerPort = (SBSSpringBoardServerPort_t)dlsym(handle, "SBSSpringBoardServerPort");
            _SBSLaunchApplicationWithIdentifier = (SBSLaunchApplicationWithIdentifier_t)dlsym(handle, "SBSLaunchApplicationWithIdentifier");
            _SBSCopyFrontmostApplicationDisplayIdentifier = (SBSCopyFrontmostApplicationDisplayIdentifier_t)dlsym(handle, "SBSCopyFrontmostApplicationDisplayIdentifier");
        }
    });
}

+ (BOOL)launchApplicationWithIdentifier:(NSString *)bundleIdentifier {
    if (!bundleIdentifier.length || !_SBSLaunchApplicationWithIdentifier || !_SBSSpringBoardServerPort) {
        return NO;
    }
    mach_port_t port = _SBSSpringBoardServerPort();
    int ret = _SBSLaunchApplicationWithIdentifier(port, (__bridge CFStringRef)bundleIdentifier, false);
    return ret == 0;
}

+ (NSString *)frontmostApplicationIdentifier {
    if (!_SBSCopyFrontmostApplicationDisplayIdentifier || !_SBSSpringBoardServerPort) {
        return nil;
    }
    mach_port_t port = _SBSSpringBoardServerPort();
    Boolean ret = false;
    CFStringRef bid = _SBSCopyFrontmostApplicationDisplayIdentifier(port, &ret);
    if (!bid) {
        return nil;
    }
    NSString *result = (__bridge_transfer NSString *)bid;
    return result;
}

@end
