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

NS_ASSUME_NONNULL_END
