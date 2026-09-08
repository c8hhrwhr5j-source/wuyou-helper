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

/// 某来源日志的"行号游标体系"最新值(单调递增)。
/// 每来源每条日志获得一个自增行号(0 起)；内存只保留最新 2000 行，
/// 更早的行被淘汰但行号继续增长，故以"行号"而非"数组下标"做增量游标，
/// 可避免日志满 2000 条后下标停在 2000、新日志永远无法被增量拉取的 bug。
- (NSInteger)logSeqTotalForFile:(NSString *)fileName;

/// 增量拉取某来源日志（供 HTTP /api/log 使用）：
///   after     客户端已知的最新行号(上次返回的 nextIndex)，首次传 0
///   cleared   出参；YES = 游标行已被淘汰 / 日志被清空 / 客户端行号超前，
///             此时返回全量内存日志，客户端应整体替换显示
///   nextIndex 出参；该来源当前最新行号，下次请求应作为 after 传回
///   @return   after 之后新增的行（cleared 时返回全量；无新增返回空数组）
- (NSArray<NSString *> *)logsForFile:(NSString *)fileName
                              after:(NSInteger)after
                            cleared:(BOOL *)cleared
                         nextIndex:(NSInteger *)nextIndex;

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
