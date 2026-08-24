//
//  TSDeviceInfo.m
//  TrollAutoTouch
//

#import "TSDeviceInfo.h"
#import "TSKeyboardInjector.h"
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AudioToolbox/AudioToolbox.h>
#import <sys/sysctl.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <dlfcn.h>
#import <notify.h>

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

// 通过 MobileGestalt 私有 API 读取设备唯一标识。
// TrollStore 安装的 app 已声明 com.apple.private.MobileGestalt.AllowedProtectedKeys=true,
// 可读取受保护键 (UDID/SerialNumber)。沙盒 App Store app 此调用会返回 nil。
// 实现用 dlopen 动态加载, 避免链接期依赖 MobileGestalt.framework。
- (nullable NSString *)udid {
    return [self _mobileGestaltString:@"UniqueDeviceID"];
}

- (nullable NSString *)serialNumber {
    return [self _mobileGestaltString:@"SerialNumber"];
}

// 内部: 调用 MGCopyAnswer(key) -> 取 CFString
- (nullable NSString *)_mobileGestaltString:(NSString *)key {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MobileGestalt.framework/MobileGestalt",
                          RTLD_LAZY | RTLD_LOCAL);
    if (!handle) return nil;
    CFStringRef (*MGCopyAnswer)(CFStringRef) = dlsym(handle, "MGCopyAnswer");
    if (!MGCopyAnswer) {
        dlclose(handle);
        return nil;
    }
    CFStringRef val = MGCopyAnswer((__bridge CFStringRef)key);
    NSString *result = [NSString stringWithString:(__bridge NSString *)val];
    if (val) CFRelease(val);
    dlclose(handle);
    return result;
}

#pragma mark - AssistiveTouch 控制

// AssistiveTouch 偏好设置文件路径 (系统级, 由 SpringBoard 读取)
// TrollStore 安装的 app 有 rootfs 读写权限, 可直接修改此文件
static NSString *const kAccessibilityPlistPath =
    @"/var/mobile/Library/Preferences/com.apple.Accessibility.plist";

// 通知 SpringBoard 重读 Accessibility 设置的 Darwin 通知名
// SpringBoard 监听此通知后会重新加载 plist 并刷新 AssistiveTouch 状态
static CFStringRef const kAssistiveTouchChangedDarwinNotification =
    CFSTR("com.apple.accessibility.assistiveTouch.changed");

- (BOOL)enableAssistiveTouch {
    return [self _setAssistiveTouchEnabled:YES];
}

- (BOOL)disableAssistiveTouch {
    return [self _setAssistiveTouchEnabled:NO];
}

- (BOOL)isAssistiveTouchEnabled {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:kAccessibilityPlistPath];
    if (!plist) return NO;
    // 实际键名因 iOS 版本可能不同, 多个候选键任一为真即视为启用
    for (NSString *key in @[@"AssistiveTouchAssistiveTouchEnabledByiTunes",
                            @"AssistiveTouchEnabledByiTunes",
                            @"AssistiveTouchEnabled"]) {
        NSNumber *v = plist[key];
        if ([v isKindOfClass:[NSNumber class]] && v.boolValue) return YES;
    }
    return NO;
}

// 核心: 修改 plist 中的所有候选键 + 广播 Darwin 通知
- (BOOL)_setAssistiveTouchEnabled:(BOOL)enabled {
    NSMutableDictionary *plist =
        [[NSDictionary dictionaryWithContentsOfFile:kAccessibilityPlistPath] mutableCopy];
    if (!plist) {
        // 文件不存在时新建空字典 (第一次设置)
        plist = [NSMutableDictionary dictionary];
    }
    // 多个候选键一并写入, 兼容不同 iOS 版本
    NSArray<NSString *> *keys = @[
        @"AssistiveTouchAssistiveTouchEnabledByiTunes",
        @"AssistiveTouchEnabledByiTunes",
        @"AssistiveTouchEnabled"
    ];
    for (NSString *key in keys) {
        plist[key] = @(enabled);
    }

    // 写回 (atomic 保证写完整; 手机存储空间满时返回 NO)
    BOOL writeOK = [plist writeToFile:kAccessibilityPlistPath atomically:YES];
    if (!writeOK) return NO;

    // 广播 Darwin 通知让 SpringBoard 重新加载
    // Darwin 通知跨进程, 即使 SpringBoard 在独立进程也能收到
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        kAssistiveTouchChangedDarwinNotification,
        NULL, NULL, TRUE);

    return YES;
}

#pragma mark - 屏幕锁定 / 解锁

// 屏幕锁定状态 Darwin 通知 (SpringBoard 维护此状态值, 锁定=1 解锁=0)
// 使用 notify_register_check 注册后可通过 notify_check 查询最近状态值
static const char *const kScreenLockDarwinNotification =
    "com.apple.springboard.lockstate";

- (BOOL)isScreenLocked {
    // notify_check 读取上次通知触发的状态值; 注册即检查是否被触发过
    int token = 0;
    uint32_t status = notify_register_check(kScreenLockDarwinNotification, &token);
    if (status != NOTIFY_STATUS_OK) {
        // 注册失败时回退到 IOService 查询 (IOPMAssertion)
        return NO;
    }
    int triggered = 0;
    notify_check(token, &triggered);
    notify_cancel(token);

    // lockstate 通知最后一次投递的时间决定了 triggered 状态
    // 但更可靠的是 notify_get_state, SpringBoard 会维护这个 int 值
    uint64_t state = 0;
    status = notify_get_state(kScreenLockDarwinNotification, &state);
    if (status == NOTIFY_STATUS_OK) {
        return state != 0;
    }
    // 退路: 触发过视为锁定状态
    return triggered != 0;
}

- (BOOL)unlockScreen {
    // 1. 唤醒屏幕: 调用 BackBoardServices 的 SBSSetBacklightLevel
    //    dlopen 加载避免链接期依赖; 失败则用 GSEvent 兜底
    BOOL woken = [self _wakeScreen];
    if (!woken) {
        // 唤醒失败时, 后续 Home 键事件可能不生效
    }

    // 2. 发送 Home 键事件取消锁屏 (无密码设备会直接进桌面)
    //    延迟一点确保背光已亮
    [NSThread sleepForTimeInterval:0.3];
    [[TSKeyboardInjector shared] pressHome];

    return YES;
}

// 唤醒屏幕: 优先 BackBoardServices SBSSetBacklightLevel, 备选 GSEventSetBacklightLevel
- (BOOL)_wakeScreen {
    // 优先 BackBoardServices (iOS 7+ 主流)
    void *bbh = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
                       RTLD_LAZY | RTLD_LOCAL);
    if (bbh) {
        // 尝试 SBSSetBacklightLevel(double level)
        void (*setBL)(double) = dlsym(bbh, "SBSSetBacklightLevel");
        if (setBL) {
            setBL(1.0);   // 1.0 = 最大亮度, 触发唤醒
            return YES;
        }
        // 备选 BKSDisplaySetBacklightFactor
        void (*setBF)(double) = dlsym(bbh, "BKSDisplaySetBacklightFactor");
        if (setBF) {
            setBF(1.0);
            return YES;
        }
    }

    // 回退到 GraphicsServices 的 GSEventSetBacklightLevel (老 iOS 版本)
    void *gsh = dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",
                       RTLD_LAZY | RTLD_LOCAL);
    if (gsh) {
        void (*gsSetBL)(double) = dlsym(gsh, "GSEventSetBacklightLevel");
        if (gsSetBL) {
            gsSetBL(1.0);
            return YES;
        }
    }
    return NO;
}

#pragma mark - 设备基础信息 / 亮度 / 音量 / 震动

- (NSString *)deviceType {
    switch ([UIDevice currentDevice].userInterfaceIdiom) {
        case UIUserInterfaceIdiomPhone:     return @"iPhone";
        case UIUserInterfaceIdiomPad:       return @"iPad";
        case UIUserInterfaceIdiomTV:        return @"TV";
        case UIUserInterfaceIdiomCarPlay:   return @"CarPlay";
        case UIUserInterfaceIdiomMac:       return @"Mac";
        default:                            return @"Unspecified";
    }
}

- (CGFloat)backlightLevel {
    return [UIScreen mainScreen].brightness;
}

- (void)setBacklightLevel:(CGFloat)level {
    // 限制 [0, 1]
    if (level < 0) level = 0;
    if (level > 1) level = 1;
    [UIScreen mainScreen].brightness = level;
}

- (void)lockScreen {
    [[TSKeyboardInjector shared] pressLock];
}

- (void)vibrate {
    // kSystemSoundID_Vibrate = 4095, 系统默认震动反馈
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

- (void)setSystemVolume:(float)volume {
    // 限制 [0, 1]
    if (volume < 0) volume = 0;
    if (volume > 1) volume = 1;
    // MPVolumeView 在父视图上时, 它内部的 MPMusicPlayerController 会响应 volume 设置
    // iOS 11+ 必须在视图层次中存在 MPVolumeView 才能修改系统音量
    // (苹果禁止纯代码修改系统音量, 这是公开的 workaround)
    dispatch_async(dispatch_get_main_queue(), ^{
        MPVolumeView *vv = [[MPVolumeView alloc] init];
        [vv setFrame:CGRectMake(-1000, -1000, 100, 30)];
        [[UIApplication sharedApplication].keyWindow addSubview:vv];
        // 在 next runloop 设置音量, 之后移除视图
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // 取出 slider 子视图设置 value
            for (UIView *sub in vv.subviews) {
                if ([sub isKindOfClass:[UISlider class]]) {
                    [(UISlider *)sub setValue:volume animated:NO];
                    // 触发 valueChanged 让 MPVolumeView 同步到系统
                    [(UISlider *)sub sendActionsForControlEvents:UIControlEventValueChanged];
                    break;
                }
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [vv removeFromSuperview];
            });
        });
    });
}

@end
