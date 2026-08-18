//
//  TSAppManager.h — 应用管理模块
//
//  通过 SpringBoardServices / LSApplicationWorkspace 等私有框架
//  实现前台应用检测、安装/卸载、进程管理等能力。
//  依赖 TrollStore 权限（com.apple.springboard.* / com.apple.frontboard.*）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 应用信息
@interface TSAppInfo : NSObject
@property (nonatomic, copy)   NSString *bundleId;
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, copy)   NSString *version;
@property (nonatomic, copy)   NSString *bundlePath;    // .app 目录路径
@property (nonatomic, copy)   NSString *dataPath;       // 沙盒 Data 路径
@property (nonatomic, assign) pid_t    pid;              // 运行中进程 PID (0=未运行)
@property (nonatomic, copy, nullable) NSData *iconData;  // 图标 PNG
@end

/// 单例
@interface TSAppManager : NSObject
+ (instancetype)shared;

// ── 前台应用 ──────────────────────────────────────
- (pid_t)     frontPid;
- (nullable NSString *)frontBid;         // 如 "com.tencent.xin"

// ── 应用查询 ──────────────────────────────────────
- (BOOL)      isInstalled:(NSString *)bundleId;
- (BOOL)      isRunning:(NSString *)bundleId;
- (nullable TSAppInfo *)appInfo:(NSString *)bundleId;
- (NSArray<TSAppInfo *> *)installedApps; // 用户可见应用列表

// ── 应用管理 ──────────────────────────────────────
- (BOOL)      openApp:(NSString *)bundleId;
- (BOOL)      launchAppInBackground:(NSString *)bundleId; // 后台启动, 不抢前台
- (BOOL)      closeApp:(NSString *)bundleId;       // 杀死进程
- (BOOL)      uninstallApp:(NSString *)bundleId;
- (BOOL)      installIPA:(NSString *)ipaPath;

// ── 通用 ──────────────────────────────────────────
- (BOOL)      openURL:(NSString *)urlString;
- (BOOL)      inputText:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
