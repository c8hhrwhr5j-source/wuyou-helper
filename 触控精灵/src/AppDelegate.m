/**
 *  AppDelegate.m
 *  创建主窗口并初始化脚本引擎
 */

#import "AppDelegate.h"
#import "ViewController.h"
#import "ScriptEngine.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor blackColor];

    ViewController *vc = [[ViewController alloc] init];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    // 预初始化 Lua 虚拟机
    [[ScriptEngine shared] initialize];

    return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [[ScriptEngine shared] destroy];
}

@end
