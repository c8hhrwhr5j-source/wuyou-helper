//
//  AppDelegate.m
//  无忧辅助 - UIKit AppDelegate（与触控精灵一致的 UIKit 生命周期）
//

#import "AppDelegate.h"
#import "TouchSimulation.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 创建窗口并设为 key window — 触控精灵也是这么做的
    // 这确保 UIApplication 完整初始化并正确注册到 window server / SpringBoard
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    [self.window makeKeyAndVisible];

    // TouchSimulation 初始化 HID client（尽早初始化，确保权限到位）
    [[TouchSimulation sharedInstance] logDiagnostic];

    return YES;
}

@end
