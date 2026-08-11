//
//  TSTCCRequestor.h
//  TrollAutoTouch
//
//  批量触发所有隐私服务权限请求，以填充 iOS Settings 的「隐私」列表。
//  仅在首次启动时执行一次，避免反复弹窗。
//

#import <Foundation/Foundation.h>

@interface TSTCCRequestor : NSObject

/// 执行所有 TCC 隐私服务请求（有延迟间隔，避免弹窗叠加）
+ (void)requestAllPermissionsIfNeeded;

@end
