//
//  HUDAppDelegate.m
//  HUDServices
//
//  应用代理: 建立全屏透明窗口 + CPDistributedMessagingCenter 服务端,
//  处理来自主 App 的全局弹窗请求 (sysAlertRequest:)。
//
//  线程模型:
//  - 消息中心在后台线程 run server, 因此 handler 在后台线程执行,
//    可以安全地阻塞等待用户点击 UIAlertController 的结果。
//  - UI 操作 (present/dismiss) 通过 dispatch_async 切回主线程。
//

#import "HUDAppDelegate.h"
#import "HUDAlertPresenter.h"
#import "HUDSystem.h"
#import "HUDServicesPrivate.h"
#import <QuartzCore/QuartzCore.h>
#import <sys/time.h>

static NSString *const kHUDCenterName = @"com.trollautotouch.HUDMessaging";
static NSString *const kAlertRequestName = @"sysAlertRequest:";

// 系统级窗口托管层级: 高于普通 app 内容(UIWindowLevelAlert 为 2000),
// 足以盖住所有前台 app 的窗口。
static const double kSBSHostingWindowLevel = 10000.0;

@implementation HUDAppDelegate {
    CPDistributedMessagingCenter *_center;
    HUDAlertPresenter *_alertPresenter;
    // iOS 15+: 通过 SBSAccessibilityWindowHostingController 把本进程窗口的
    // CAContext 注册到 SpringBoard 的 accessibility 窗口层, 实现
    // "不依赖 app 前台" 的系统级弹窗 (逆向自 AutoGoRunner/agoverlayd)。
    SBSAccessibilityWindowHostingController *_sbsHostingCtrl;
    unsigned _registeredContextId;
    BOOL _startupFailedSBS;
}

// 启动日志落盘到 /tmp/hud_startup.log, 便于在无 Xcode 环境下排查启动/崩溃路径。
static void HUDLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    struct timeval tv;
    gettimeofday(&tv, NULL);
    NSString *line = [NSString stringWithFormat:@"[%.3f] %@\n",
                      tv.tv_sec + tv.tv_usec / 1000000.0, msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/hud_startup.log"];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:@"/tmp/hud_startup.log"
                                               contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:@"/tmp/hud_startup.log"];
    }
    if (fh) {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {
            // 日志写失败不影响主流程
        }
    }
    NSLog(@"%@", msg);
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    @try {
        // 全屏透明窗口 (windowLevel 抬高, 确保可见)
        self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        self.window.windowLevel = UIWindowLevelStatusBar + 100;
        self.window.backgroundColor = [UIColor clearColor];

        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        self.window.rootViewController = rootVC;
        [self.window makeKeyAndVisible];

        _alertPresenter = [[HUDAlertPresenter alloc] initWithPresenter:rootVC];
        HUDLog(@"didFinishLaunching: window ok");

        // 注册消息中心 (后台线程 run server, handler 在后台线程被调用)
        // 注意: 在 iOS 15.5+ TrollStore (无 platform 身份) 环境下,
        // runServerOnCurrentThread 的 mach 端口注册可能失败甚至 abort,
        // 必须 try-catch + 延迟执行, 避免启动即崩。
        @try {
            _center = [CPDistributedMessagingCenter centerNamed:kHUDCenterName];
            [_center registerForMessageName:kAlertRequestName
                                     target:self
                                   selector:@selector(handleAlertRequest:userInfo:)];
            HUDLog(@"messaging center registered");
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                @try {
                    [self->_center runServerOnCurrentThread];
                    HUDLog(@"messaging server running");
                } @catch (NSException *e) {
                    HUDLog(@"messaging server exception: %@", e);
                }
            });
        } @catch (NSException *e) {
            HUDLog(@"messaging center exception: %@", e);
        }
    } @catch (NSException *e) {
        HUDLog(@"didFinishLaunching exception: %@", e);
    }

    // iOS 15+: 把窗口注册到 SpringBoard 的 accessibility 窗口层。
    // 延迟到首轮 runloop 之后执行 (makeKeyAndVisible 后 layer 需一轮
    // runloop 才绑定 CAContext)。整个调用链都 try-catch 保护, 失败只降级
    // (弹窗回退"激活前台"路径), 绝不让 HUD 进程崩溃。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self _registerAccessibilityHostingWithRetryCount:10];
    });

    HUDLog(@"didFinishLaunching done");
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // app 激活后 window 的 CAContext 可能重建 (contextId 变化), 重新注册
    if (_startupFailedSBS) return;
    [self _registerAccessibilityHostingWithRetryCount:5];
}

#pragma mark - 系统级窗口托管 (SBSAccessibilityWindowHostingController)

- (BOOL)_registerAccessibilityHostingWithRetryCount:(NSInteger)retryCount {
    if (retryCount <= 0) {
        HUDLog(@"accessibility hosting: retry exhausted, fallback to foreground");
        _startupFailedSBS = YES;
        return NO;
    }

    @try {
        // 类型检查: contextId 是 CALayer 私有属性, 用 respondsToSelector 兜底
        CALayer *layer = self.window.layer;
        if (!layer) return NO;
        unsigned ctxId = 0;
        if ([layer respondsToSelector:@selector(contextId)]) {
            ctxId = (unsigned)[layer contextId];
        }
        if (ctxId == 0) {
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                __strong typeof(self) self = weakSelf;
                if (self && !self->_startupFailedSBS) {
                    [self _registerAccessibilityHostingWithRetryCount:retryCount - 1];
                }
            });
            return NO;
        }

        if (_registeredContextId == ctxId) return YES; // 已注册

        Class sbsClass = NSClassFromString(@"SBSAccessibilityWindowHostingController");
        if (!sbsClass) {
            HUDLog(@"accessibility hosting: SBS class missing");
            _startupFailedSBS = YES;
            return NO;
        }

        if (!_sbsHostingCtrl) {
            _sbsHostingCtrl = [[sbsClass alloc] init];
        }
        if (_registeredContextId != 0) {
            SEL unregSel = NSSelectorFromString(@"unregisterWindowWithContextID:");
            if ([_sbsHostingCtrl respondsToSelector:unregSel]) {
                void (*fn)(id, SEL, unsigned) = (void (*)(id, SEL, unsigned))[_sbsHostingCtrl methodForSelector:unregSel];
                if (fn) fn(_sbsHostingCtrl, unregSel, _registeredContextId);
            }
        }
        SEL regSel = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
        if ([_sbsHostingCtrl respondsToSelector:regSel]) {
            void (*fn)(id, SEL, unsigned, double) = (void (*)(id, SEL, unsigned, double))[_sbsHostingCtrl methodForSelector:regSel];
            if (fn) fn(_sbsHostingCtrl, regSel, ctxId, kSBSHostingWindowLevel);
            _registeredContextId = ctxId;
            HUDLog(@"accessibility window hosting registered: contextId=%u", ctxId);
        } else {
            HUDLog(@"accessibility hosting: register selector missing");
            _startupFailedSBS = YES;
        }
        return YES;
    } @catch (NSException *e) {
        HUDLog(@"accessibility hosting exception: %@", e);
        _startupFailedSBS = YES;
        return NO;
    }
}

#pragma mark - 弹窗请求处理 (后台线程)

- (void)handleAlertRequest:(NSString *)name userInfo:(NSDictionary *)userInfo {
    NSString *title = userInfo[@"title"];
    NSString *message = userInfo[@"message"];
    NSArray *buttons = userInfo[@"buttons"];
    NSTimeInterval timeout = [userInfo[@"timeout"] doubleValue];
    NSString *previousApp = userInfo[@"previousApp"];

    // 窗口已通过 SBSAccessibilityWindowHostingController 托管到系统级,
    // 无论 HUD 是否在前台都能显示弹窗, 无需再激活自己抢前台。
    // 兜底: 若托管未就绪(contextId 未注册成功), 回退到激活前台保证弹窗可见。
    BOOL needForegroundFallback = (_registeredContextId == 0 &&
        [UIApplication sharedApplication].applicationState != UIApplicationStateActive);
    if (needForegroundFallback) {
        [HUDSystem launchApplicationWithIdentifier:[[NSBundle mainBundle] bundleIdentifier]];
    }

    NSString *result = [_alertPresenter presentCustomAlertWithTitle:title
                                                            message:message
                                                            buttons:buttons
                                                            timeout:timeout];

    // fallback 路径(激活过前台): 弹窗结束后交还前台
    if (needForegroundFallback && previousApp.length > 0) {
        [HUDSystem launchApplicationWithIdentifier:previousApp];
    }

    // 同步回复结果给主 App
    if (_center && result.length > 0) {
        [_center sendReplyForMessage:name userInfo:@{ @"result": result }];
    } else if (_center) {
        [_center sendReplyForMessage:name userInfo:@{ @"result": @"" }];
    }
}

@end
