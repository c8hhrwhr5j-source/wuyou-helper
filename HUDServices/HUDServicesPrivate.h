//
//  HUDServicesPrivate.h
//  HUDServices
//
//  手动声明的私有框架接口 (SpringBoardServices / FrontBoard)。
//  通过 -Wl,-undefined,dynamic_lookup 在运行时动态解析, 无需实际链接私有框架。
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - CPDistributedMessagingCenter (AppSupport)

@interface CPDistributedMessagingCenter : NSObject

+ (instancetype)centerNamed:(NSString *)name;
- (void)runServerOnCurrentThread;
- (void)registerForMessageName:(NSString *)name target:(id)target selector:(SEL)selector;
- (void)sendMessageName:(NSString *)name userInfo:(NSDictionary *)userInfo;
- (NSDictionary *)sendMessageAndReceiveReplyName:(NSString *)name userInfo:(NSDictionary *)userInfo;
- (void)sendReplyForMessage:(NSString *)name userInfo:(NSDictionary *)userInfo;

@end

#pragma mark - FBSSystemService (FrontBoard)

@interface FBSSystemService : NSObject

- (void)openApplication:(NSString *)bundleIdentifier
            withOptions:(NSDictionary *)options
             clientPort:(mach_port_t)clientPort
             withResult:(void (^)(NSError *error))resultBlock;

@end

#pragma mark - SBSAccessibilityWindowHostingController (SpringBoardServices)
// iOS 15+ 系统级无障碍窗口托管：把本进程 UIWindow 的 CAContext 注册到
// SpringBoard 的 accessibility 窗口层，窗口可显示在所有前台 app 之上，
// 无需把本 app 激活到前台。需要 entitlement: com.apple.springboard.accessibility-window-hosting

@interface SBSAccessibilityWindowHostingController : NSObject

- (void)registerWindowWithContextID:(unsigned)contextId atLevel:(double)level;
- (void)unregisterWindowWithContextID:(unsigned)contextId;

@end

#pragma mark - CALayer 私有属性 (QuartzCore)

@interface CALayer (TSHUDPrivate)

// iOS 10+ 私有: 当前 layer 渲染到的 CAContext id (0 表示尚未绑定渲染上下文)
@property (nonatomic, readonly) unsigned int contextId;

@end

NS_ASSUME_NONNULL_END
