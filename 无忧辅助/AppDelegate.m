//
//  AppDelegate.m
//  无忧辅助 - UIKit AppDelegate（仅用于提前初始化 HID 客户端）
//

#import "AppDelegate.h"
#import "TouchSimulation.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 仅初始化 TouchSimulation HID client，不创建额外窗口
    // SwiftUI 的 WindowGroup 会自动管理场景窗口
    [[TouchSimulation sharedInstance] logDiagnostic];

    return YES;
}

@end
