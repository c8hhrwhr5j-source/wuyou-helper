//
//  TSLogStore.h
//  TrollAutoTouch
//
//  全局日志存储 —— 收集 Lua 引擎及运行时日志，
//  供设置页"查看日志"读取；同时追加写入 /var/mobile/touch/log/ 下日志文件。
//  落盘分类:
//    touch.log = 程序自身产生的日志(引擎诊断/运行时/senderID/脚本启停等)
//    debug.log = main.lua 主动写入的 log/logStr/print
//  两类日志统一进内存 logs(UI 查看日志时全部可见), 仅文件按类别分流。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSLogStore : NSObject

+ (instancetype)shared;

/// 最近的全部日志（最多保留 2000 条，带时间戳，两类日志合并）
@property (nonatomic, readonly) NSArray<NSString *> *logs;

/// 按日志来源返回内存日志（最多各保留 2000 条，带时间戳）:
///   fileName == "debug.log" → 脚本主动日志 (main.lua 的 log/logStr/print)
///   其他 (如 "touch.log")   → 程序自身日志
/// 供设置页"查看脚本日志"/"查看系统日志"按来源分别展示。
- (NSArray<NSString *> *)logsForFile:(NSString *)fileName;

/// 程序自身日志文件完整路径 /var/mobile/touch/log/touch.log
@property (nonatomic, readonly) NSString *logFilePath;

/// main.lua 主动日志文件完整路径 /var/mobile/touch/log/debug.log
@property (nonatomic, readonly) NSString *debugLogFilePath;

/// 追加一条程序自身日志（线程安全，自动加时间戳，落盘 touch.log）
- (void)append:(NSString *)message;

/// 追加一条日志到指定文件（fileName: "touch.log" 或 "debug.log"；线程安全，自动加时间戳）
- (void)append:(NSString *)message toFile:(NSString *)fileName;

/// 清空内存日志并清空 touch.log / debug.log 两个日志文件
- (void)clear;

@end

NS_ASSUME_NONNULL_END
