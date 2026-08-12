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
    self.navigationItem.rightBarButtonItem = clearBtn;

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
    NSString *content = [[[TSLogStore shared].logs componentsJoinedByString:@"\n"]
                         stringByAppendingString:@"\n"];
    _textView.text = content;

    if (content.length > 0) {
        [_textView scrollRangeToVisible:NSMakeRange(content.length - 1, 1)];
    }
}

- (void)_clear {
    [[TSLogStore shared] clear];
    [self _refresh];
}

@end
