//
//  TSScriptUIViewController.m
//  TrollAutoTouch
//

#import "TSScriptUIViewController.h"
#import "TSHTTPServer.h"
#import "TSLuaBridge.h"
#import "TSHUDHost.h"
#import <WebKit/WebKit.h>

@interface TSScriptUIViewController () <WKNavigationDelegate>
@property (nonatomic, strong) NSString *scriptName;
@property (nonatomic, strong) NSString *scriptTitle;
@property (nonatomic, strong) WKWebView *webView;
@end

@implementation TSScriptUIViewController

- (instancetype)initWithScriptName:(NSString *)name title:(nullable NSString *)title {
    self = [super init];
    if (self) {
        _scriptName = [name copy];
        _scriptTitle = title.length ? [title copy] : [name copy];
        // 强制全屏 (无返回按钮, 无导航栏)
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)prefersStatusBarHidden {
    return NO;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    // 网页设置页顶部为深色背景, 状态栏文字用白色
    return UIStatusBarStyleLightContent;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    // 确保内嵌 HTTP 服务器在运行 (网页经 http://127.0.0.1 访问)
    TSHTTPServer *server = [TSHTTPServer shared];
    if (!server.isRunning) {
        [server start];
    }

    // 全屏网页视图 (无原生导航栏/返回按钮, 网页自身带顶部标题与底部按钮)
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.allowsInlineMediaPlayback = YES;
    cfg.dataDetectorTypes = WKDataDetectorTypeNone;
    _webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    _webView.navigationDelegate = self;
    _webView.backgroundColor = [UIColor whiteColor];
    _webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_webView];
    _webView.frame = self.view.bounds;

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
    // 网页点"取消" → 服务器发出通知 → 停止脚本并关闭设置页
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_onCancelRequest:)
                                                 name:TSScriptUICancelRequestNotification
                                               object:nil];
}

#pragma mark - 操作

- (void)_dismissAndFinish:(BOOL)didRun {
    if (_hostedInHUD) {
        // HUD 承载模式: 页面由 TSHUDHost 系统级层承载 (App 后台时 ui.open 弹出),
        // 未被 present, 直接移除 view 并手动 flush, 确保后台也能立刻消失。
        [[TSHUDHost shared] dismissViewControllerFromHUD:self];
        if (self.onFinish) self.onFinish(didRun);
        return;
    }
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.onFinish) self.onFinish(didRun);
    }];
}

- (void)_onRunRequest:(NSNotification *)note {
    NSString *name = note.userInfo[@"name"];
    if ([name isEqualToString:_scriptName]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _dismissAndFinish:YES];
        });
    }
}

- (void)_onCancelRequest:(NSNotification *)note {
    NSString *name = note.userInfo[@"name"];
    if (![name isEqualToString:_scriptName]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_cancelRequested) return;  // 已取消, 防重复
        self->_cancelRequested = YES;
        // 停止当前脚本 (脚本内 ui.open() 阻塞等待时会因停止标志立即返回)
        [[TSLuaBridge shared] stop];
        [self _dismissAndFinish:NO];
    });
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"[ScriptUI] 加载失败: %@", error.localizedDescription);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"[ScriptUI] 加载失败(provisional): %@", error.localizedDescription);
}

@end
