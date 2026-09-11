//
//  TSLogStore.m
//  TrollAutoTouch
//

#import "TSLogStore.h"
#import "TSPaths.h"

// 单来源内存/界面保留行数(2026-09-11 由 2000 收紧到 500: 挂机脚本时长跑,
// 日志越多越占内存与 UI 重绘时间, 500 行足够看清"最近发生了什么")。
static const NSUInteger kMaxLogCount = 500;
static const NSUInteger kFileFlushBatch = 50;   // 攒满 50 条批量落盘
// 日志文件行数上限(2026-09-11 新增): touch.log / debug.log 各自最多 500 行,
// 超出即裁剪为"最新 500 行"。行数是精确维护的(见 _lineCountForPath: 说明),
// 不靠文件大小估算, 所以不会出现"说是 500 行实际几千行"的情况。
static const NSUInteger kMaxLogFileLines = 500;

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

// 各日志文件当前的行数(键 = 文件路径)。
// 用于把文件行数严格控制在 kMaxLogFileLines(500): 首次访问某文件时读文件统计一次,
// 之后每次写入在该值上累加。调用方需持有 @synchronized(self) —— 只在 TSLogStore 内使用。
static NSMutableDictionary<NSString *, NSNumber *> *s_logFileLines = nil;

static NSMutableDictionary<NSString *, NSNumber *> *LogFileLines(void) {
    if (!s_logFileLines) s_logFileLines = [NSMutableDictionary dictionary];
    return s_logFileLines;
}

// 日志文件内容 → 非空行数组(统计行数 / 裁剪尾部共用)
static NSArray<NSString *> *TSNonEmptyLines(NSString *content) {
    if (content.length == 0) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *line in [content componentsSeparatedByString:@"\n"]) {
        if (line.length > 0) [out addObject:line];
    }
    return out;
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
        // 记录文件真实行数: 内存数组只留 kMaxLogCount 行, 但文件可能仍有更多行,
        // 后续写入时据此判断是否需要裁剪到 500 行。
        NSUInteger fileLines = 0;
        for (NSString *line in lines) {
            if (line.length == 0) continue;
            fileLines += 1;
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
        LogFileLines()[path] = @(fileLines);
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
    }
    // 删文件 + 重置行数缓存放到日志队列上执行: 与该队列上的落盘/裁剪串行,
    // 避免"清空后又被一个在途批次写回"或与行数缓存产生竞态。
    NSString *touchPath = self.logFilePath;
    NSString *debugPath = self.debugLogFilePath;
    dispatch_sync(LogFileQueue(), ^{
        LogFileLines()[touchPath] = @0;
        LogFileLines()[debugPath] = @0;
        [[NSFileManager defaultManager] removeItemAtPath:touchPath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:debugPath error:nil];
    });
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

    NSUInteger linesInFile = [self _lineCountForPath:path];

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

    // 行数上限(500): 超出即裁剪为"最新 500 行", 精确按行裁 —— 旧实现只在文件超过
    // 5MB 时整体删除, 挂机数小时会攒出上万行, 每次追加都变慢, 也占内存/流量。
    NSUInteger total = linesInFile + lines.count;
    if (total > kMaxLogFileLines) {
        total = [self _trimFile:path keep:kMaxLogFileLines];
    }
    @synchronized (self) {
        LogFileLines()[path] = @(total);
    }
}

// 该文件当前行数: 首次询问时读文件统计一次, 之后由写入/裁剪结果缓存 ——
// 避免每次落盘都整读文件(落盘最多每 50 条或 1 秒一次, 读的是 ≤500 行的小文件)。
- (NSUInteger)_lineCountForPath:(NSString *)path {
    @synchronized (self) {
        NSNumber *cached = LogFileLines()[path];
        if (cached) return cached.unsignedIntegerValue;
    }
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    NSUInteger count = TSNonEmptyLines(content).count;
    @synchronized (self) {
        LogFileLines()[path] = @(count);
    }
    return count;
}

// 把日志文件裁剪为"最新 keep 行", 返回裁剪后的行数(文件不存在/读失败返回 0)。
- (NSUInteger)_trimFile:(NSString *)path keep:(NSUInteger)keep {
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    NSArray<NSString *> *lines = TSNonEmptyLines(content);
    if (lines.count <= keep) return lines.count;
    NSArray<NSString *> *tail = [lines subarrayWithRange:NSMakeRange(lines.count - keep, keep)];
    [[tail componentsJoinedByString:@"\n"] writeToFile:path
                                            atomically:YES
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    return keep;
}

@end
