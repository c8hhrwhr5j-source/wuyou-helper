//
//  TSLocationKeepAlive.m
//  TrollAutoTouch
//

#import "TSLocationKeepAlive.h"
#import "TSLogStore.h"

@implementation TSLocationKeepAlive {
    CLLocationManager *_lm;
    BOOL _running;
    BOOL _requestedOnce;
}

+ (instancetype)shared {
    static TSLocationKeepAlive *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[TSLocationKeepAlive alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lm = [[CLLocationManager alloc] init];
        _lm.delegate = self;
        // 粗精度 + 大距离过滤: 仅用于保活, 不追求定位精度, 大幅省电
        _lm.desiredAccuracy = kCLLocationAccuracyKilometer;
        _lm.distanceFilter = 500;
        _lm.activityType = CLActivityTypeOtherNavigation;  // 导航类: 保持后台持续定位
        if (@available(iOS 9.0, *)) {
            _lm.pausesLocationUpdatesAutomatically = NO;   // 禁止系统暂停定位(防后台失活)
            _lm.allowsBackgroundLocationUpdates = YES;     // 需要 UIBackgroundModes: location
        }
    }
    return self;
}

- (void)start {
    if (_running) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_running) return;
        self->_running = YES;

        CLAuthorizationStatus st = [self authorizationStatus];
        NSString *log = [NSString stringWithFormat:
            @"定位保活: 启动持续定位 授权状态=%ld(%@)",
            (long)st, [self statusString:st]];
        NSLog(@"[定位保活] %@", log);
        [[TSLogStore shared] append:log];

        if (st == kCLAuthorizationStatusNotDetermined && !self->_requestedOnce) {
            self->_requestedOnce = YES;
            // 正常情况下 entitlements 预授权(kTCCServiceLocation)使状态直接为
            // Always, 无需弹窗; 仅当预授权未生效时才需要请求(会弹窗一次)。
            if (@available(iOS 8.0, *)) {
                [self->_lm requestAlwaysAuthorization];
            }
        } else if (st == kCLAuthorizationStatusAuthorizedWhenInUse) {
            NSString *warn = @"定位保活: 警告 仅\"使用期间\"授权, 后台保活将无效, 请到 设置-隐私-定位服务 改为\"始终\"";
            NSLog(@"[定位保活] %@", warn);
            [[TSLogStore shared] append:warn];
        } else if (st == kCLAuthorizationStatusDenied || st == kCLAuthorizationStatusRestricted) {
            NSString *warn = [NSString stringWithFormat:
                @"定位保活: 警告 定位被拒绝(%@), 后台保活将无效", [self statusString:st]];
            NSLog(@"[定位保活] %@", warn);
            [[TSLogStore shared] append:warn];
        }

        [self->_lm startUpdatingLocation];
        // ── 开机自启(近似): 重大位置变化监听(SLC) ──
        // SLC 注册由系统 daemons 持久记录: app 被杀/设备重启后依然有效,
        // 重启后首次基站切换/移动 ~500m 时系统自动在后台拉起本 app 进程,
        // didFinishLaunching 无条件启动 TAS 服务 + 8080 端口, 保活链自动接管。
        // 非越狱 TrollStore 下这是唯一可用的"重启后自动恢复"通道
        // (真正的开机 LaunchDaemon 需要 platform 身份, 仅越狱可实现)。
        // 注意: SLC 与标准定位可并存, 且 SLC 不受 background 模式限制。
        [self->_lm startMonitoringSignificantLocationChanges];
        NSLog(@"[定位保活] startUpdatingLocation 已调用, SLC 重启自启监听已注册");
    });
}

- (void)stop {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_running) return;
        self->_running = NO;
        [self->_lm stopUpdatingLocation];
        // 刻意【不】注销 SLC: stopAll 会在 appWillTerminate/dealloc 等终止路径被调用,
        // 若随之注销 SLC, 系统级注册丢失, 重启/被杀后的自动拉起即失效。
        // SLC 注册是系统持久化的, 保持即可(用户强杀 app 后 iOS 本身也不再自动拉起)。
        NSLog(@"[定位保活] 持续定位已停止(SLC 自启监听保留)");
    });
}

// 注销 SLC 重启自启监听 —— 仅在用户于设置页明确关闭 TAS 服务时调用。
- (void)stopSystemRelaunchWatch {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_lm stopMonitoringSignificantLocationChanges];
        NSLog(@"[定位保活] SLC 自启监听已注销(用户关闭 TAS 服务)");
    });
}

- (BOOL)isRunning {
    return _running;
}

- (CLAuthorizationStatus)authorizationStatus {
    return [CLLocationManager authorizationStatus];
}

- (NSString *)statusString:(CLAuthorizationStatus)st {
    switch (st) {
        case kCLAuthorizationStatusNotDetermined: return @"未决定";
        case kCLAuthorizationStatusRestricted: return @"受限制";
        case kCLAuthorizationStatusDenied: return @"已拒绝";
        case kCLAuthorizationStatusAuthorizedAlways: return @"始终允许";
        case kCLAuthorizationStatusAuthorizedWhenInUse: return @"使用期间";
        default: return @"未知";
    }
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    CLAuthorizationStatus st = [self authorizationStatus];
    NSLog(@"[定位保活] 授权状态变化: %ld(%@)", (long)st, [self statusString:st]);
    if (st == kCLAuthorizationStatusAuthorizedAlways && _running) {
        [manager startUpdatingLocation];
    }
}

- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *loc = locations.lastObject;
    if (!loc) return;
    NSLog(@"[定位保活] 定位更新: %.4f,%.4f acc=%.0fm",
          loc.coordinate.latitude, loc.coordinate.longitude, loc.horizontalAccuracy);
}

- (void)locationManager:(CLLocationManager *)manager
       didFailWithError:(NSError *)error {
    NSLog(@"[定位保活] 定位失败: %@", error.localizedDescription);
}

@end
