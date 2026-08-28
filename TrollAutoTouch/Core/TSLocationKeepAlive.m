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
        NSLog(@"[定位保活] startUpdatingLocation 已调用");
    });
}

- (void)stop {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_running) return;
        self->_running = NO;
        [self->_lm stopUpdatingLocation];
        NSLog(@"[定位保活] 持续定位已停止");
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
