//
//  TSScriptCipher.m
//  TrollAutoTouch
//
//  XXTEA (Tiny Encryption Algorithm 扩展版, Needham & Wheeler) + Base64。
//  密钥为内置固定 16 字节，与 TrollAutoScript 的 .tas 格式互不兼容，
//  但功能等价: 加密后脚本仍可运行，仅无法明文查看。
//
//  支持两种文件格式:
//    "TAS1" 魔数头 + base64(...)  —— 单个 .lua 脚本加密 (.tas)
//    "TAP1" 魔数头 + base64(...)  —— 整个项目文件夹打包成一个加密文件 (.tas, 整包加密)
//  两种都复用同一条 XXTEA 载荷封装, 只是魔数与载荷含义不同。
//

#import "TSScriptCipher.h"
#import <string.h>

// ────────────────────────── 魔数 / 密钥 ──────────────────────────
static const char kTASMagic[4] = { 'T', 'A', 'S', '1' };
static const char kTAPMagic[4] = { 'T', 'A', 'P', '1' };
// 16 字节固定密钥 ("TrollAutoTouchK" 恰好 15 字符 + \0 = 16 字节)
static const char kTASKey[16]  = "TrollAutoTouchK";

static const uint32_t kDelta = 0x9E3779B9;

// ────────────────────────── XXTEA ──────────────────────────
static void xxtea_encrypt(uint32_t *v, uint32_t n, const uint32_t key[4]) {
    if (n == 0) return;
    if (n == 1) { v[0] += key[0]; return; }
    // 标准 XXTEA: z 为末尾/上一轮结果, y 为下一字, 与下方 xxtea_decrypt 严格互逆。
    uint32_t z = v[n - 1];
    uint32_t sum = 0;
    uint32_t rounds = 6 + 52 / n;
    do {
        sum += kDelta;
        uint32_t e = (sum >> 2) & 3;
        for (uint32_t p = 0; p < n - 1; p++) {
            uint32_t y = v[p + 1];
            v[p] += (((z >> 5 ^ y << 2) + (y >> 3 ^ z << 4)) ^ ((sum ^ y) + (key[(p & 3) ^ e] ^ z)));
            z = v[p];
        }
        uint32_t y = v[0];
        // 关键: z 必须更新为新的末字, 供下一轮首个 MX 使用 (否则与解密不互逆)
        z = v[n - 1] += (((z >> 5 ^ y << 2) + (y >> 3 ^ z << 4)) ^ ((sum ^ y) + (key[((n - 1) & 3) ^ e] ^ z)));
    } while (--rounds);
}

static void xxtea_decrypt(uint32_t *v, uint32_t n, const uint32_t key[4]) {
    if (n == 0) return;
    if (n == 1) { v[0] -= key[0]; return; }
    uint32_t z = v[n - 1];
    uint32_t sum = 0;
    uint32_t rounds = 6 + 52 / n;
    uint32_t y = v[0];
    sum = rounds * kDelta;
    do {
        uint32_t e = (sum >> 2) & 3;
        for (uint32_t p = n - 1; p > 0; p--) {
            z = v[p - 1];
            v[p] -= (((z >> 5 ^ y << 2) + (y >> 3 ^ z << 4)) ^ ((sum ^ y) + (key[(p & 3) ^ e] ^ z)));
            y = v[p];
        }
        z = v[n - 1];
        v[0] -= (((z >> 5 ^ y << 2) + (y >> 3 ^ z << 4)) ^ ((sum ^ y) + (key[0 ^ e] ^ z)));
        // 关键: y 必须更新为新的 v[0], 供下一轮首个 MX 使用 (否则与加密不互逆)
        y = v[0];
        sum -= kDelta;
    } while (--rounds);
}

// ────────────────────────── 通用载荷封装 ──────────────────────────
// 载荷 = [明文长度: 4B 小端] + [原始数据] + [0 补齐到 4 的倍数]
// XXTEA 要求至少 8 字节 (n >= 2)，故不足时补足。
// 加密: 原始数据 → "魔数"+base64
static NSString *ts_xxteaEncodeData(NSData *plain, const char magic[4]) {
    if (!plain || plain.length == 0) return nil;
    NSUInteger len = plain.length;
    NSUInteger aligned = (len + 4 + 3) & ~(NSUInteger)3;
    if (aligned < 8) aligned = 8;

    NSMutableData *payload = [NSMutableData dataWithLength:aligned];
    uint8_t *p = payload.mutableBytes;
    uint32_t lenLE = (uint32_t)len;
    memcpy(p, &lenLE, 4);
    [plain getBytes:p + 4 length:len];

    uint32_t key[4];
    memcpy(key, kTASKey, sizeof(key));
    xxtea_encrypt((uint32_t *)p, (uint32_t)(aligned / 4), key);

    NSString *b64 = [payload base64EncodedStringWithOptions:0];
    NSString *magicStr = [[NSString alloc] initWithBytes:magic length:4 encoding:NSASCIIStringEncoding];
    return [magicStr stringByAppendingString:b64];
}

// 解密: "魔数"+base64 → 原始数据; 格式非法/密钥不匹配返回 nil
static NSData *ts_xxteaDecodeData(NSString *cipherText, const char magic[4]) {
    if (cipherText.length < 5) return nil;
    NSString *magicStr = [[NSString alloc] initWithBytes:magic length:4 encoding:NSASCIIStringEncoding];
    if (![cipherText hasPrefix:magicStr]) return nil;
    NSString *b64 = [cipherText substringFromIndex:4];

    NSData *payload = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (!payload || payload.length < 8 || payload.length % 4 != 0) return nil;

    NSMutableData *buf = [payload mutableCopy];
    uint32_t key[4];
    memcpy(key, kTASKey, sizeof(key));
    xxtea_decrypt((uint32_t *)buf.mutableBytes, (uint32_t)(buf.length / 4), key);

    // 解密后前 4 字节是明文长度，做越界校验
    const uint8_t *q = buf.bytes;
    uint32_t len = 0;
    memcpy(&len, q, 4);
    if ((NSUInteger)len > buf.length - 4) return nil;

    return [NSData dataWithBytes:q + 4 length:len];
}

// ────────────────────────── 实现 ──────────────────────────
@implementation TSScriptCipher

+ (BOOL)isEncryptedContent:(NSString *)content {
    if (content.length < 4) return NO;
    return [content hasPrefix:@"TAS1"];
}

+ (BOOL)isProjectPackageContent:(NSString *)content {
    if (content.length < 4) return NO;
    return [content hasPrefix:@"TAP1"];
}

+ (nullable NSString *)encryptScript:(NSString *)plainText {
    if (!plainText.length) return nil;
    NSData *utf8 = [plainText dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8) return nil;
    return ts_xxteaEncodeData(utf8, kTASMagic);
}

+ (nullable NSString *)decryptScript:(NSString *)cipherText {
    NSData *plain = ts_xxteaDecodeData(cipherText, kTASMagic);
    if (!plain) return nil;
    return [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding];
}

// 整包加密: 把项目目录打包得到的 zip 数据 → "TAP1"+base64(.tas 文件内容)
+ (nullable NSString *)encryptProjectData:(NSData *)projectZipData {
    if (!projectZipData || projectZipData.length == 0) return nil;
    return ts_xxteaEncodeData(projectZipData, kTAPMagic);
}

// 整包解密: ".tas 项目包内容" → zip 数据
+ (nullable NSData *)decryptProjectData:(NSString *)cipherText {
    return ts_xxteaDecodeData(cipherText, kTAPMagic);
}

@end
