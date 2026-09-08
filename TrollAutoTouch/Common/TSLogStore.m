//
//  TSLogStore.m
//  TrollAutoTouch
//

#import "TSLogStore.h"
#import "TSPaths.h"

static const NSUInteger kMaxLogCount = 2000;
static const NSUInteger kFileFlushBatch = 50;   // 攒满 50 条批量落盘
static const NSUInteger kMaxLogFileBytes = 5 * 1024 * 1024;

// 日志文件写入队列(串行)，避免阻塞主线程
static dispatch_queue_t LogFileQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.trollautotouch.logfile", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// 时间格式化器全局复用: 每次 append 都新建 NSDateFormatter 会在高频日志时
// 造成大量内存抖动, 拖慢主/后台线程。
static NSDateFormatter *LogTimeFormatter(void) {
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss";
    });
    return df;
}

@implementation TSLogStore {
    NSMutableArray<NSString *> *_logs;             // 合并日志(全部, 向后兼容)
    NSMutableArray<NSString *> *_touchLogs;        // 程序自身日志(touch.log 来源)
    NSMutableArray<NSString *> *_debugLogs;        // 脚本主动日志(debug.log 来源)
    NSMutableArray<NSString *> *_filePending;      // 待写 touch.log 的日志行(锁保护)
    NSMutableArray<NSString *> *_debugPending;     // 待写 debug.log 的日志行(锁保护)
    NSInteger _touchSeqTotal;                      // touch.log 来源已分配行号总数(单调递增)
    NSInteger _debugSeqTotal;                      // debug.log 来源已分配行号总数(单调递增)
}

+ (instancetype)shared {
    static TSLogStore *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [TSLogStore new];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _logs = [NSMutableArray array];
        _touchLogs = [NSMutableArray array];
        _debugLogs = [NSMutableArray array];
        _filePending = [NSMutableArray array];
        _debugPending = [NSMutableArray array];
        [self _loadHistoryFromFile];
    }
    return self;
}

/// 启动时从本地日志文件加载历史，保证关闭重开 app 后日志仍可见。
/// 两个日志文件分别加载到对应来源数组, 并合并进 _logs。
- (void)_loadHistoryFromFile {
    [TSPaths ensureDirectoriesExist];
    [self _loadFile:self.logFilePath into:_touchLogs seq:&_touchSeqTotal];
    [self _loadFile:self.debugLogFilePath into:_debugLogs seq:&_debugSeqTotal];
}

/// 从磁盘文件加载历史日志到内存来源数组，并按行顺序分配行号(0 起递增)。
/// 行号按"读到的总行数"累计(超上限淘汰头部后行号不回收)，
/// 因此数组第 0 行对应行号 = seqTotal - 数组当前行数。
- (void)_loadFile:(NSString *)path
             into:(NSMutableArray<NSString *> *)source
              seq:(NSInteger *)seqPtr {
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    if (content.length == 0) return;
    NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
    @synchronized (self) {
        for (NSString *line in lines) {
            if (line.length == 0) continue;
            [source addObject:line];
            [_logs addObject:line];
            (*seqPtr) += 1;   // 每读入一行分配一个新行号
            if (source.count > kMaxLogCount) {
                [source removeObjectsInRange:NSMakeRange(0, source.count - kMaxLogCount)];
            }
            if (_logs.count > kMaxLogCount) {
                [_logs removeObjectsInRange:NSMakeRange(0, _logs.count - kMaxLogCount)];
            }
        }
    }
}

- (NSString *)logFilePath {
    return [TSPaths pathForLog:@"touch.log"];
}

/// debug.log 文件完整路径（脚本主动 log/logStr/print 输出）
- (NSString *)debugLogFilePath {
    return [TSPaths pathForLog:@"debug.log"];
}

- (NSArray<NSString *> *)logs {
    @synchronized (self) {
        return [_logs copy];
    }
}

// 按来源返回内存日志: "debug.log" → 脚本主动日志, 其他 → 程序自身日志。
// 供设置页"查看脚本日志"/"查看系统日志"分别展示, 来源互不混入。
- (NSArray<NSString *> *)logsForFile:(NSString *)fileName {
    @synchronized (self) {
        if ([fileName isEqualToString:@"debug.log"]) return [_debugLogs copy];
        return [_touchLogs copy];
    }
}

- (NSInteger)logSeqTotalForFile:(NSString *)fileName {
    @synchronized (self) {
        if ([fileName isEqualToString:@"debug.log"]) return _debugSeqTotal;
        return _touchSeqTotal;
    }
}

// 行号游标增量查询(供 /api/log)：
// 内存数组保留 [seqStart, seqTotal) 行号区间内的日志，seqStart = seqTotal - 行数。
// 行号不在数组区间(被淘汰/清空/客户端超前)时 cleared=YES 并返回全量，由客户端替换显示。
- (NSArray<NSString *> *)logsForFile:(NSString *)fileName
                              after:(NSInteger)after
                            cleared:(BOOL *)cleared
                         nextIndex:(NSInteger *)nextIndex {
    @synchronized (self) {
        BOOL isDebug = [fileName isEqualToString:@"debug.log"];
        NSMutableArray<NSString *> *source = isDebug ? _debugLogs : _touchLogs;
        NSInteger seqTotal = isDebug ? _debugSeqTotal : _touchSeqTotal;
        NSInteger count = (NSInteger)source.count;
        NSInteger seqStart = seqTotal - count;   // 数组第 0 行对应的行号
        if (cleared) *cleared = NO;
        if (nextIndex) *nextIndex = seqTotal;

        if (count == 0) {
            // 空：日志被清空过(或从未产生)。客户端曾持有旧游标 → 标记 cleared。
            if (cleared) *cleared = (after > 0);
            return @[];
        }
        if (after > seqTotal) {
            // 客户端行号超前：设备重启/清空后行号重新累计 → 返回全量校正
            if (cleared) *cleared = YES;
            return [source copy];
        }
        if (after == seqTotal) {
            return @[];   // 客户端已是最新，无新增
        }
        if (after < seqStart) {
            // 客户端游标行已被淘汰 → 全量替换，避免"下标/行号停在容量上限"后永不更新
            if (cleared) *cleared = YES;
            return [source copy];
        }
        // seqStart <= after < seqTotal: 返回 (after - seqStart) 起的新增行
        NSInteger offset = after - seqStart;
        return [source subarrayWithRange:NSMakeRange((NSUInteger)offset,
                                                     (NSUInteger)(count - offset))];
    }
}

// 默认入口: 程序自身产生的日志 → touch.log
- (void)append:(NSString *)message {
    [self append:message toFile:@"touch.log"];
}

// 分类入口: fileName 为 log 目录下的文件名 ("touch.log" 或 "debug.log")。
// 两类日志统一进内存 _logs(向后兼容), 并按来源分别进 _touchLogs/_debugLogs
// (设置页"查看系统日志/脚本日志"按来源展示), 落盘按文件分流:
//   touch.log = 程序自身日志(引擎诊断/运行时/senderID/脚本启停等)
//   debug.log = main.lua 主动写入的 log/logStr/print
- (void)append:(NSString *)message toFile:(NSString *)fileName {
    if (message.length == 0) return;
    if (fileName.length == 0) fileName = @"touch.log";

    NSString *line = [NSString stringWithFormat:@"[%@] %@",
                      [LogTimeFormatter() stringFromDate:[NSDate date]], message];

    BOOL flushNow = NO;
    @synchronized (self) {
        [_logs addObject:line];
        if (_logs.count > kMaxLogCount) {
            [_logs removeObjectsInRange:NSMakeRange(0, _logs.count - kMaxLogCount)];
        }
        // 来源分离: debug.log → 脚本日志数组, 其余 → 程序自身日志数组
        NSMutableArray *sourceLogs = [fileName isEqualToString:@"debug.log"] ? _debugLogs : _touchLogs;
        if (fileName.length > 0 && [fileName isEqualToString:@"debug.log"]) {
            _debugSeqTotal += 1;   // 新日志获得行号 = 递增后的行号总数
        } else {
            _touchSeqTotal += 1;
        }
        [sourceLogs addObject:line];
        if (sourceLogs.count > kMaxLogCount) {
            [sourceLogs removeObjectsInRange:NSMakeRange(0, sourceLogs.count - kMaxLogCount)];
        }
        // 批量落盘: 攒满一批立即写; 否则 1s 兜底, 避免逐条 open/close 文件
        NSMutableArray *pending = [fileName isEqualToString:@"debug.log"] ? _debugPending : _filePending;
        [pending addObject:line];
        if (pending.count >= kFileFlushBatch) flushNow = YES;
    }
    if (flushNow) {
        [self _flushFile];
    } else {
        [self _scheduleLazyFlush];
    }
}

- (void)clear {
    @synchronized (self) {
        [_logs removeAllObjects];
        [_touchLogs removeAllObjects];
        [_debugLogs removeAllObjects];
        [_filePending removeAllObjects];
        [_debugPending removeAllObjects];
        _touchSeqTotal = 0;   // 行号随清空归零，客户端游标将失效(cleared)由全量替换校正
        _debugSeqTotal = 0;
        [[NSFileManager defaultManager] removeItemAtPath:self.logFilePath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:self.debugLogFilePath error:nil];
    }
}

#pragma mark - File

// 立即派发一次批量落盘(两个日志文件都排空)
- (void)_flushFile {
    dispatch_async(LogFileQueue(), ^{
        [self _drainAllPending];
    });
}

// 兜底: 1s 内未攒满一批也落盘一次, 避免低频日志长期滞留内存
- (void)_scheduleLazyFlush {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   LogFileQueue(), ^{
        [self _drainAllPending];
    });
}

- (void)_drainAllPending {
    [self _drainPending:_filePending  path:self.logFilePath];
    [self _drainPending:_debugPending path:self.debugLogFilePath];
}

// 从指定 pending 队列取走一批并追加到对应文件
- (void)_drainPending:(NSMutableArray<NSString *> *)pending path:(NSString *)path {
    NSArray<NSString *> *batch = nil;
    @synchronized (self) {
        if (pending.count == 0) return;
        batch = [pending copy];
        [pending removeAllObjects];
    }
    [self _appendLinesToFile:batch path:path];
}

- (void)_appendLinesToFile:(NSArray<NSString *> *)lines path:(NSString *)path {
    if (lines.count == 0 || path.length == 0) return;
    [TSPaths ensureDirectoriesExist];

    // 日志文件上限 5MB: 超出则重置, 只保留最新批次, 防止无限膨胀
    NSDictionary *attrs = [[NSFileManager defaultManager]
                           attributesOfItemAtPath:path error:nil];
    if (attrs && [attrs[NSFileSize] unsignedLongLongValue] > kMaxLogFileBytes) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:path
                                                contents:nil
                                              attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    if (fh) {
        @try {
            [fh seekToEndOfFile];
            NSString *blob = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
            NSData *data = [blob dataUsingEncoding:NSUTF8StringEncoding];
            if (data) [fh writeData:data];
        } @catch (NSException *e) {
            NSLog(@"[TSLogStore] 写日志文件失败: %@", e);
        } @finally {
            [fh closeFile];
        }
    }
}

@end
