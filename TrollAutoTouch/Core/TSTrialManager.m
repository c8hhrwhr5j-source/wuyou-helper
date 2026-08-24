//
//  TSTrialManager.m
//  TrollAutoTouch
//
//  未激活设备的 15 分钟试用管理实现。
//  计时基于"启动时刻 + 15 分钟"的墙钟截止时间 (进程存活期间不重置),
//  由 GCD 定时器周期性检查 + 回到前台时补检, 保证后台挂机期间到期也能触发。
//

#import "TSTrialManager.h"
#import "TSLicense.h"
#import "TSLuaBridge.h"
#import "TSHUDHost.h"

static const NSTimeInterval kTSTrialDuration = 15 * 60.0;   // 试用时长: 15 分钟
static const NSTimeInterval kTSTrialCheckInterval = 2.0;    // 到期检查间隔(秒)
static const NSTimeInterval kTSLicenseRefreshInterval = 6 * 60 * 60.0; // 已激活状态下的周期联网校验间隔(秒)

NSNotificationName const TSTrialStateChangedNotification = @"TSTrialStateChangedNotification";

@interface TSTrialManager ()
@property (nonatomic, assign) BOOL expired;
@property (nonatomic, strong) NSDate *deadline;      // 试用截止时刻
@property (nonatomic, strong) dispatch_source_t timer;               // 试用到期检查定时器
@property (nonatomic, strong) dispatch_source_t licenseRefreshTimer; // 已激活状态周期校验定时器(6h)
@end

@implementation TSTrialManager

+ (instancetype)shared {
    static TSTrialManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TSTrialManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_appDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    if (_licenseRefreshTimer) {
        dispatch_source_cancel(_licenseRefreshTimer);
        _licenseRefreshTimer = nil;
    }
}

// MARK: - 对外接口

- (void)startIfNeeded {
    if ([[TSLicense shared] isActivated]) {
        // 已激活: 无试用限制; 但每次启动都要与服务器校验卡密是否仍可用
        [self cancelTrial];
        [self _startLicenseRefreshTimer]; // 已激活期间周期(6h)联网校验
        [self _verifyLicenseAsync];       // 启动立即校验
        return;
    }
    if (!_deadline) {
        // 未激活且未在计时: 从"本次启动"起重新获得 15 分钟窗口
        self.deadline = [NSDate dateWithTimeIntervalSinceNow:kTSTrialDuration];
        self.expired = NO;
        [self _startTimer];
    }
    // 已有窗口(进程存活期间)不重置; 每次冷启动天然获得新窗口
    [self _checkExpiry];
}

- (void)cancelTrial {
    [self _stopTimer];
    self.deadline = nil;
    self.expired = NO;
}

- (BOOL)isExpired {
    return _expired;
}

- (BOOL)isTrialActive {
    return ![[TSLicense shared] isActivated] && !_expired;
}

- (NSTimeInterval)remainingSeconds {
    if ([[TSLicense shared] isActivated] || !_deadline) return 0;
    NSTimeInterval rem = [_deadline timeIntervalSinceNow];
    return rem > 0 ? rem : 0;
}

// MARK: - 内部

- (void)_startTimer {
    if (_timer) return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_walltime(NULL, 0),
                              (uint64_t)(kTSTrialCheckInterval * NSEC_PER_SEC), 0);
    __weak typeof(self) ws = self;
    dispatch_source_set_event_handler(t, ^{
        [ws _checkExpiry];
    });
    dispatch_resume(t);
    _timer = t;
}

- (void)_stopTimer {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

// 已激活状态下的周期联网校验定时器(每 6 小时一次, 幂等)
- (void)_startLicenseRefreshTimer {
    if (_licenseRefreshTimer) return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_walltime(NULL, kTSLicenseRefreshInterval * NSEC_PER_SEC),
                              (uint64_t)(kTSLicenseRefreshInterval * NSEC_PER_SEC), 0);
    __weak typeof(self) ws = self;
    dispatch_source_set_event_handler(t, ^{
        [ws _verifyLicenseAsync];
    });
    dispatch_resume(t);
    _licenseRefreshTimer = t;
}

// 已激活设备的联网校验: 后台线程回调, 结果回主线程处理
- (void)_verifyLicenseAsync {
    if (![[TSLicense shared] isActivated]) return; // 未激活时无需校验(如已被判失效转入试用)
    __weak typeof(self) ws = self;
    [[TSLicense shared] refreshValidWithCompletion:^(BOOL valid, BOOL networkError, NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) self = ws;
            if (!self) return;
            if (valid) {
                // 校验通过(可能已同步最新到期时间): 刷新设置页卡密区展示
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:TSTrialStateChangedNotification object:self];
                return;
            }
            if (networkError) {
                // 网络异常: 离线放行, 保持已激活状态, 不打扰用户
                return;
            }
            // 服务端明确判定卡密无效(已清除本地激活): 立即进入 15 分钟试用
            [self startIfNeeded];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:TSTrialStateChangedNotification object:self];
            [[TSHUDHost shared] showToast:(msg.length ? msg : @"卡密已失效，进入 15 分钟试用")
                                 duration:3 hidden:NO];
        });
    }];
}

- (void)_appDidBecomeActive:(NSNotification *)note {
    // 回到前台补检: 后台期间脚本可能仍在运行, 或许已超过 15 分钟窗口
    if (![[TSLicense shared] isActivated]) {
        [self _checkExpiry];
    }
}

- (void)_checkExpiry {
    if (_expired) return;
    if ([[TSLicense shared] isActivated]) {
        // 试用期间完成了激活
        [self cancelTrial];
        return;
    }
    if (_deadline && [[NSDate date] compare:_deadline] != NSOrderedAscending) {
        // 15 分钟到点: 强制停止该设备上运行的所有脚本, 并阻止后续启动
        self.expired = YES;
        [self _stopTimer];
        [[TSLuaBridge shared] stop];
        [[TSHUDHost shared] showToast:@"15 分钟试用已结束，请到 设置-卡密 激活后继续使用"
                             duration:3
                               hidden:NO];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TSTrialStateChangedNotification object:self];
    }
}

@end
