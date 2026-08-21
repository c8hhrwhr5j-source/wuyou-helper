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
    NSMutableArray<NSString *> *_logs;
    NSMutableArray<NSString *> *_filePending;      // 待写 touch.log 的日志行(锁保护)
    NSMutableArray<NSString *> *_debugPending;     // 待写 debug.log 的日志行(锁保护)
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
        _filePending = [NSMutableArray array];
        _debugPending = [NSMutableArray array];
        [self _loadHistoryFromFile];
    }
    return self;
}

/// 启动时从本地日志文件加载历史，保证关闭重开 app 后日志仍可见
- (void)_loadHistoryFromFile {
    [TSPaths ensureDirectoriesExist];
    NSString *content = [NSString stringWithContentsOfFile:self.logFilePath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    if (content.length == 0) return;
    NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
    @synchronized (self) {
        for (NSString *line in lines) {
            if (line.length == 0) continue;
            [_logs addObject:line];
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

// 默认入口: 程序自身产生的日志 → touch.log
- (void)append:(NSString *)message {
    [self append:message toFile:@"touch.log"];
}

// 分类入口: fileName 为 log 目录下的文件名 ("touch.log" 或 "debug.log")。
// 两类日志统一进内存 _logs(UI 查看日志时全部可见), 落盘按文件分流:
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
        [_filePending removeAllObjects];
        [_debugPending removeAllObjects];
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
