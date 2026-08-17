//
//  HUDAppDelegate.h
//  HUDServices
//
//  HUD 隐藏服务的应用代理: 负责注册 CPDistributedMessagingCenter、
//  维护全屏透明窗口, 并处理来自主 App 的全局弹窗请求。
//

#import <UIKit/UIKit.h>

@interface HUDAppDelegate : UIResponder <UIApplicationDelegate>

@property (nonatomic, strong) UIWindow *window;

@end
