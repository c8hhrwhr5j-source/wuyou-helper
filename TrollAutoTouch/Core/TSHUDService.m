//
//  TSHUDService.m — HUD 全局弹窗服务 (单 App 架构)
//
//  架构 (合并自旧版独立 HUDServices app):
//  - 弹窗完全在 TrollAutoTouch 进程内完成:
//      TSHUDService (入口, 保持 showAlertWithTitle: 接口不变)
//        └─> TSHUDHost (创建全屏透明窗口 + SBS 系统级托管)
//              └─> HUDCustomAlertView (自绘弹窗, 替代 UIAlertController)
//  - 不再有独立 HUDServices.app / CPDistributedMessagingCenter 跨进程消息 /
//    TrollStore 多 app tipa 安装。桌面只显示 TrollAutoTouch 一个图标。
//  - SBS 托管成功时弹窗显示在任意前台 app 之上; 托管失败时弹窗
//    仅在 TrollAutoTouch 位于前台时可见 (后台调用立即返回 nil, 不阻塞脚本)。

#import "TSHUDService.h"
#import "TSHUDHost.h"
#import <UIKit/UIKit.h>

@implementation TSHUDService

+ (instancetype)sharedInstance {
    static TSHUDService *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (void)warmUp {
    [[TSHUDHost shared] start];
}

- (nullable NSString *)showAlertWithTitle:(nullable NSString *)title
                                  message:(nullable NSString *)message
                                  buttons:(nullable NSArray<NSString *> *)buttons
                                  timeout:(NSTimeInterval)timeout {
    return [[TSHUDHost shared] presentAlertWithTitle:title
                                             message:message
                                             buttons:buttons
                                             timeout:timeout];
}

@end
