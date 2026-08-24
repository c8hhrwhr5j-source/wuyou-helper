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
#define kTSLicenseAskKey        @"eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJhcHBJZCI6MTI1MTQ5MzIyOTE5Mzk0MDk5MiwiZ2V0TWFuYWdlbWVudElkIjoxMTY4Nzc0NDM4NjgxMzk5Mjk2LCJUSU1FIjoxNzg3NDkxMzE0NzIzfQ.t6NYBOkdrthwPEcz-9HpaSG3MjXizDZSphvWC4ALUSM"

/// 验签秘钥 (V3 签名用, 后台"验签秘钥"框)
#define kTSLicenseSignSecret    @"aB3#kL9$mN2pQ7wX"

/// 加解密秘钥 (AES-128, 必须 16 字节, 后台"加解密秘钥"框)
#define kTSLicenseEncryptSecret @"aB3#kL9$mN2pQ7wX"

#endif /* TSLicenseConfig_h */
