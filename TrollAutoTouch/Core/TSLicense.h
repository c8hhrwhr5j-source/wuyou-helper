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

/// 激活卡密: 联网验证通过后持久化到 keychain
- (void)activateWithCard:(NSString *)card
              completion:(void (^)(BOOL ok, NSString *_Nullable msg))completion;

/// 启动时联网校验; 网络失败且处于宽限期仍放行, 校验不通过会清除激活状态
- (void)startupCheckWithCompletion:(void (^)(BOOL ok, NSString *_Nullable msg))completion;

/// 清除本地激活凭证
- (void)deactivate;

/// 设备机器码 (keychain 持久 UUID, 供土豆 mac 参数做设备绑定)
+ (NSString *)deviceId;

@end

NS_ASSUME_NONNULL_END
