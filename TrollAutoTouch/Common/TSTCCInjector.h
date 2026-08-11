//
//  TSTCCInjector.h
//  运行时直接写入 TCC.db 并重启 tccd，强制授予所有隐私权限
//
#import <Foundation/Foundation.h>

@interface TSTCCInjector : NSObject

/// 授予所有常用隐私权限（摄像头/麦克风/相册/通讯录/日历/提醒/位置/蓝牙/语音等）
/// 写入 /var/mobile/Library/TCC/TCC.db 后 killall tccd 使其立即生效
+ (void)grantAllPermissions;

/// 授予指定 TCC 服务权限
+ (void)grantPermission:(NSString *)tccService;

@end
