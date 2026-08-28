//
//  TSPushKeepAlive.m
//  TrollAutoTouch
//
//  实现: PushKit VoIP 注册保活。
//  iOS 13+ 系统保证注册 PushKit VoIP 的应用持续在线(不被挂起), 以获得来电推送。
//  TrollStore 应用无需真实推送服务, 注册成功即获得豁免。
//  iOS 16.6 实测: 仅靠静音音频后台保活在游戏抢占 audio session 时会失效
//  (约 10 秒被挂起并遭 Jetsam 回收), PushKit VoIP 提供独立于音频的豁免。
//

#import "TSPushKeepAlive.h"
#import "TSLogStore.h"
#import <PushKit/PushKit.h>

@interface TSPushKeepAlive () <PKPushRegistryDelegate>
@property (nonatomic, strong) PKPushRegistry *registry;
@property (nonatomic, assign) BOOL started;
@end

@implementation TSPushKeepAlive

+ (instancetype)shared {
    static TSPushKeepAlive *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [TSPushKeepAlive new];
    });
    return inst;
}

- (void)start {
    if (_started) return;
    _started = YES;
    _registry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
    _registry.delegate = self;
    _registry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
    NSLog(@"[PushKeepAlive] PushKit VoIP 注册中...");
    [self log:@"PushKit VoIP 注册中..."];
}

- (void)stop {
    _started = NO;
    _registry = nil;
}

- (BOOL)isRegistered {
    NSData *token = _registry.pushTokenForType[PKPushTypeVoIP];
    return token.length > 0;
}

#pragma mark - PKPushRegistryDelegate

- (void)pushRegistry:(PKPushRegistry *)registry
    didUpdatePushCredentials:(PKPushCredentials *)credentials
                     forType:(PKPushType)type {
    NSLog(@"[PushKeepAlive] PushKit VoIP 注册成功(已获得后台豁免)");
    [self log:@"PushKit VoIP 注册成功, 后台豁免已生效"];
}

- (void)pushRegistry:(PKPushRegistry *)registry
    didReceiveIncomingPushWithPayload:(PKPushPayload *)payload
                              forType:(PKPushType)type
                withCompletionHandler:(void (^)(void))completion {
    if (completion) completion();
}

- (void)pushRegistry:(PKPushRegistry *)registry
    didInvalidatePushTokenForType:(PKPushType)type {
    NSLog(@"[PushKeepAlive] PushKit VoIP token 失效");
    [self log:@"PushKit VoIP token 失效"];
}

#pragma mark - 日志

- (void)log:(NSString *)msg {
    [[TSLogStore shared] append:[NSString stringWithFormat:@"[保活] %@", msg]];
}

@end
