//
//  TSExpiryStore.h
//  TrollAutoTouch
//
//  卡密到期时间的防篡改冗余存储:
//  将服务器下发的到期时间以混淆形式隐藏写入本地三个不同位置,
//  断网时通过三份一致性校验判断是否放行。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSExpiryStore : NSObject

/// 将到期时间隐藏写入本地三份冗余文件。expiry 为 nil 时视为清除。
+ (void)writeExpiryTime:(nullable NSDate *)expiry;

/// 读取并校验三份到期时间:
///   - 三份存在且一致 → 返回该时间, *tampered = NO
///   - 三份全部缺失(从未成功写入) → 返回 nil, *tampered = NO
///   - 任一缺失或值不一致(被篡改) → 返回 nil, *tampered = YES
+ (nullable NSDate *)readVerifiedExpiry:(nullable BOOL *)tampered;

/// 清除三份文件(非法设备判定/到期锁定时调用)
+ (void)clearAll;

@end

NS_ASSUME_NONNULL_END
