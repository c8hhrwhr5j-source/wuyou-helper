//
//  MainTabBarController.m
//  TrollAutoTouch
//
//  底部双标签：配置 (脚本列表) + 设置 (服务/性能)
//  浅色主题
//

#import "MainTabBarController.h"
#import "Script/TSScriptListViewController.h"
#import "Settings/TSSettingsViewController.h"
#import "Common/TSPaths.h"
#import "Script/TSLuaBridge.h"

@implementation MainTabBarController

- (instancetype)init {
    self = [super init];
    if (self) {
        TSScriptListViewController *scripts = [[TSScriptListViewController alloc] init];
        UINavigationController *nav1 = [[UINavigationController alloc] initWithRootViewController:scripts];
        nav1.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"配置"
                                                       image:[UIImage systemImageNamed:@"doc.text"]
                                                         tag:0];

        TSSettingsViewController *settings = [[TSSettingsViewController alloc] init];
        UINavigationController *nav2 = [[UINavigationController alloc] initWithRootViewController:settings];
        nav2.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"设置"
                                                       image:[UIImage systemImageNamed:@"gearshape"]
                                                         tag:1];

        self.viewControllers = @[nav1, nav2];
        self.selectedIndex = 0;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // ── 浅色 TabBar ──
    if (@available(iOS 13.0, *)) {
        UITabBarAppearance *app = [[UITabBarAppearance alloc] init];
        [app configureWithOpaqueBackground];
        app.backgroundColor = [TSColors card];
        self.tabBar.standardAppearance = app;
        if (@available(iOS 15.0, *)) {
            self.tabBar.scrollEdgeAppearance = app;
        }
    }

    self.tabBar.barTintColor = [TSColors card];
    self.tabBar.tintColor    = [TSColors tint];
    self.tabBar.unselectedItemTintColor = [TSColors tertiaryLabel];

    // ── 浅色 NavigationBar ──
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *navApp = [[UINavigationBarAppearance alloc] init];
        [navApp configureWithOpaqueBackground];
        navApp.backgroundColor = [TSColors card];
        navApp.titleTextAttributes = @{NSForegroundColorAttributeName: [TSColors label]};
        navApp.shadowColor = [TSColors separator];

        [UINavigationBar appearance].standardAppearance = navApp;
        [UINavigationBar appearance].scrollEdgeAppearance = navApp;
    }

    // 接收脚本列表页"执行"通知，交给 Lua 引擎运行
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_handleRunScriptNotification:)
                                                 name:@"TSRunScript"
                                               object:nil];
}

- (void)_handleRunScriptNotification:(NSNotification *)note {
    NSString *path = note.userInfo[@"path"];
    if (!path.length) return;
    [[TSLuaBridge shared] runFile:path];
}

@end