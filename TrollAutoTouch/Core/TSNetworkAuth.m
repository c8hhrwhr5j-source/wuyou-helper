//
//  TSNetworkAuth.m
//  TrollAutoTouch
//
//  NEHotspotHelper 注册 —— 原版 TrollAutoScript 2.3.6 的保活关键之一。
//
//  静态证据(逆向原版二进制):
//    - 调用了 registerWithOptions:queue:handler: (NEHotspotHelper 注册方法)
//    - 二进制含 NEHotspotHelperCommand / Authenticate / Evaluate 等符号
//    - entitlements 含 com.apple.developer.networking.HotspotHelper、
//      com.apple.wifi.manager-access、com.apple.wlan.authentication
//
//  原理: 注册 NEHotspotHelper 后, 系统把 app 标记为"Wi-Fi 热点认证助手",
//  属于 network-authentication 应用 —— 这正是 UIBackgroundModes 中
//  network-authentication 模式的判定依据, 授予后台持续执行豁免。
//

#import "TSNetworkAuth.h"
#import "TSLogStore.h"
// 必须用 umbrella 头文件: NEHotspotHelper.h 拒绝被直接 #import,
// 且构建禁用了 Clang modules(@import 不可用)。
#import <NetworkExtension/NetworkExtension.h>

static BOOL gRegistered = NO;

@implementation TSNetworkAuth

+ (BOOL)registerHotspotHelper {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *options = @{
            kNEHotspotHelperOptionDisplayName: @"TrollAutoTouch",
        };
        gRegistered = [NEHotspotHelper registerWithOptions:options
                                                     queue:dispatch_get_main_queue()
                                                   handler:^(NEHotspotHelperCommand *cmd) {
            // 对齐原版: 注册后响应系统下发的热点命令。
            // FilterScanList / FilterNetworkList 返回空网络列表(不干预用户选择热点),
            // 其余命令(Evaluate/Authenticate/PresentUI/Maintain/Logoff)保持注册状态即可。
            switch (cmd.commandType) {
                case kNEHotspotHelperCommandTypeFilterScanList:
                case kNEHotspotHelperCommandTypeFilterNetworkList: {
                    NEHotspotHelperResponse *resp = [cmd createResponse:kNEHotspotHelperResultSuccess];
                    [NEHotspotHelper setResponse:resp];
                    break;
                }
                default:
                    break;
            }
        }];
        [[TSLogStore shared] append:[NSString stringWithFormat:
                                     @"[认证保活] NEHotspotHelper 注册: %@",
                                     gRegistered ? @"成功" : @"失败"]];
    });
    return gRegistered;
}

+ (BOOL)isRegistered {
    return gRegistered;
}

@end
