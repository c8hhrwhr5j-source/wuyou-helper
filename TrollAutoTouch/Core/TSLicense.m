//
//  TSLicense.m
//  TrollAutoTouch
//
//  土豆 API 卡密验证实现 (verifyCardV2)。
//

#import "TSLicense.h"
#import "TSLicenseConfig.h"
#import "TSExpiryStore.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonCryptor.h>
#import <Security/Security.h>
#import <dlfcn.h>

static NSString *const kKeychainService = @"com.trollautotouch.license";
static NSString *const kKeychainAccountActivation = @"activation";   // 激活凭证 JSON
static NSString *const kKeychainAccountDevice = @"deviceId";         // 设备机器码
static NSString *const kKeychainAccountFingerprint = @"hwFingerprint"; // 激活时绑定的硬件指纹(md5)

// 硬件指纹混淆盐: 避免指纹直接可被识别为 hash(UDID)
static NSString *const kFingerprintSalt = @"trollautotouch.hw.v1";

@interface TSLicense ()
@property (nonatomic, assign) BOOL activated;
+ (void)bindHardwareFingerprint; // 私有类方法: 供激活/校验链路调用
@end

@implementation TSLicense

+ (instancetype)shared {
    static TSLicense *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TSLicense alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _activated = ([self _loadActivationRecord] != nil);
    }
    return self;
}

// MARK: - 对外接口

- (BOOL)isActivated {
    return _activated;
}

- (void)activateWithCard:(NSString *)card
              completion:(void (^)(BOOL ok, NSString *_Nullable msg))completion {
    [self _requestVerifyCard:card
                  completion:^(BOOL ok, BOOL networkError, NSString *msg, NSString *exTime) {
        if (ok) {
            NSDictionary *rec = @{
                @"card": card ?: @"",
                @"deviceId": [TSLicense deviceId],
                @"activatedAt": @([[NSDate date] timeIntervalSince1970]),
                @"exTime": exTime ?: @"",
            };
            [self _saveActivationRecord:rec];
            self->_activated = YES;
            // 绑定本机硬件指纹(UDID/序列号), 防 deviceId 被复制到其他设备共享卡密
            [TSLicense bindHardwareFingerprint];
            // 把服务器到期时间隐藏写入本地三份(防篡改冗余)
            if (exTime.length) {
                NSDate *d = [self _parseExTime:exTime];
                if (d) [TSExpiryStore writeExpiryTime:d];
            }
        }
        if (completion) completion(ok, msg);
    }];
}

- (NSString *)expireDateString {
    NSDictionary *rec = [self _loadActivationRecord];
    NSString *t = rec[@"exTime"];
    return ([t isKindOfClass:NSString.class] && t.length) ? t : nil;
}

- (void)deactivate {
    [self _deleteActivationRecord];
    [TSExpiryStore clearAll]; // 同时清除三份到期时间文件
    KeychainDelete(kKeychainService, kKeychainAccountFingerprint); // 清除硬件指纹
    _activated = NO;
}

// 已激活状态下的静默联网校验(每次启动 + 每6小时周期调用):
//   - 校验通过 → 若服务端返回到期时间则更新本地凭证并覆盖写入三份隐藏到期文件
//   - 服务端明确判定无效 → 清除激活, 由调用方转入试用流程
//   - 网络异常 → 校验本地三份隐藏到期文件: 三份一致且未到期放行;
//                 不一致判定非法设备锁定; 三份缺失(从未联网写入)放行
- (void)refreshValidWithCompletion:(void (^)(BOOL valid, BOOL networkError, NSString *_Nullable msg))completion {
    NSDictionary *rec = [self _loadActivationRecord];
    if (!rec || ![rec[@"card"] length]) {
        if (completion) completion(NO, NO, @"未激活");
        return;
    }
    // 硬件指纹校验(本地): 本机 UDID/序列号与激活时绑定值不一致 → 判定 deviceId 被复制, 锁定
    if (![TSLicense isHardwareMatch]) {
        [self deactivate];
        if (completion) completion(NO, NO, @"设备硬件指纹校验异常，已锁定");
        return;
    }
    [self _requestVerifyCard:rec[@"card"]
                  completion:^(BOOL ok, BOOL networkError, NSString *msg, NSString *exTime) {
        if (ok) {
            // 校验通过: 同步服务端最新到期时间, 避免本地凭证过期不更新
            [TSLicense bindHardwareFingerprint]; // 兼容: 老版本激活未绑指纹, 校验通过后自动补绑
            if (exTime.length) {
                NSDate *d = [self _parseExTime:exTime];
                if (d) {
                    NSMutableDictionary *m = [rec mutableCopy];
                    m[@"exTime"] = exTime;
                    [self _saveActivationRecord:m];
                    // 覆盖写入三份隐藏到期时间文件
                    [TSExpiryStore writeExpiryTime:d];
                }
            }
            if (completion) completion(YES, NO, nil);
            return;
        }
        if (networkError) {
            // 验证不了(网络失败): 校验本地三份到期时间文件
            BOOL tampered = NO;
            NSDate *localExpiry = [TSExpiryStore readVerifiedExpiry:&tampered];
            if (tampered) {
                // 三份时间对不上 → 判定非法设备
                [TSExpiryStore clearAll];
                [self deactivate];
                if (completion) completion(NO, NO, @"设备到期文件校验异常，已锁定");
                return;
            }
            if (localExpiry) {
                if ([localExpiry timeIntervalSinceNow] > 0) {
                    // 三份一致且未到期 → 放行
                    if (completion) completion(NO, YES, nil);
                    return;
                }
                // 三份一致但已到期 → 判定到期
                [TSExpiryStore clearAll];
                [self deactivate];
                if (completion) completion(NO, NO, @"卡密已到期");
                return;
            }
            // 三份文件缺失(从未成功联网写入): 保持激活放行, 不误杀首次使用设备
            if (completion) completion(NO, YES, msg);
            return;
        }
        // 服务端明确返回校验不通过: 卡密被删/禁用/到期/机器码不匹配 → 清除本地激活
        [self deactivate];
        if (completion) completion(NO, NO, msg ?: @"卡密校验失败");
    }];
}

// 解析服务端到期时间字符串 -> NSDate; 解析失败返回 nil(调用方不写三份, 保留旧值)
- (NSDate *)_parseExTime:(NSString *)s {
    if (!s.length) return nil;
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSDate *d = [fmt dateFromString:s];
    if (!d) {
        fmt.dateFormat = @"yyyy-MM-dd";
        d = [fmt dateFromString:s];
    }
    return d;
}

// MARK: - 土豆 API 请求

- (void)_requestVerifyCard:(NSString *)card
                completion:(void (^)(BOOL ok, BOOL networkError, NSString *_Nullable msg, NSString *_Nullable exTime))completion {
    if (card.length == 0) {
        if (completion) completion(NO, NO, @"卡密为空", nil);
        return;
    }

    NSData *encKey = [kTSLicenseEncryptSecret dataUsingEncoding:NSUTF8StringEncoding];
    NSString *mac = [TSLicense deviceId];

    // V3 签名基于原始参数 (SDK 的 signV3 传入的是 data, 不是加密后的 encryptedJson)
    NSDictionary *raw = @{@"cardStr": card, @"mac": mac};
    NSString *time = [NSString stringWithFormat:@"%lld",
                      (long long)([[NSDate date] timeIntervalSince1970] * 1000.0)];
    NSString *nonce = [TSLicense randomAlnum:32];
    NSString *sign = [TSLicense signV3WithParams:raw time:time nonce:nonce
                                          secret:kTSLicenseSignSecret];

    // 半加密: 只加密 value, key 保持明文
    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithCapacity:raw.count];
    for (NSString *k in raw) {
        NSData *plain = [raw[k] dataUsingEncoding:NSUTF8StringEncoding];
        NSData *cipher = [TSLicense aesEncryptECBNoPadding:plain key:encKey];
        body[k] = cipher ? [cipher base64EncodedStringWithOptions:0] : @"";
    }

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/verifyCardV2",
                                       kTSLicenseHost]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 15;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:kTSLicenseAskKey forHTTPHeaderField:@"askKey"];
    [req setValue:time forHTTPHeaderField:@"time"];
    [req setValue:nonce forHTTPHeaderField:@"nonce"];
    [req setValue:sign forHTTPHeaderField:@"sign"];
    // 土豆 API 要求除登录/注册外所有接口 header 都携带 apiUserToken; 卡密验证场景无用户 token, 传空字符串
    [req setValue:@"" forHTTPHeaderField:@"apiUserToken"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];

    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task =
        [session dataTaskWithRequest:req
                   completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) {
            NSString *msg = [NSString stringWithFormat:@"网络错误(%ld): %@",
                             (long)error.code, error.localizedDescription];
            if (completion) completion(NO, YES, msg, nil);
            return;
        }
        NSInteger statusCode = [(NSHTTPURLResponse *)resp statusCode];
        // 响应内容为全加密 Base64 (服务端出错时可能返回明文, 这里都打印出来便于诊断)
        NSString *bodyStr = [[NSString alloc] initWithData:data
                                                  encoding:NSUTF8StringEncoding];
        bodyStr = [bodyStr stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSData *cipher = [[NSData alloc] initWithBase64EncodedString:bodyStr options:0];
        NSData *plain = [TSLicense aesDecryptECBNoPadding:cipher key:encKey];
        NSString *jsonStr = plain ?
            [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding] : nil;
        // 兼容服务端实际未加密响应(后台配置未生效时): 解密失败则尝试按明文 JSON 解析
        if (!jsonStr.length && bodyStr.length) {
            jsonStr = bodyStr;
        }
        jsonStr = [jsonStr stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        NSDictionary *obj = nil;
        if (jsonStr.length) {
            NSData *jd = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
            obj = [NSJSONSerialization JSONObjectWithData:jd options:0 error:NULL];
        }
        NSString *code = [obj[@"code"] description];
        NSDictionary *dataObj = [obj isKindOfClass:NSDictionary.class] ? obj[@"data"] : nil;
        BOOL verifyOk = [code isEqualToString:@"200"] && [dataObj[@"verify"] boolValue];

        // 卡密到期时间(土豆返回 exTime, 格式 "2025-07-11 15:04:07")
        // 兼容不同后台的字段名; "0000-00-00 ..." / 空串视为"无到期时间"
        NSString *exTime = nil;
        if ([dataObj isKindOfClass:NSDictionary.class]) {
            NSArray<NSString *> *keys = @[@"exTime", @"expireTime", @"expiryTime",
                                          @"endTime", @"expireDate", @"validTime"];
            for (NSString *k in keys) {
                id t = dataObj[k];
                NSString *s = nil;
                if ([t isKindOfClass:NSString.class]) {
                    s = [t stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                } else if ([t isKindOfClass:NSNumber.class]) {
                    s = [t stringValue];
                }
                if (s.length && ![s hasPrefix:@"0000"]) { exTime = s; break; }
            }
        }

        if (verifyOk) {
            if (completion) completion(YES, NO, @"验证通过", exTime);
            return;
        }

        // 失败时把原始响应带出来便于排查
        NSString *rawPreview = bodyStr.length > 500 ?
            [bodyStr substringToIndex:500] : bodyStr;
        if (statusCode != 200) {
            NSString *msg = [NSString stringWithFormat:@"HTTP %ld: %@", (long)statusCode, rawPreview];
            if (completion) completion(NO, NO, msg, nil);
            return;
        }
        NSString *msg = nil;
        if ([obj[@"message"] isKindOfClass:NSString.class] && [obj[@"message"] length]) {
            msg = obj[@"message"];
        } else if (code.length) {
            msg = [NSString stringWithFormat:@"验证失败(code=%@)", code];
        } else {
            msg = [NSString stringWithFormat:@"响应解析失败, raw=%@, dec=%@",
                   rawPreview, jsonStr ?: @"(nil)"];
        }
        if (completion) completion(NO, NO, msg, nil);
    }];
    [task resume];
}

// MARK: - V3 签名 & AES

/// 土豆验签 V3: 过滤空值 → 键升序 → &k=v 拼接 → 追加 &验签秘钥&time&nonce → MD5(hex 小写)
+ (NSString *)signV3WithParams:(NSDictionary *)params
                          time:(NSString *)time
                         nonce:(NSString *)nonce
                        secret:(NSString *)secret {
    NSMutableArray *keys = [NSMutableArray array];
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    [params enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSString *v = [self _stringifyParam:obj];
        if (v.length == 0) return; // 空值过滤
        [keys addObject:key];
        values[key] = v;
    }];
    [keys sortUsingSelector:@selector(compare:)];

    NSMutableString *str = [NSMutableString string];
    for (NSString *k in keys) {
        [str appendFormat:@"&%@=%@", k, values[k]];
    }
    [str appendFormat:@"&%@", secret];
    [str appendFormat:@"&%@", time];
    [str appendFormat:@"&%@", nonce];
    return [self md5Hex:str];
}

+ (NSString *)_stringifyParam:(id)obj {
    if ([obj isKindOfClass:NSString.class]) return obj;
    if ([obj isKindOfClass:NSNumber.class]) return [obj stringValue];
    if ([obj isKindOfClass:NSArray.class] || [obj isKindOfClass:NSDictionary.class]) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
        if (d) return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    }
    return [obj description];
}

/// AES-128 ECB NoPadding 加密。明文补齐: padLen = 16 - len%16 (len 恰为 16 倍数时补一整块 16 个 \0)
+ (NSData *)aesEncryptECBNoPadding:(NSData *)plain key:(NSData *)key {
    if (!plain.length || key.length != kCCKeySizeAES128) return nil;
    NSUInteger len = plain.length;
    NSUInteger padLen = 16 - (len % 16);
    NSMutableData *padded = [plain mutableCopy];
    uint8_t zeros[16] = {0};
    [padded appendBytes:zeros length:padLen];

    NSMutableData *out = [NSMutableData dataWithLength:padded.length + 16];
    size_t outLen = 0;
    CCCryptorStatus st = CCCrypt(kCCEncrypt,
                                 kCCAlgorithmAES,
                                 kCCOptionECBMode,
                                 key.bytes, kCCKeySizeAES128,
                                 NULL,
                                 padded.bytes, padded.length,
                                 out.mutableBytes, out.length,
                                 &outLen);
    if (st != kCCSuccess) return nil;
    out.length = outLen;
    return out;
}

/// AES-128 ECB NoPadding 解密后去除尾部 \0
+ (NSData *)aesDecryptECBNoPadding:(NSData *)cipher key:(NSData *)key {
    if (!cipher.length || key.length != kCCKeySizeAES128) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:cipher.length + 16];
    size_t outLen = 0;
    CCCryptorStatus st = CCCrypt(kCCDecrypt,
                                 kCCAlgorithmAES,
                                 kCCOptionECBMode,
                                 key.bytes, kCCKeySizeAES128,
                                 NULL,
                                 cipher.bytes, cipher.length,
                                 out.mutableBytes, out.length,
                                 &outLen);
    if (st != kCCSuccess) return nil;
    const uint8_t *b = out.bytes;
    NSUInteger i = outLen;
    while (i > 0 && b[i - 1] == 0) i--;
    return [out subdataWithRange:NSMakeRange(0, i)];
}

+ (NSString *)md5Hex:(NSString *)str {
    const char *cStr = [str UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);
    NSMutableString *s = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [s appendFormat:@"%02x", digest[i]];
    }
    return s;
}

+ (NSString *)randomAlnum:(NSUInteger)len {
    static const char alnum[] =
        "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    NSMutableString *s = [NSMutableString stringWithCapacity:len];
    for (NSUInteger i = 0; i < len; i++) {
        [s appendFormat:@"%c", alnum[arc4random_uniform((uint32_t)(sizeof(alnum) - 1))]];
    }
    return s;
}

// MARK: - 设备机器码

+ (NSString *)deviceId {
    NSData *d = KeychainData(kKeychainService, kKeychainAccountDevice);
    if (d.length) {
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (s.length) return s;
    }
    NSString *vid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    NSString *did = vid ? [NSString stringWithFormat:@"TAT-%@", vid]
                        : [NSString stringWithFormat:@"TAT-%@", [NSUUID UUID].UUIDString];
    KeychainSave(kKeychainService, kKeychainAccountDevice,
                 [did dataUsingEncoding:NSUTF8StringEncoding]);
    return did;
}

// MARK: - 硬件指纹 (防设备号复制共享)

typedef CFTypeRef (*MGCopyAnswerFunc)(CFStringRef key);

// 动态调用 MobileGestalt 私有 API(MGCopyAnswer), 需 no-sandbox + platform-application entitlement;
// 库或符号不可用时返回 nil, 调用方按"读不到硬件标识"降级放行, 避免误伤
static NSString *MGAnswerString(NSString *key) {
    static MGCopyAnswerFunc func = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
        if (handle) {
            func = (MGCopyAnswerFunc)dlsym(handle, "MGCopyAnswer");
        }
    });
    if (!func) return nil;
    CFTypeRef value = func((__bridge CFStringRef)key);
    if (!value) return nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        return (__bridge_transfer NSString *)value; // Copy 约定: 转移所有权交由 ARC 释放
    }
    CFRelease(value);
    return nil;
}

// 本机硬件标识: UDID 优先(与硬件绑定, 重装/删 App 不重置), 序列号兜底
+ (NSString *)hardwareIdentifier {
    NSString *udid = MGAnswerString(@"UniqueDeviceID");
    if (udid.length) return udid;
    return MGAnswerString(@"SerialNumber");
}

// 激活时把当前硬件标识的 md5 写入 keychain(与 deviceId 分开存, 复制 keychain 也带不走本机硬件标识)
+ (void)bindHardwareFingerprint {
    NSString *hw = [self hardwareIdentifier];
    if (!hw.length) return; // 读不到硬件(非 no-sandbox 等)保持"未绑定"状态, 校验时放行
    NSString *fp = [self md5Hex:[NSString stringWithFormat:@"%@|%@", hw, kFingerprintSalt]];
    KeychainSave(kKeychainService, kKeychainAccountFingerprint,
                 [fp dataUsingEncoding:NSUTF8StringEncoding]);
}

+ (BOOL)isHardwareMatch {
    NSData *d = KeychainData(kKeychainService, kKeychainAccountFingerprint);
    if (!d.length) return YES; // 从未绑定(老版本/读不到硬件) → 放行
    NSString *stored = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!stored.length) return YES;
    NSString *hw = [self hardwareIdentifier];
    if (!hw.length) return YES; // 当前读不到硬件 → 降级放行(不误伤)
    NSString *cur = [self md5Hex:[NSString stringWithFormat:@"%@|%@", hw, kFingerprintSalt]];
    return [cur isEqualToString:stored];
}

// MARK: - keychain

static NSData *KeychainData(NSString *service, NSString *account) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (st == errSecSuccess && result) {
        return (__bridge_transfer NSData *)result;
    }
    return nil;
}

static BOOL KeychainSave(NSString *service, NSString *account, NSData *data) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
    NSDictionary *attrs = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecValueData: data,
    };
    OSStatus st = SecItemAdd((__bridge CFDictionaryRef)attrs, NULL);
    return st == errSecSuccess;
}

static BOOL KeychainDelete(NSString *service, NSString *account) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
    };
    OSStatus st = SecItemDelete((__bridge CFDictionaryRef)query);
    return st == errSecSuccess || st == errSecItemNotFound;
}

// MARK: - 激活凭证存取

- (NSDictionary *)_loadActivationRecord {
    NSData *data = KeychainData(kKeychainService, kKeychainAccountActivation);
    if (!data.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

- (void)_saveActivationRecord:(NSDictionary *)rec {
    NSData *data = [NSJSONSerialization dataWithJSONObject:rec options:0 error:NULL];
    if (data) KeychainSave(kKeychainService, kKeychainAccountActivation, data);
}

- (void)_deleteActivationRecord {
    KeychainDelete(kKeychainService, kKeychainAccountActivation);
}

@end
