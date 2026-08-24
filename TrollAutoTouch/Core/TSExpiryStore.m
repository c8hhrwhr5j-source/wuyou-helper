//
//  TSExpiryStore.m
//  TrollAutoTouch
//
//  三份隐藏存储 + 混淆实现。
//

#import "TSExpiryStore.h"
#import <UIKit/UIKit.h>
#import <math.h>
#import <string.h>

/// 混淆密钥(轻量防明文, 防止直接改时间戳绕过)
static NSString *const kTSExpiryObfuscKey = @"ta_exp@7f3a#2c9e";

static NSString *Encode(NSString *s) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (!d.length) return @"";
    const char *key = kTSExpiryObfuscKey.UTF8String;
    NSUInteger keyLen = strlen(key);
    NSMutableData *out = [NSMutableData dataWithLength:d.length];
    const uint8_t *src = d.bytes;
    uint8_t *dst = out.mutableBytes;
    for (NSUInteger i = 0; i < d.length; i++) dst[i] = src[i] ^ key[i % keyLen];
    return [out base64EncodedStringWithOptions:0];
}

static NSString *Decode(NSString *s) {
    NSData *d = [[NSData alloc] initWithBase64EncodedString:s options:0];
    if (!d.length) return nil;
    const char *key = kTSExpiryObfuscKey.UTF8String;
    NSUInteger keyLen = strlen(key);
    NSMutableData *out = [NSMutableData dataWithLength:d.length];
    const uint8_t *src = d.bytes;
    uint8_t *dst = out.mutableBytes;
    for (NSUInteger i = 0; i < d.length; i++) dst[i] = src[i] ^ key[i % keyLen];
    return [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
}

/// 三个存储位置: Documents / Application Support / Preferences, 均用隐藏伪装名
static NSArray<NSString *> *ExpiryPaths(void) {
    NSArray<NSString *> *docs =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = docs.firstObject;
    NSString *sandbox = [doc stringByDeletingLastPathComponent];
    NSString *lib = [sandbox stringByAppendingPathComponent:@"Library"];
    NSString *support = [lib stringByAppendingPathComponent:@"Application Support"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:support]) {
        [fm createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    return @[
        [doc stringByAppendingPathComponent:@".ts_exp_7f3a2c"],
        [support stringByAppendingPathComponent:@".ts_exp_9e1b4d"],
        [lib stringByAppendingPathComponent:@"Preferences/.ts_exp_5c7d9e"],
    ];
}

@implementation TSExpiryStore

+ (void)writeExpiryTime:(NSDate *)expiry {
    if (!expiry) {
        [self clearAll];
        return;
    }
    NSString *payload = [NSString stringWithFormat:@"%.0f", [expiry timeIntervalSince1970]];
    NSString *enc = Encode(payload);
    if (!enc.length) return;
    for (NSString *p in ExpiryPaths()) {
        [enc writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
}

+ (NSDate *)readVerifiedExpiry:(BOOL *)tampered {
    if (tampered) *tampered = NO;

    NSArray<NSString *> *paths = ExpiryPaths();
    NSFileManager *fm = [NSFileManager defaultManager];
    double first = 0;
    BOOL hasFirst = NO;
    BOOL allExist = YES;

    for (NSString *p in paths) {
        if (![fm fileExistsAtPath:p]) { allExist = NO; continue; }
        NSString *content =
            [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
        NSString *decoded = Decode(content ?: @"");
        double ts = [decoded doubleValue];
        if (ts <= 0) {
            // 内容解析不出合法时间戳 → 视为被篡改
            if (tampered) *tampered = YES;
            return nil;
        }
        if (!hasFirst) {
            first = ts;
            hasFirst = YES;
        } else if (fabs(ts - first) > 0.5) {
            // 三份时间对不上 → 判定非法设备
            if (tampered) *tampered = YES;
            return nil;
        }
    }

    if (!hasFirst) return nil;      // 全缺失: 从未成功写入, 无数据可校验
    if (!allExist) {                // 部分缺失 → 视为篡改
        if (tampered) *tampered = YES;
        return nil;
    }
    return [NSDate dateWithTimeIntervalSince1970:first];
}

+ (void)clearAll {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in ExpiryPaths()) {
        if ([fm fileExistsAtPath:p]) {
            [fm removeItemAtPath:p error:NULL];
        }
    }
}

@end
