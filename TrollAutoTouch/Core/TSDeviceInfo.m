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
#import <sys/proc.h>
#import <signal.h>
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

// AssistiveTouch 偏好设置文件路径 (系统级, 由 SpringBoard/assistivetouchd 读取)
// TrollStore 安装的 app 有 rootfs 读写权限, 可直接修改此文件
static NSString *const kAccessibilityPlistPath =
    @"/var/mobile/Library/Preferences/com.apple.Accessibility.plist";

// 通知 SpringBoard/assistivetouchd 重读 Accessibility 设置的 Darwin 通知名
// 这两个通知名是 TrollAutoScript 2.3.6 逆向确认的实际监听名
static const char *const kATCacheChangedNotify1 = "com.apple.accessibility.cache.axsettings";
static const char *const kATCacheChangedNotify2 = "com.apple.accessibility.cache";

// notify_post 声明 (位于 libSystem.dylib, 无需额外链接)
extern int notify_post(const char *name);

// 通过 sysctl 枚举进程并 SIGKILL 指定名称的进程
// iOS 上 system() 不可用, 故用纯 POSIX 方式
static void _tsKillProcessByName(const char *name) {
    int mib[3] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) return;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return;
    if (sysctl(mib, 3, procs, &size, NULL, 0) != 0) {
        free(procs);
        return;
    }
    int count = (int)(size / sizeof(struct kinfo_proc));
    for (int i = 0; i < count; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, name) == 0) {
            kill(procs[i].kp_proc.p_pid, SIGKILL);
            break;
        }
    }
    free(procs);
}

// 判断指定名称的进程是否存活 (用于"按需杀", 避免每轮都杀导致闪烁)
static int _tsIsProcessRunning(const char *name) {
    int mib[3] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) return 0;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return 0;
    if (sysctl(mib, 3, procs, &size, NULL, 0) != 0) {
        free(procs);
        return 0;
    }
    int count = (int)(size / sizeof(struct kinfo_proc));
    int found = 0;
    for (int i = 0; i < count; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, name) == 0) { found = 1; break; }
    }
    free(procs);
    return found;
}

// 预先 dlopen Accessibility 相关私有框架
// AXAccessibilityPreferences 类与 AXSSetAssistiveTouchEnabled 符号均位于
// Accessibility.framework (旧系统可能在 AccessibilityUtilities.framework)
static void _tsEnsureATFrameworkLoaded(void) {
    static int loaded = 0;
    if (loaded) return;
    loaded = 1;
    const char *paths[] = {
        "/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility",
        "/System/Library/Frameworks/Accessibility.framework/Accessibility",
        "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
        "/System/Library/PrivateFrameworks/AccessibilitySettings.framework/AccessibilitySettings",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        dlopen(paths[i], RTLD_LAZY | RTLD_GLOBAL);
    }
}

// 写偏好 (CFPreferences 为主, plist 文件为辅) 并发送通知
// CFPreferences 官方 API 写入能立即更新 cfprefsd 的内存缓存, 无需杀进程
static void _tsWriteATPlist(BOOL enabled) {
    @autoreleasepool {
        CFStringRef app = CFSTR("com.apple.Accessibility");
        CFPropertyListRef val = enabled ? kCFBooleanTrue : kCFBooleanFalse;

        // ① CFPreferences 官方 API 写入 (主手段, 立即生效)
        CFPreferencesSetValue(CFSTR("AXAssistiveTouchEnabled"), val,
                              app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSetValue(CFSTR("AssistiveTouchEnabled"), val,
                              app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

        // ② 同时写磁盘 plist 作为后备 (部分旧系统直接读磁盘)
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:kAccessibilityPlistPath];
        if (!dict) dict = [NSMutableDictionary dictionary];
        dict[@"AXAssistiveTouchEnabled"] = @(enabled);
        dict[@"AssistiveTouchEnabled"] = @(enabled);
        [dict writeToFile:kAccessibilityPlistPath atomically:YES];

        // ③ 发送 Darwin 通知 (双重通知名, 提高触发重载概率)
        notify_post(kATCacheChangedNotify1);
        notify_post(kATCacheChangedNotify2);
    }
}

- (BOOL)enableAssistiveTouch {
    return [self _setAssistiveTouchEnabled:YES];
}

- (BOOL)disableAssistiveTouch {
    return [self _setAssistiveTouchEnabled:NO];
}

- (BOOL)isAssistiveTouchEnabled {
    // 优先用 CFPreferences 读取 (跟实际系统状态一致)
    CFBooleanRef val = (CFBooleanRef)CFPreferencesCopyAppValue(
        CFSTR("AXAssistiveTouchEnabled"), CFSTR("com.apple.Accessibility"));
    if (val) {
        BOOL enabled = CFBooleanGetValue(val);
        CFRelease(val);
        return enabled;
    }
    // 备选: 读 plist
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:kAccessibilityPlistPath];
    if (!plist) return NO;
    for (NSString *key in @[@"AXAssistiveTouchEnabled", @"AssistiveTouchEnabled"]) {
        NSNumber *v = plist[key];
        if ([v isKindOfClass:[NSNumber class]] && v.boolValue) return YES;
    }
    return NO;
}

// 切换辅助触控开关. 绝不杀 cfprefsd (会影响系统其他功能).
// 顺序:
// ① dlopen Accessibility 框架 (否则类/符号找不到);
// ② 优先 ObjC runtime 调 AXAccessibilityPreferences.setAssistiveTouchEnabled: (平滑, 不杀进程);
// ③ 否则 dlsym C 符号 AXSSetAssistiveTouchEnabled;
// ④ 兜底: 写 plist/CFPreferences + 通知; 若 assistivetouchd 仍在运行则"按需杀一次"
//    (仅当进程存活才杀, 硬件未重开时不会反复杀, 避免持续闪烁)
- (BOOL)_setAssistiveTouchEnabled:(BOOL)enabled {
    @autoreleasepool {
        _tsEnsureATFrameworkLoaded();
        BOOL apiDone = NO;

        // ② ObjC runtime (类/方法名是字符串, 不受 strip 影响)
        Class prefsCls = NSClassFromString(@"AXAccessibilityPreferences");
        if (prefsCls) {
            SEL shared = NSSelectorFromString(@"preferences");
            if (![prefsCls respondsToSelector:shared]) shared = NSSelectorFromString(@"sharedPreferences");
            if (![prefsCls respondsToSelector:shared]) shared = NSSelectorFromString(@"sharedInstance");
            if ([prefsCls respondsToSelector:shared]) {
                id prefs = [prefsCls performSelector:shared];
                SEL setSel = NSSelectorFromString(@"setAssistiveTouchEnabled:");
                if (prefs && [prefs respondsToSelector:setSel]) {
                    NSMethodSignature *sig = [prefs methodSignatureForSelector:setSel];
                    if (sig) {
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        [inv setTarget:prefs];
                        [inv setSelector:setSel];
                        [inv setArgument:&enabled atIndex:2];
                        [inv invoke];
                        apiDone = YES;
                    }
                }
            }
        }

        // ③ C 符号 (框架已 dlopen, RTLD_DEFAULT 可检索)
        if (!apiDone) {
            void (*setEnabled)(BOOL) = (void (*)(BOOL))dlsym(RTLD_DEFAULT, "AXSSetAssistiveTouchEnabled");
            if (!setEnabled) setEnabled = (void (*)(BOOL))dlsym(RTLD_DEFAULT, "_AXSSetAssistiveTouchEnabled");
            if (setEnabled) {
                setEnabled(enabled);
                apiDone = YES;
            }
        }

        // ④ 兜底: 始终写偏好 + 通知 (无害且可能直接生效)
        //    assistivetouchd 存活则按需杀一次, 强制其重新读取我们写入的值
        _tsWriteATPlist(enabled);
        notify_post(kATCacheChangedNotify1);
        notify_post(kATCacheChangedNotify2);
        if (_tsIsProcessRunning("assistivetouchd")) {
            // 仅进程存活时杀, 硬件未重开时进程不存活, 不重复杀 → 不闪
            _tsKillProcessByName("assistivetouchd");
        }
        return YES;
    }
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
