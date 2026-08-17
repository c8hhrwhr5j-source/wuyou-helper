//
//  HUDSystem.h
//  HUDServices
//
//  系统级操作封装: 启动/激活 app、获取前台 app bundle id。
//  通过 dlopen 动态加载 SpringBoardServices 私有框架。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HUDSystem : NSObject

/// 启动/激活指定 bundle id 的 app (会将其带到前台)
+ (BOOL)launchApplicationWithIdentifier:(NSString *)bundleIdentifier;

/// 获取当前前台 app 的 bundle id (失败返回 nil)
+ (nullable NSString *)frontmostApplicationIdentifier;

@end

NS_ASSUME_NONNULL_END
