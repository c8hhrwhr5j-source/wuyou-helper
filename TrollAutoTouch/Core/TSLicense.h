//
//  TSLicense.h
//  TrollAutoTouch
//
//  卡密激活 / 许可证校验模块。
//  对接土豆 API (potatocloud.cn) /api/verifyCardV2:
//    - 验签 V3:  MD5(&k=v&...&验签秘钥&time&nonce)
//    - 请求加密: 半加密(只加密 value), AES-128 ECB NoPadding, 明文补 \0 到 16 字节倍数
//    - 响应加密: 全加密 Base64 → AES-128 ECB NoPadding → 去 \0 → JSON
//  激活凭证存 keychain, 卸载重装(同 bundle id)保留。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSLicense : NSObject

+ (instancetype)shared;

/// 本地是否有激活凭证
@property (nonatomic, readonly) BOOL isActivated;

/// 激活卡密的到期时间字符串(土豆 exTime, 如 "2025-07-11 15:04:07"); 未激活或未知返回 nil
@property (nonatomic, readonly, nullable) NSString *expireDateString;

/// 激活卡密: 联网验证通过后持久化到 keychain
- (void)activateWithCard:(NSString *)card
              completion:(void (^)(BOOL ok, NSString *_Nullable msg))completion;

/// 已激活状态下与服务器校验卡密是否仍可用(启动时静默调用):
///   valid=YES  → 有效, 若服务端返回新到期时间则同步更新本地凭证
///   networkError=YES → 网络异常, 保持激活状态离线放行(不误杀)
///   两者皆 NO → 服务端明确判定卡密无效(被删/禁用/到期/机器码不匹配), 已清除本地激活
- (void)refreshValidWithCompletion:(void (^)(BOOL valid, BOOL networkError, NSString *_Nullable msg))completion;

/// 清除本地激活凭证
- (void)deactivate;

/// 设备机器码 (keychain 持久 UUID, 供土豆 mac 参数做设备绑定)
+ (NSString *)deviceId;

@end

NS_ASSUME_NONNULL_END
