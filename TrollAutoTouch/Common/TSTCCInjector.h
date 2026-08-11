//
//  TSTCCInjector.h
//  TrollAutoTouch
//
//  直接写入 /var/mobile/Library/TCC/TCC.db，零弹窗注册所有隐私权限。
//  巨魔应用 no-sandbox，可直写 mobile 用户拥有的 TCC 数据库。
//

#import <Foundation/Foundation.h>

@interface TSTCCInjector : NSObject

/// 直接向 TCC.db 批量插入 ALLOW 记录（零弹窗、零用户交互）
+ (void)injectAllPermissions;

@end
