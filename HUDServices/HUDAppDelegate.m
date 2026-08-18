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
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 全屏透明窗口 (windowLevel 抬高, 确保可见)
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.windowLevel = UIWindowLevelStatusBar + 100;
    self.window.backgroundColor = [UIColor clearColor];

    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    self.window.rootViewController = rootVC;
    [self.window makeKeyAndVisible];

    _alertPresenter = [[HUDAlertPresenter alloc] initWithPresenter:rootVC];

    // 注册消息中心 (后台线程 run server, handler 在后台线程被调用)
    _center = [CPDistributedMessagingCenter centerNamed:kHUDCenterName];
    [_center registerForMessageName:kAlertRequestName
                             target:self
                           selector:@selector(handleAlertRequest:userInfo:)];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self->_center runServerOnCurrentThread];
    });

    // iOS 15+: 把窗口注册到 SpringBoard 的 accessibility 窗口层
    // (makeKeyAndVisible 后 layer 需一轮 runloop 才绑定 CAContext, 故延迟重试)
    [self _registerAccessibilityHostingWithRetryCount:10];

    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // app 激活后 window 的 CAContext 可能重建 (contextId 变化), 重新注册
    [self _registerAccessibilityHostingWithRetryCount:10];
}

#pragma mark - 系统级窗口托管 (SBSAccessibilityWindowHostingController)

- (BOOL)_registerAccessibilityHostingWithRetryCount:(NSInteger)retryCount {
    if (retryCount <= 0) return NO;

    unsigned ctxId = (unsigned)[self.window.layer contextId];
    if (ctxId == 0) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(self) self = weakSelf;
            if (self) {
                [self _registerAccessibilityHostingWithRetryCount:retryCount - 1];
            }
        });
        return NO;
    }

    if (_registeredContextId == ctxId) return YES; // 已注册

    if (!_sbsHostingCtrl) {
        _sbsHostingCtrl = [[SBSAccessibilityWindowHostingController alloc] init];
    }
    if (_registeredContextId != 0) {
        [_sbsHostingCtrl unregisterWindowWithContextID:_registeredContextId];
    }
    [_sbsHostingCtrl registerWindowWithContextID:ctxId atLevel:kSBSHostingWindowLevel];
    _registeredContextId = ctxId;
    NSLog(@"[HUDServices] accessibility window hosting registered: contextId=%u", ctxId);
    return YES;
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
