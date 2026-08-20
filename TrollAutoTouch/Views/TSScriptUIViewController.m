//
//  TSScriptUIViewController.m
//  TrollAutoTouch
//

#import "TSScriptUIViewController.h"
#import "TSHTTPServer.h"
#import <WebKit/WebKit.h>

@interface TSScriptUIViewController () <WKNavigationDelegate>
@property (nonatomic, strong) NSString *scriptName;
@property (nonatomic, strong) NSString *scriptTitle;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIView *topBar;
@property (nonatomic, strong) UIButton *closeBtn;
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation TSScriptUIViewController

- (instancetype)initWithScriptName:(NSString *)name title:(nullable NSString *)title {
    self = [super init];
    if (self) {
        _scriptName = [name copy];
        _scriptTitle = title.length ? [title copy] : [name copy];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    // 确保内嵌 HTTP 服务器在运行 (网页经 http://127.0.0.1 访问)
    TSHTTPServer *server = [TSHTTPServer shared];
    if (!server.isRunning) {
        [server start];
    }

    // 顶部条: 返回 + 标题
    _topBar = [[UIView alloc] init];
    _topBar.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
    [self.view addSubview:_topBar];

    _closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_closeBtn setTitle:@"‹ 返回" forState:UIControlStateNormal];
    _closeBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    [_closeBtn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    [_closeBtn addTarget:self action:@selector(_onClose) forControlEvents:UIControlEventTouchUpInside];
    [_topBar addSubview:_closeBtn];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = _scriptTitle;
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [_topBar addSubview:_titleLabel];

    // 网页视图
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.allowsInlineMediaPlayback = YES;
    cfg.dataDetectorTypes = WKDataDetectorTypeNone;
    _webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    _webView.navigationDelegate = self;
    _webView.backgroundColor = [UIColor whiteColor];
    [self.view addSubview:_webView];

    NSString *enc = [_scriptName stringByAddingPercentEncodingWithAllowedCharacters:
                     [NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *url = [NSString stringWithFormat:@"http://127.0.0.1:%u/ui/%@/index.html",
                     server.port, enc];
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
    [_webView loadRequest:req];

    // 网页点"开始运行" → 服务器发出通知 → 自动关闭回主界面
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_onRunRequest:)
                                                 name:TSScriptUIRunRequestNotification
                                               object:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat top = self.view.safeAreaInsets.top;
    if (top < 20) top = 20;
    CGFloat barH = 44;
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    _topBar.frame = CGRectMake(0, top, w, barH);
    _closeBtn.frame = CGRectMake(8, 0, 64, barH);
    _titleLabel.frame = CGRectMake(72, 0, w - 144, barH);
    _webView.frame = CGRectMake(0, top + barH, w, h - top - barH);
}

#pragma mark - 操作

- (void)_onClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)_onRunRequest:(NSNotification *)note {
    NSString *name = note.userInfo[@"name"];
    if ([name isEqualToString:_scriptName]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self dismissViewControllerAnimated:YES completion:nil];
        });
    }
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"[ScriptUI] 加载失败: %@", error.localizedDescription);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"[ScriptUI] 加载失败(provisional): %@", error.localizedDescription);
}

@end
