//
//  TSLogStore.m
//  TrollAutoTouch
//

#import "TSLogStore.h"
#import "TSPaths.h"

static const NSUInteger kMaxLogCount = 2000;

@implementation TSLogStore {
    NSMutableArray<NSString *> *_logs;
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

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [df stringFromDate:[NSDate date]], message];

    @synchronized (self) {
        [_logs addObject:line];
        if (_logs.count > kMaxLogCount) {
            [_logs removeObjectsInRange:NSMakeRange(0, _logs.count - kMaxLogCount)];
        }
        [self _appendToFile:line];
    }
}

- (void)clear {
    @synchronized (self) {
        [_logs removeAllObjects];
        [[NSFileManager defaultManager] removeItemAtPath:self.logFilePath error:nil];
    }
}

#pragma mark - File

- (void)_appendToFile:(NSString *)line {
    [TSPaths ensureDirectoriesExist];

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
            NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
            if (data) [fh writeData:data];
        } @catch (NSException *e) {
            NSLog(@"[TSLogStore] 写日志文件失败: %@", e);
        } @finally {
            [fh closeFile];
        }
    }
}

@end
