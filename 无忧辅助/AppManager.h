//
//  AppManager.h
//  无忧辅助 - 应用管理（前台/启动/关闭/检测运行/包路径）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppManager : NSObject

+ (instancetype)sharedInstance;

/// 获取当前前台 App 的 Bundle ID
- (NSString *)frontBid;

/// 启动指定 Bundle ID 的应用
- (BOOL)runApp:(NSString *)bundleId;

/// 关闭指定 Bundle ID 的应用
- (BOOL)killApp:(NSString *)bundleId;

/// 检测指定应用是否正在运行
- (BOOL)isAppRunning:(NSString *)bundleId;

/// 获取指定应用的 Bundle 目录路径
- (NSString *)bundlePath:(NSString *)bundleId;

@end

NS_ASSUME_NONNULL_END
