//
//  TSActivationViewController.h
//  TrollAutoTouch
//
//  卡密激活页面: 未激活时作为 rootViewController 展示。
//  激活成功后调用 onActivated 由 AppDelegate 切入主界面并启动服务。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSActivationViewController : UIViewController

/// 激活成功后回调 (主线程)
@property (nonatomic, copy, nullable) void (^onActivated)(void);

/// 进入页面时预置显示的错误/提示信息 (如启动校验失败原因)
@property (nonatomic, copy, nullable) NSString *initialMessage;

@end

NS_ASSUME_NONNULL_END
