//
//  TSLogStore.h
//  TrollAutoTouch
//
//  全局日志存储 —— 收集 Lua 引擎及运行时日志，
//  供设置页"查看日志"读取；同时追加写入 /var/mobile/touch/log/touch.log。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSLogStore : NSObject

+ (instancetype)shared;

/// 最近的全部日志（最多保留 2000 条，带时间戳）
@property (nonatomic, readonly) NSArray<NSString *> *logs;

/// 日志文件完整路径 /var/mobile/touch/log/touch.log
@property (nonatomic, readonly) NSString *logFilePath;

/// 追加一条日志（线程安全，自动加时间戳）
- (void)append:(NSString *)message;

/// 清空内存日志并清空日志文件
- (void)clear;

@end

NS_ASSUME_NONNULL_END
