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
    NSMutableArray<NSString *> *_filePending; // 待写文件的日志行(锁保护)
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

- (NSArray<NSString *> *)logs {
    @synchronized (self) {
        return [_logs copy];
    }
}

- (void)append:(NSString *)message {
    if (message.length == 0) return;

    NSString *line = [NSString stringWithFormat:@"[%@] %@",
                      [LogTimeFormatter() stringFromDate:[NSDate date]], message];

    BOOL flushNow = NO;
    @synchronized (self) {
        [_logs addObject:line];
        if (_logs.count > kMaxLogCount) {
            [_logs removeObjectsInRange:NSMakeRange(0, _logs.count - kMaxLogCount)];
        }
        // 批量落盘: 攒满一批立即写; 否则 1s 兜底, 避免逐条 open/close 文件
        [_filePending addObject:line];
        if (_filePending.count >= kFileFlushBatch) flushNow = YES;
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
        [[NSFileManager defaultManager] removeItemAtPath:self.logFilePath error:nil];
    }
}

#pragma mark - File

// 立即派发一次批量落盘
- (void)_flushFile {
    dispatch_async(LogFileQueue(), ^{
        [self _drainFilePending];
    });
}

// 兜底: 1s 内未攒满一批也落盘一次, 避免低频日志长期滞留内存
- (void)_scheduleLazyFlush {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   LogFileQueue(), ^{
        [self _drainFilePending];
    });
}

- (void)_drainFilePending {
    NSArray<NSString *> *batch = nil;
    @synchronized (self) {
        if (_filePending.count == 0) return;
        batch = [_filePending copy];
        [_filePending removeAllObjects];
    }
    [self _appendLinesToFile:batch];
}

- (void)_appendLinesToFile:(NSArray<NSString *> *)lines {
    if (lines.count == 0) return;
    [TSPaths ensureDirectoriesExist];

    // 日志文件上限 5MB: 超出则重置, 只保留最新批次, 防止无限膨胀
    NSDictionary *attrs = [[NSFileManager defaultManager]
                           attributesOfItemAtPath:self.logFilePath error:nil];
    if (attrs && [attrs[NSFileSize] unsignedLongLongValue] > kMaxLogFileBytes) {
        [[NSFileManager defaultManager] removeItemAtPath:self.logFilePath error:nil];
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:self.logFilePath];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:self.logFilePath
                                                contents:nil
                                              attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:self.logFilePath];
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
