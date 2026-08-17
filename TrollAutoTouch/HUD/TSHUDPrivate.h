//
//  TSHUDPrivate.h
//  TrollAutoTouch
//
//  HUD 全局弹窗服务所需的私有框架 API 声明。
//
//  说明:
//  - 这些类/函数来自 AppSupport / FrontBoardServices / SpringBoardServices 私有框架,
//    本工程 CLANG_ENABLE_MODULES=NO 且不引入私有框架头文件, 故手动声明。
//  - 链接时通过 OTHER_LDFLAGS 的 -Wl,-undefined,dynamic_lookup 在运行时由 dyld 解析
//    (与 TSInjectedTouchService 相同策略), 因此这里不需要 -framework 私有框架。
//  - 用法与系统行为参考 TrollAutoScript (原版 TrollAutoTouch 参考实现) 的 HUD 服务。
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>

NS_ASSUME_NONNULL_BEGIN

// ─────────────────────────────────────────────────────────────────────────────
// CPDistributedMessagingCenter (AppSupport)
// 进程间消息中心: 主 App 与 HUD 服务之间同步收发 alert 请求/结果。
// 消息名 + userInfo(plist 可序列化) 传输, sendMessageAndReceiveReplyName: 为同步阻塞调用,
// 正好满足 sys.alertButtons 需要"等待用户点击并拿到结果"的语义。
// ─────────────────────────────────────────────────────────────────────────────
@interface CPDistributedMessagingCenter : NSObject

// 创建/获取指定名称的消息中心(两端必须使用相同名称才能互通)
+ (instancetype)centerNamed:(NSString *)name;

// 服务端: 在当前线程 runloop 上开始接收消息
- (void)runServerOnCurrentThread;
// 服务端: 停止接收
- (void)stopServer;

// 服务端: 注册某个消息名的处理 target/selector
// selector 签名: - (void)handleMessage:(NSString *)name userInfo:(NSDictionary *)userInfo
// 若需同步回复, 用 -sendReplyForMessage:userInfo: 回传
- (void)registerForMessageName:(NSString *)name target:(id)target selector:(SEL)selector;
- (void)unregisterForMessageName:(NSString *)name;

// 客户端: 同步发送并等待服务端回复 (阻塞, 返回 replyUserInfo)
- (NSDictionary *)sendMessageAndReceiveReplyName:(NSString *)name userInfo:(NSDictionary *)userInfo;
- (NSDictionary *)sendMessageAndReceiveReplyName:(NSString *)name userInfo:(NSDictionary *)userInfo error:(NSError *__autoreleasing *)error;

// 服务端: 回复之前收到的消息 (用于同步回传结果)
- (void)sendReplyForMessage:(NSString *)name userInfo:(NSDictionary *)userInfo;

// 客户端: 单向发送(不等回复)
- (void)sendMessageName:(NSString *)name userInfo:(NSDictionary *)userInfo;

@end

// ─────────────────────────────────────────────────────────────────────────────
// FBSSystemService (FrontBoardServices)
// 系统服务: 用于把 HUD 服务进程激活到前台(让它的 UIWindow 显示在任意 app 之上),
// 以及启动/关闭后台 app。
// ─────────────────────────────────────────────────────────────────────────────
@interface FBSSystemService : NSObject

+ (instancetype)sharedService;

// 打开 app: bundleIdentifier 可以是 bundle id; 激活到前台
- (BOOL)openApplication:(NSString *)bundleIdentifier options:(nullable NSDictionary *)options clientPort:(mach_port_t)clientPort withResult:(nullable int *)result;

// 把当前进程的 app 拉到前台 (调用方 app)
- (void)activateFrontmostApp;

@end

// ─────────────────────────────────────────────────────────────────────────────
// LSApplicationWorkspace (MobileCoreServices / LaunchServices)
// 应用工作区: 查询已安装 app、启动 app。
// ─────────────────────────────────────────────────────────────────────────────
@interface LSApplicationWorkspace : NSObject

+ (instancetype)defaultWorkspace;

// 按 bundle id 启动 app (同步, 返回是否成功)
- (BOOL)openApplicationWithBundleID:(NSString *)bundleIdentifier;

// 已安装的所有 app 的 bundle id 集合 (用于判断 HUD 是否已安装/可启动)
- (NSArray *)allInstalledApplications;

@end

// 私有 C 函数: 按 bundle id 启动 app (SpringBoardServices), 与原版一致
FOUNDATION_EXPORT void _SBSLaunchApplicationWithIdentifier(NSString *identifier, NSDictionary *options, void (^completion)(BOOL success));

NS_ASSUME_NONNULL_END
