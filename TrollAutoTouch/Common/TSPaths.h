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
/// 运行目录   /var/mobile/touch/runtime
/// 仅供"整包加密项目(.tas)"运行时存放一次性临时资源(图片/音频等非源码)。
/// 其中的 .lua 源码只驻内存、绝不写入该目录; 运行结束即整体删除, App 冷启动再兜底清空。
+ (NSString *)runtimeDir;

/// 确保所有目录存在（首次启动时创建）
+ (void)ensureDirectoriesExist;

/// 清空 runtime 目录下的全部内容(加密项目临时运行残留)。
/// 在 App 冷启动时调用, 防止异常退出/崩溃留下上次解密的临时资源, 同时清除旧版本遗留的明文。
+ (void)cleanupRuntimeDirectory;

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