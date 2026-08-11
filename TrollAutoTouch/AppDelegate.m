//
//  AppDelegate.m
//  TrollAutoTouch
//

#import "AppDelegate.h"
#import "TSHUDWindow.h"
#import "TSDaemonManager.h"
#import "TSHTTPServer.h"
#import "TSToolExecutor.h"
#import <AVFoundation/AVFoundation.h>

@interface AppDelegate ()
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    // 配置音频会话（后台保活用）
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                    withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                          error:nil];

    // 启动守护服务（悬浮窗 + 后台保活）
    dispatch_async(dispatch_get_main_queue(), ^{
        [[TSHUDWindow shared] show];
        [[TSDaemonManager shared] startAll];

        // 自动启动 Web 服务器（端口 8080）
        if (![[TSHTTPServer shared] isRunning]) {
            if ([[TSHTTPServer shared] start]) {
                NSString *wifiIP = [[TSToolExecutor shared] wifiIPAddress];
                NSLog(@"[App] Web 远程控制: http://%@:%d", wifiIP ?: @"localhost", [[TSHTTPServer shared] port]);
            }
        }
    });

    return YES;
}

// ---------- Scene 生命周期(适配 iOS 13+) ----------
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                 options:(UISceneConnectionOptions *)options {
    return [UISceneConfiguration configurationWithName:@"Default"
                                          sessionRole:connectingSceneSession.role];
}

- (void)application:(UIApplication *)application
    didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {}

@end
