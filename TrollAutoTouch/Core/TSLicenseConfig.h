//
//  TSLicenseConfig.h
//  TrollAutoTouch
//
//  土豆 API (potatocloud.cn) 卡密验证配置
//  =====================================================
//  使用前必须填写下面 3 个值，否则 App 无法激活:
//    1. askKey           —— 土豆后台 APP 控制台查看
//    2. 验签秘钥          —— 土豆后台"验签秘钥"框里设置的值 (V3 验签)
//    3. 加密秘钥          —— 土豆后台"加解密秘钥"框里设置的值
//                           (必须 16 字节 ASCII, 对应 AES-128)
//  ⚠️ 这些密钥会编译进 App, 公开仓库下会被他人看到。
// =====================================================
//

#ifndef TSLicenseConfig_h
#define TSLicenseConfig_h

/// 土豆 API 网关地址
#define kTSLicenseHost          @"https://api.potatocloud.cn"

/// askKey: 土豆后台 APP 控制台的令牌
#define kTSLicenseAskKey        @"YOUR_ASK_KEY"

/// 验签秘钥 (V3 签名用, 后台"验签秘钥"框)
#define kTSLicenseSignSecret    @"YOUR_SIGN_SECRET"

/// 加解密秘钥 (AES-128, 必须 16 字节, 后台"加解密秘钥"框)
#define kTSLicenseEncryptSecret @"YOUR_ENCRYPT_SECRET"

/// 断网时允许离线使用的宽限天数 (用户选择了"每次启动联网校验+宽限")
#define kTSLicenseGracePeriodDays 3

#endif /* TSLicenseConfig_h */
