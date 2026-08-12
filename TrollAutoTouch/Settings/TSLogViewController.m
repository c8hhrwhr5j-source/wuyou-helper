//
//  TSLogViewController.m
//  TrollAutoTouch
//

#import "TSLogViewController.h"
#import "../Common/TSLogStore.h"
#import "../Common/TSPaths.h"

@interface TSLogViewController ()

@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) NSTimer *refreshTimer;

@end

@implementation TSLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [TSColors bg];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"运行日志";
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
    // 顶部显示日志文件路径，便于用户在本地找到历史日志
    NSString *path = [TSPaths pathForLog:@"touch.log"];
    NSMutableString *content = [NSMutableString string];
    [content appendString:[NSString stringWithFormat:@"日志文件: %@\n%@\n", path, @"────────────────────────"]];
    [content appendString:[[[TSLogStore shared].logs componentsJoinedByString:@"\n"]
                           stringByAppendingString:@"\n"]];
    _textView.text = content;

    if (content.length > 0) {
        [_textView scrollRangeToVisible:NSMakeRange(content.length - 1, 1)];
    }
}

- (void)_clear {
    [[TSLogStore shared] clear];
    [self _refresh];
}

- (void)_copy {
    // 复制全部日志内容到剪贴板(不含文件路径头)
    NSString *logs = [[[TSLogStore shared].logs componentsJoinedByString:@"\n"]
                      stringByAppendingString:@"\n"];
    UIPasteboard.generalPasteboard.string = logs;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil
                                                               message:@"已复制全部日志"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:ac animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ac dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

@end
