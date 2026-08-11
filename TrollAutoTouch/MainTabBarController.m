//
//  MainTabBarController.m
//  TrollAutoTouch
//

#import "MainTabBarController.h"
#import "Script/TSScriptListViewController.h"
#import "Settings/TSSettingsViewController.h"

@implementation MainTabBarController

- (instancetype)init {
    self = [super init];
    if (self) {
        TSScriptListViewController *scripts = [[TSScriptListViewController alloc] init];
        UINavigationController *nav1 = [[UINavigationController alloc] initWithRootViewController:scripts];
        nav1.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"配置" image:nil tag:0];

        TSSettingsViewController *settings = [[TSSettingsViewController alloc] init];
        UINavigationController *nav2 = [[UINavigationController alloc] initWithRootViewController:settings];
        nav2.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"设置" image:nil tag:1];

        self.viewControllers = @[nav1, nav2];
        self.selectedIndex = 0;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // 深色 TabBar
    if (@available(iOS 13.0, *)) {
        UITabBarAppearance *app = [[UITabBarAppearance alloc] init];
        [app configureWithOpaqueBackground];
        app.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];
        self.tabBar.standardAppearance = app;
        if (@available(iOS 15.0, *)) {
            self.tabBar.scrollEdgeAppearance = app;
        }
    }

    self.tabBar.barTintColor = [UIColor colorWithWhite:0.06 alpha:1];
    self.tabBar.tintColor    = [UIColor colorWithRed:0.3 green:0.6 blue:1.0 alpha:1];
    self.tabBar.unselectedItemTintColor = [UIColor colorWithWhite:0.5 alpha:1];

    // 导航栏深色
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *navApp = [[UINavigationBarAppearance alloc] init];
        [navApp configureWithOpaqueBackground];
        navApp.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];
        navApp.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor whiteColor]};
        [UINavigationBar appearance].standardAppearance = navApp;
        [UINavigationBar appearance].scrollEdgeAppearance = navApp;
    }
}

@end