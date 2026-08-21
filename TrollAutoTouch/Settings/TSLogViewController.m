//
//  TSLogViewController.m
//  TrollAutoTouch
//

#import "TSLogViewController.h"
#import "../Common/TSLogStore.h"
#import "../Common/TSPaths.h"

@interface TSLogViewController () {
    NSString *_mode;   // @"script" = 脚本日志, @"system" = 系统日志
}

@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) NSTimer *refreshTimer;

@end

@implementation TSLogViewController

- (instancetype)initWithMode:(NSString *)mode {
    self = [super init];
    if (self) {
        _mode = [mode isEqualToString:@"script"] ? @"script" : @"system";
    }
    return self;
}

- (instancetype)init {
    return [self initWithMode:@"system"];
}

// 页面展示名: 脚本日志 / 系统日志
- (NSString *)_displayName {
    return [_mode isEqualToString:@"script"] ? @"脚本日志" : @"系统日志";
}

// 来源文件名: debug.log(脚本主动日志) / touch.log(程序自身日志)
- (NSString *)_fileName {
    return [_mode isEqualToString:@"script"] ? @"debug.log" : @"touch.log";
}

// 对应日志文件完整路径
- (NSString *)_filePath {
    return [_mode isEqualToString:@"script"]
        ? [TSLogStore shared].debugLogFilePath
        : [TSLogStore shared].logFilePath;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [TSColors bg];

    UILabel *title = [[UILabel alloc] init];
    title.text = [self _displayName];
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textColor = [TSColors label];
    [title sizeToFit];
    self.navigationItem.titleView = title;

    UIBarButtonItem *clearBtn = [[UIBarButtonItem alloc] initWithTitle:@"清空"
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(_clear)];
    clearBtn.tintColor = [TSColors danger];

    UIBarButtonItem *copyBtn = [[UIBarButtonItem alloc] initWithTitle:@"复制"
                                                                style:UIBarButtonItemStylePlain
                                                               target:self
                                                               action:@selector(_copy)];
    copyBtn.tintColor = [TSColors tint];
    self.navigationItem.rightBarButtonItems = @[copyBtn, clearBtn];

    _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _textView.editable = NO;
    _textView.selectable = YES;
    _textView.backgroundColor = [TSColors bg];
    _textView.textColor = [TSColors label];
    _textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _textView.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    [self.view addSubview:_textView];

    [self _refresh];

    // 每秒自动刷新(运行中的脚本会持续输出日志)
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                     target:self
                                                   selector:@selector(_refresh)
                                                   userInfo:nil
                                                    repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_refreshTimer invalidate];
    _refreshTimer = nil;
}

- (void)_refresh {
    // 顶部标注日志来源, 界面清晰区分两类日志; 并显示对应文件路径便于本地查找。
    NSMutableString *content = [NSMutableString string];
    if ([_mode isEqualToString:@"script"]) {
        [content appendString:@"脚本日志 (main.lua 主动 log/logStr/print)\n"];
    } else {
        [content appendString:@"系统日志 (程序自身日志)\n"];
    }
    [content appendString:[NSString stringWithFormat:@"文件: %@\n", [self _filePath]]];
    [content appendString:@"────────────────────────\n"];
    // 仅展示本来源的日志, 另一类日志不混入
    NSArray<NSString *> *lines = [[TSLogStore shared] logsForFile:[self _fileName]];
    [content appendString:[[lines componentsJoinedByString:@"\n"]
                           stringByAppendingString:@"\n"]];
    _textView.text = content;

    // 自动滚动到最新日志明细
    if (content.length > 0) {
        [_textView scrollRangeToVisible:NSMakeRange(content.length - 1, 1)];
    }
}

- (void)_clear {
    [[TSLogStore shared] clear];
    [self _refresh];
}

- (void)_copy {
    // 复制当前来源的日志内容到剪贴板(不含文件路径头)
    NSArray<NSString *> *lines = [[TSLogStore shared] logsForFile:[self _fileName]];
    NSString *logs = [[lines componentsJoinedByString:@"\n"]
                      stringByAppendingString:@"\n"];
    UIPasteboard.generalPasteboard.string = logs;

    NSString *msg = [_mode isEqualToString:@"script"] ? @"已复制脚本日志" : @"已复制系统日志";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:ac animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ac dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

@end
