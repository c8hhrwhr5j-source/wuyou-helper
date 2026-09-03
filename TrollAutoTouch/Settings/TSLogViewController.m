//
//  TSLogViewController.m
//  TrollAutoTouch
//

#import "TSLogViewController.h"
#import "../Common/TSLogStore.h"
#import "../Common/TSPaths.h"

@interface TSLogViewController () <UIScrollViewDelegate> {
    NSString *_mode;   // @"script" = 脚本日志, @"system" = 系统日志
}

@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) NSTimer *refreshTimer;
// YES = 自动跟随最新日志(处于底部时); NO = 用户已上滑翻阅, 停止拉回底部
@property (nonatomic, assign) BOOL followTail;
// 已渲染过一次(首帧/空日志也要渲染出头部说明, 之后再无新日志则跳过刷新)
@property (nonatomic, assign) BOOL renderedOnce;
// 上次渲染的最后一行, 用于判断是否有新日志
@property (nonatomic, copy) NSString *lastTail;

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
    _textView.delegate = self;   // 接收滚动事件, 判断用户是否手动翻阅
    [self.view addSubview:_textView];

    // 默认跟随最新日志(刚打开页面停在底部); 用户上滑后停止跟随
    _followTail = YES;
    _renderedOnce = NO;
    _lastTail = nil;

    [self _refresh];

    // 每秒自动刷新(运行中的脚本会持续输出日志); 无新日志时 _refresh 直接返回, 不打断阅读
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

// 刷新前当前视口顶部可见的字符位置(用于用户翻阅时保持阅读位置)
- (NSUInteger)_topVisibleChar {
    UITextView *tv = _textView;
    if (tv.text.length == 0) return NSNotFound;
    CGRect visibleRect = CGRectMake(tv.contentOffset.x, tv.contentOffset.y,
                                    tv.bounds.size.width, tv.bounds.size.height);
    NSRange glyphRange = [tv.layoutManager glyphRangeForBoundingRect:visibleRect
                                                      inTextContainer:tv.textContainer];
    if (glyphRange.location == NSNotFound) return NSNotFound;
    NSRange charRange = [tv.layoutManager characterRangeForGlyphRange:glyphRange
                                                       actualGlyphRange:NULL];
    return charRange.location;
}

- (void)_refresh {
    // 顶部标注日志来源, 界面清晰区分两类日志; 并显示对应文件路径便于本地查找。
    NSArray<NSString *> *lines = [[TSLogStore shared] logsForFile:[self _fileName]];
    NSString *tail = lines.lastObject;

    // 无新日志(且已渲染过首帧): 直接返回, 避免每秒全量重拼 + 打断用户滚动位置
    if (_renderedOnce && (tail == nil && _lastTail == nil)) return;
    if (_renderedOnce && tail != nil && [_lastTail isEqualToString:tail]) return;
    _renderedOnce = YES;
    _lastTail = tail;

    // 用户正在翻阅旧内容时, 重拼前记录其视口顶部字符, 重拼后恢复
    NSUInteger topChar = _followTail ? NSNotFound : [self _topVisibleChar];

    NSMutableString *content = [NSMutableString string];
    if ([_mode isEqualToString:@"script"]) {
        [content appendString:@"脚本日志 (main.lua 主动 log/logStr/print)\n"];
    } else {
        [content appendString:@"系统日志 (程序自身日志)\n"];
    }
    [content appendString:[NSString stringWithFormat:@"文件: %@\n", [self _filePath]]];
    [content appendString:@"────────────────────────\n"];
    [content appendString:[[lines componentsJoinedByString:@"\n"]
                           stringByAppendingString:@"\n"]];
    _textView.text = content;

    if (content.length == 0) return;

    if (_followTail) {
        // 处于底部: 跟随最新日志, 滚到底部
        [_textView scrollRangeToVisible:NSMakeRange(content.length - 1, 1)];
    } else if (topChar != NSNotFound) {
        // 用户在翻阅: 保持其阅读位置, 不拉回底部
        [_textView scrollRangeToVisible:NSMakeRange(topChar, 0)];
    }
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    // 用户开始手动滚动: 立即停止自动跟随, 不再被拉回底部
    _followTail = NO;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // 用户滚回到接近底部 → 恢复自动跟随新日志
    CGFloat bottom = scrollView.contentSize.height - scrollView.bounds.size.height;
    if (bottom <= 0) return;   // 内容不满一屏, 无需判断
    if (scrollView.contentOffset.y >= bottom - 40) {
        _followTail = YES;
    }
}

- (void)scrollViewDidScrollToTop:(UIScrollView *)scrollView {
    // 点状态栏回到顶部: 明确停在上方, 停止跟随
    _followTail = NO;
}

- (void)_clear {
    [[TSLogStore shared] clear];
    _renderedOnce = NO;
    _lastTail = nil;
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
