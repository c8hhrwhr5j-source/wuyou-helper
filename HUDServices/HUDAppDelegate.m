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

static NSString *const kHUDCenterName = @"com.trollautotouch.HUDMessaging";
static NSString *const kAlertRequestName = @"sysAlertRequest:";

@implementation HUDAppDelegate {
    CPDistributedMessagingCenter *_center;
    HUDAlertPresenter *_alertPresenter;
    dispatch_semaphore_t _activationSem;
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

    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    if (_activationSem) {
        dispatch_semaphore_signal(_activationSem);
        _activationSem = nil;
    }
}

#pragma mark - 弹窗请求处理 (后台线程)

- (void)handleAlertRequest:(NSString *)name userInfo:(NSDictionary *)userInfo {
    NSString *title = userInfo[@"title"];
    NSString *message = userInfo[@"message"];
    NSArray *buttons = userInfo[@"buttons"];
    NSTimeInterval timeout = [userInfo[@"timeout"] doubleValue];
    NSString *previousApp = userInfo[@"previousApp"];

    // 若 HUD 不在前台, 激活自己并等待前台就绪
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        _activationSem = dispatch_semaphore_create(0);
        [HUDSystem launchApplicationWithIdentifier:[[NSBundle mainBundle] bundleIdentifier]];
        dispatch_semaphore_wait(_activationSem,
                                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)));
    }

    // 展示对话框并等待用户点击 / 超时
    NSString *result = [_alertPresenter presentAlertWithTitle:title
                                                      message:message
                                                      buttons:buttons
                                                      timeout:timeout];

    // 弹窗结束, 把前台交还给之前的 app
    if (previousApp.length > 0) {
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
