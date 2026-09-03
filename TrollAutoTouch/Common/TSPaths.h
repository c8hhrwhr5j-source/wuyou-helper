//
//  TSPaths.h
//  TrollAutoTouch
//
//  集中管理 app 使用的所有路径常量 + 主题色常量
//  路径为 /var/mobile/touch/{lua,log,res} —— TrollStore 应用稳定可写
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Paths

@interface TSPaths : NSObject

/// 根目录 /var/mobile/touch
+ (NSString *)rootDir;
/// lua 脚本目录 /var/mobile/touch/lua
+ (NSString *)luaDir;
/// 日志目录   /var/mobile/touch/log
+ (NSString *)logDir;
/// 资源目录   /var/mobile/touch/res
+ (NSString *)resDir;
/// 运行目录   /var/mobile/touch/runtime (加密项目(.tas)解密后的临时运行目录, 不列入脚本列表)
+ (NSString *)runtimeDir;

/// 确保所有目录存在（首次启动时创建）
+ (void)ensureDirectoriesExist;

/// 完整路径拼接
+ (NSString *)pathForLua:(NSString *)name;
+ (NSString *)pathForLog:(NSString *)name;
+ (NSString *)pathForRes:(NSString *)name;

@end

#pragma mark - Colors (Light Theme)

@interface TSColors : NSObject

@property (class, nonatomic, readonly) UIColor *bg;            // 主背景 #F2F2F7
@property (class, nonatomic, readonly) UIColor *card;          // 卡片/分组背景 #FFFFFF
@property (class, nonatomic, readonly) UIColor *separator;      // 分割线 #C6C6C8
@property (class, nonatomic, readonly) UIColor *label;          // 主文字 #1C1C1E
@property (class, nonatomic, readonly) UIColor *secondaryLabel; // 次要文字 #3C3C43
@property (class, nonatomic, readonly) UIColor *tertiaryLabel;  // 辅助文字 #8E8E93
@property (class, nonatomic, readonly) UIColor *tint;           // 主色调 (蓝色) #007AFF
@property (class, nonatomic, readonly) UIColor *switchOn;       // 开关 ON 颜色 #34C759
@property (class, nonatomic, readonly) UIColor *danger;         // 红色 #FF3B30
@property (class, nonatomic, readonly) UIColor *warning;        // 黄色 #FF9500
@property (class, nonatomic, readonly) UIColor *success;        // 绿色 #34C759
@property (class, nonatomic, readonly) UIColor *info;           // 蓝色 #007AFF

@end

NS_ASSUME_NONNULL_END