//
//  main.m — HUD 隐藏服务入口
//  TrollAutoTouch
//
//  用途: 独立隐藏 app, 由主 App 通过 MobileInstallation 安装并启动。
//  通过 CPDistributedMessagingCenter 接收 sys.alert / sys.alertButtons 请求,
//  在任意前台 app 之上用高 windowLevel 的 UIWindow 弹出系统风格对话框。
//

#import <UIKit/UIKit.h>
#import "HUDAppDelegate.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([HUDAppDelegate class]));
    }
}
