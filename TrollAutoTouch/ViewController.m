//
//  ViewController.m
//  TrollAutoTouch
//
//  主界面: 自检 + 截屏预览 + 脚本管理 + HUD 集成
//

#import "ViewController.h"
#import "TSHUDWindow.h"
#import "TSScreenCapture.h"
#import "TSHIDEventTouch.h"
#import "TSTouchSimulator.h"
#import "TSScriptEngine.h"
#import "TSTouchRecorder.h"
#import "TSTemplateMatcher.h"
#import "TSAppNodeInfo.h"
#import "TSDeviceInfo.h"
#import "TSHTTPServer.h"
#import "TSOCREngine.h"
#import "TSDaemonManager.h"
#import "TSColorFinder.h"
#import "TSToolExecutor.h"
#import "TSLuaBridge.h"
#import "TSPaths.h"
#import "Views/TSScriptUIViewController.h"

@interface ViewController () <TSLogDelegate, TSWebControlDelegate>
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIImageView *preview;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) dispatch_source_t logFlushTimer;
@end

@implementation ViewController {
    // 日志聚合缓冲: _logBuffer 任意线程追加, 50ms 定时器在主线程批量合并
    // 到 _logFull 并刷新 logView, 避免每条日志 O(n) 拼接刷爆主线程。
    NSMutableString *_logBuffer;
    NSMutableString *_logFull;
}

// "暂停 Lua"按钮的暂停/继续状态 (音量键面板也会同步更新它)
static BOOL _luaPausedByButton = NO;

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.06 green:0.08 blue:0.12 alpha:1.0];
    [self _buildUI];

    // 日志 UI 刷新节流定时器: 每 50ms 批量合并一次日志。
    // 脚本高频日志(循环里 logStr/print)时主线程只做受限长度的合并刷新,
    // 不会因逐条 O(n) 拼接 logView.text 而 CPU 100% → App 假死/脚本停摆。
    _logBuffer = [NSMutableString string];
    _logFull = [NSMutableString string];
    self.logFlushTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.logFlushTimer, dispatch_walltime(NULL, 0),
                              (uint64_t)(50 * NSEC_PER_MSEC), (uint64_t)(10 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(self.logFlushTimer, ^{ [self _flushLogView]; });
    dispatch_resume(self.logFlushTimer);

    [self _log:@"QQ音乐 v2.0 已启动。"];

    // 悬浮窗动作由 MainTabBarController 统一处理 (启停/暂停/关闭)

    // 设置 Web 服务器回调
    [TSHTTPServer shared].delegate = self;

    // 脚本网页设置 UI: 网页点"开始运行"后由 HTTP 服务器发出, 这里启动对应脚本
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_handleScriptUIRun:)
                                                 name:TSScriptUIRunRequestNotification
                                               object:nil];
}

- (void)_buildUI {
    CGFloat top = 10;
    CGFloat btnHeight = 36;
    CGFloat gapH = 8;
    CGFloat margin = 12;
    NSInteger cols = 2;
    CGFloat btnW = (self.view.bounds.size.width - margin * 2 - gapH) / cols;

    NSArray *titles = @[
        @"自检",          @"截屏预览",
        @"测试点击",      @"测试找色",
        @"启 Web 服务器",  @"停 Web 服务器",
        @"OCR 识别",      @"OCR 点击",
        @"设备信息",      @"磁盘信息",
        @"运行 demo",    @"停止脚本",
        @"运行 Lua",     @"停止 Lua",
        @"显示 HUD",     @"隐藏 HUD",
        @"启动守护",     @"Shell 执行",
        @"暂停 Lua",     @"脚本UI",
    ];

    for (NSUInteger i = 0; i < titles.count; i++) {
        NSInteger row = (NSInteger)(i / cols);
        NSInteger col = (NSInteger)(i % cols);
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(margin + col * (btnW + gapH),
                             top + row * (btnHeight + 6),
                             btnW, btnHeight);
        b.tag = (NSInteger)i;
        b.backgroundColor = [UIColor colorWithRed:0.15 green:0.30 blue:0.55 alpha:1];
        b.tintColor = [UIColor whiteColor];
        b.layer.cornerRadius = 6;
        b.titleLabel.font = [UIFont systemFontOfSize:12];
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b addTarget:self action:@selector(_onBtn:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
    }

    NSInteger totalRows = (NSInteger)((titles.count + cols - 1) / cols);
    CGFloat btnBottom = top + totalRows * (btnHeight + 6);

    CGFloat previewTop = btnBottom + 8;
    _preview = [[UIImageView alloc] initWithFrame:CGRectMake(margin, previewTop, self.view.bounds.size.width / 3, 200)];
    _preview.backgroundColor = [UIColor blackColor];
    _preview.contentMode = UIViewContentModeScaleAspectFit;
    _preview.layer.cornerRadius = 6;
    [self.view addSubview:_preview];

    _logView = [[UITextView alloc] initWithFrame:CGRectMake(margin + self.view.bounds.size.width / 3 + 8, previewTop,
        self.view.bounds.size.width - self.view.bounds.size.width / 3 - margin - 8, 200)];
    _logView.editable = NO;
    _logView.backgroundColor = [UIColor colorWithRed:0.02 green:0.02 blue:0.02 alpha:0.6];
    _logView.textColor = [UIColor colorWithRed:0.5 green:0.9 blue:0.6 alpha:1];
    _logView.font = [UIFont fontWithName:@"Menlo" size:9];
    _logView.layer.cornerRadius = 6;
    [self.view addSubview:_logView];
}

- (void)_onBtn:(UIButton *)b {
    switch (b.tag) {
        case 0:  [self _selfCheck]; break;
        case 1:  [self _capturePreview]; break;
        case 2:  [self _testTap]; break;
        case 3:  [self _testFindColor]; break;
        case 4:  [self _startServer]; break;
        case 5:  [self _stopServer]; break;
        case 6:  [self _testOCR]; break;
        case 7:  [self _testOCRTap]; break;
        case 8:  [self _showDeviceInfo]; break;
        case 9:  [self _showDiskInfo]; break;
        case 10: [self _runScript]; break;
        case 11: [self _stopScript]; break;
        case 12: [self _runLuaScript]; break;
        case 13: [self _stopLuaScript]; break;
        case 14: [[TSHUDWindow shared] show]; break;
        case 15: [[TSHUDWindow shared] hide]; break;
        case 16: [self _startDaemon]; break;
        case 17: [self _testShell]; break;
        case 18: [self _pauseLuaScript]; break;
        case 19: [self _openScriptUI]; break;
    }
}

#pragma mark - 功能按钮

- (void)_selfCheck {
    [self _log:@"════ 自检 ════"];
    uint8_t *px = NULL; int w=0,h=0;
    BOOL cap = [[TSTouchSimulator shared] capture:&px width:&w height:&h];
    [self _log:[NSString stringWithFormat:@"截屏: %@ (%dx%d)", cap?@"OK":@"失败", w, h]];
    if (px) free(px);

    // 设备信息
    [self _log:[NSString stringWithFormat:@"设备: %@ (%@) iOS %@",
                [TSDeviceInfo shared].deviceName,
                [TSDeviceInfo shared].modelIdentifier,
                [TSDeviceInfo shared].osVersion]];
    [self _log:[NSString stringWithFormat:@"屏幕: %.0fx%.0f scale=%.0f",
                [TSDeviceInfo shared].screenSize.width,
                [TSDeviceInfo shared].screenSize.height,
                [TSDeviceInfo shared].screenScale]];
    [self _log:@"触摸模块已加载(需 TrollStore 安装后实际注入才生效)"];
    [self _log:@"════ 自检完成 ════"];
}

- (void)_capturePreview {
    UIImage *img = [[TSScreenCapture shared] captureImage];
    if (img) {
        _preview.image = img;
        [self _log:@"截屏已更新。"];
    } else {
        [self _log:@"截屏失败(可能缺少 IOSurface 权限)。"];
    }
}

- (void)_testTap {
    CGSize s = [UIScreen mainScreen].bounds.size;
    CGPoint center = CGPointMake(s.width / 2, s.height / 2);
    [[TSHIDEventTouch shared] tapAtPoint:center duration:0.05];
    [self _log:[NSString stringWithFormat:@"已注入点击 (%.0f, %.0f)", center.x, center.y]];
}

- (void)_testFindColor {
    [self _log:@"正在截屏并查找红色 (0xFF0000)..."];
    uint8_t *px = NULL; int w=0,h=0;
    if (![[TSScreenCapture shared] captureScreenToRGBA:&px width:&w height:&h] || !px) {
        [self _log:@"截屏失败"]; return;
    }
    CGSize ss = [UIScreen mainScreen].bounds.size;
    TSColorResult *res = [TSColorFinder findColor:0xFF0000 rect:CGRectZero sim:0.9
                                          pixels:px width:w height:h screenSize:ss];
    free(px);
    if (res) {
        [self _log:[NSString stringWithFormat:@"找到红色于 (%.1f, %.1f) diff=%d",
                    res.point.x, res.point.y, res.diff]];
    } else {
        [self _log:@"当前屏幕未找到红色像素"];
    }
}

- (void)_runScript {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"demo" ofType:@"script"];
    if (path) {
        [[TSScriptEngine shared] runFile:path delegate:self];
        [[TSHUDWindow shared] setScriptRunning:YES];
        [self _log:@"演示脚本已启动"];
    } else {
        [self _log:@"未找到 demo.script，请先将脚本加入工程"];
    }
}

- (void)_stopScript {
    [[TSScriptEngine shared] stop];
    [[TSHUDWindow shared] setScriptRunning:NO];
    [self _log:@"已停止脚本"];
}

#pragma mark - Lua 脚本

- (void)_runLuaScript {
    __weak typeof(self) ws = self;
    [TSLuaBridge shared].logHandler = ^(NSString *msg) {
        [ws _log:msg];
    };

    // 优先运行 /var/mobile/touch/lua/demo.lua(用户可编辑)，否则用 Bundle 内置 demo.lua
    NSString *luaPath = [TSPaths pathForLua:@"demo.lua"];
    NSString *path = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:luaPath]) {
        path = luaPath;
    } else {
        path = [[NSBundle mainBundle] pathForResource:@"demo" ofType:@"lua"];
    }
    if (path) {
        [[TSLuaBridge shared] runFile:path];
        [self _log:[NSString stringWithFormat:@"[Lua] 启动脚本: %@", path]];
    } else {
        [self _log:@"[Lua] 未找到 demo.lua，请先添加脚本"];
    }
}

- (void)_stopLuaScript {
    [[TSLuaBridge shared] stop];
    [self _log:@"[Lua] 已请求停止"];
}

#pragma mark - 脚本网页设置 UI

// 打开脚本设置 UI: 列出有网页设置页的脚本, 选择后全屏显示设置网页
- (void)_openScriptUI {
    // 确保内嵌服务器运行 (设置网页由它提供)
    if (![TSHTTPServer shared].isRunning) {
        [[TSHTTPServer shared] start];
    }
    NSArray<NSString *> *names = [[TSHTTPServer shared] uiScriptNames];
    if (names.count == 0) {
        [self _log:@"[脚本UI] 未找到带设置页的脚本 (内置示例: demo)"];
        return;
    }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"脚本设置 UI"
                                                                message:@"选择脚本, 网页中配置参数后点\"开始运行\""
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *name in names) {
        [ac addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            TSScriptUIViewController *vc =
                [[TSScriptUIViewController alloc] initWithScriptName:name title:name];
            [self presentViewController:vc animated:YES completion:nil];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        ac.popoverPresentationController.sourceView = self.view;
        ac.popoverPresentationController.sourceRect =
            CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    }
    [self presentViewController:ac animated:YES completion:nil];
}

// 网页点"开始运行"回调: 运行 /var/mobile/touch/lua/<name>.lua, 不存在则用内置 <name>.lua
- (void)_handleScriptUIRun:(NSNotification *)note {
    NSString *name = note.userInfo[@"name"];
    if (name.length == 0) return;

    // 脚本已在运行(例如脚本内 ui.open() 弹出设置页后点"开始运行"):
    // 设置已由网页保存, 脚本会从 settings 表继续执行, 这里不能再启动一次, 否则脚本重复执行。
    if ([[TSLuaBridge shared] isRunning]) {
        return;
    }

    NSString *devPath = [TSPaths pathForLua:[name stringByAppendingString:@".lua"]];
    NSString *path = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:devPath]) {
        path = devPath;
    } else {
        path = [[NSBundle mainBundle] pathForResource:name ofType:@"lua"];
    }
    if (!path) {
        [self _log:[NSString stringWithFormat:@"[脚本UI] 未找到脚本 %@.lua (设备或内置)", name]];
        return;
    }
    __weak typeof(self) ws = self;
    [TSLuaBridge shared].logHandler = ^(NSString *msg) {
        [ws _log:msg];
    };
    [[TSLuaBridge shared] runFile:path];
    [self _log:[NSString stringWithFormat:@"[脚本UI] 启动脚本: %@", path]];
}

// 暂停/继续切换 (主界面按钮)。脚本运行期间也可按音量键呼出控制面板。
- (void)_pauseLuaScript {
    TSLuaBridge *lua = [TSLuaBridge shared];
    if (!lua.isRunning) {
        [self _log:@"[Lua] 当前没有脚本在运行"];
        return;
    }
    if (_luaPausedByButton) {
        [lua resume];
        _luaPausedByButton = NO;
        [self _log:@"[Lua] 已继续"];
    } else {
        [lua pause];
        _luaPausedByButton = YES;
        [self _log:@"[Lua] 已暂停 (脚本运行期间按音量键可呼出控制面板)"];
    }
}

- (void)_startServer {
    if ([[TSHTTPServer shared] isRunning]) {
        [self _log:[NSString stringWithFormat:@"服务器已在运行，端口 %d", [[TSHTTPServer shared] port]]];
        return;
    }
    [[TSHTTPServer shared] start];
    NSString *wifiIP = [[TSToolExecutor shared] wifiIPAddress];
    int port = [[TSHTTPServer shared] port];
    [self _log:[NSString stringWithFormat:@"Web 服务器已启动 → http://%@:%d", wifiIP ?: @"localhost", port]];
    [self _log:@"浏览器访问可远程控制设备"];
}

- (void)_stopServer {
    [[TSHTTPServer shared] stop];
    [self _log:@"Web 服务器已停止"];
}

- (void)_testOCR {
    [self _log:@"正在 OCR 识别整屏文字..."];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *img = [[TSScreenCapture shared] captureImage];
        if (!img) {
            [self _log:@"截屏失败"]; return;
        }
        NSArray<TSOCRResult *> *results = [[TSOCREngine shared] recognize:img];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _log:[NSString stringWithFormat:@"OCR 识别到 %lu 条文字:", (unsigned long)results.count]];
            for (TSOCRResult *r in results) {
                [self _log:[NSString stringWithFormat:@"  \"%@\" (%.0f,%.0f) %.0f%%",
                            r.text, r.center.x, r.center.y, r.confidence * 100]];
            }
        });
    });
}

- (void)_testOCRTap {
    [self _log:@"截屏并 OCR 查找可点击文字..."];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *img = [[TSScreenCapture shared] captureImage];
        if (!img) { [self _log:@"截屏失败"]; return; }
        NSArray<TSOCRResult *> *all = [[TSOCREngine shared] recognize:img];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _log:[NSString stringWithFormat:@"OCR 找到 %lu 个文字区域", (unsigned long)all.count]];
            if (all.count > 0) {
                [self _log:[NSString stringWithFormat:@"点击首个: \"%@\" (%.0f,%.0f)",
                            all[0].text, all[0].center.x, all[0].center.y]];
                [[TSOCREngine shared] tapText:all[0].text inImage:img];
            }
        });
    });
}

- (void)_showDeviceInfo {
    NSDictionary *info = [[TSDeviceInfo shared] fullInfo];
    [self _log:[NSString stringWithFormat:@"设备信息:\n%@", info]];
    NSString *wifi = [[TSToolExecutor shared] wifiIPAddress];
    [self _log:[NSString stringWithFormat:@"WiFi IP: %@", wifi ?: @"无"]];
}

- (void)_showDiskInfo {
    NSDictionary *info = [[TSToolExecutor shared] diskInfo];
    [self _log:[NSString stringWithFormat:@"磁盘:\n%@", info]];
    NSDictionary *mem = [[TSToolExecutor shared] memoryInfo];
    [self _log:[NSString stringWithFormat:@"内存:\n%@", mem]];
}

- (void)_startDaemon {
    [[TSDaemonManager shared] startAll];
    [self _log:@"守护服务已启动（悬浮窗 + 后台保活）"];
}

- (void)_testShell {
    NSString *cmd = @"uname -a";
    [self _log:[NSString stringWithFormat:@"执行: %@", cmd]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TSCmdResult *res = [[TSToolExecutor shared] executeCommand:cmd];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _log:[NSString stringWithFormat:@"结果 (exit=%d, %.2fs):\n%@",
                        res.exitCode, res.elapsed, res.standardOutput.length > 0 ? res.standardOutput : res.standardError]];
        });
    });
}

#pragma mark - TSWebControlDelegate

- (void)webDidReceiveTap:(CGPoint)point {
    [self _log:[NSString stringWithFormat:@"[Web] 远程点击 (%.0f,%.0f)", point.x, point.y]];
}

- (void)webDidReceiveScript:(NSString *)script {
    [self _log:[NSString stringWithFormat:@"[Web] 远程脚本 (%lu chars)", (unsigned long)script.length]];
    [[TSScriptEngine shared] runString:script delegate:self];
}

- (void)webDidReceiveStop {
    [[TSScriptEngine shared] stop];
    [self _log:@"[Web] 远程停止"];
}

#pragma mark - TSLogDelegate

- (void)log:(NSString *)message {
    [self _log:message];
}

// 线程安全日志入口(任意线程可调用): 只追加到缓冲, 由 50ms 定时器批量刷新 UI。
// 脚本高频日志时主线程每 50ms 只做一次受限长度的合并刷新, 不会因 O(n) 拼接而假死。
- (void)_log:(NSString *)s {
    if (s.length == 0) return;
    @synchronized (self) {
        if (!_logBuffer) _logBuffer = [NSMutableString string];
        [_logBuffer appendString:s];
        [_logBuffer appendString:@"\n"];
    }
}

// 主线程(50ms 定时器): 取走缓冲 → 合并到全量文本(截断上限) → 一次 setText。
- (void)_flushLogView {
    NSString *chunk = nil;
    @synchronized (self) {
        if (_logBuffer.length == 0) return;
        chunk = [_logBuffer copy];
        [_logBuffer setString:@""];
    }
    if (chunk.length == 0) return;
    if (!_logFull) _logFull = [NSMutableString string];
    [_logFull appendString:chunk];
    // 限制日志最大长度, 超出丢弃最旧部分, 保证每次 setText 成本恒定
    const NSUInteger kMaxLogLen = 200 * 1024;
    if (_logFull.length > kMaxLogLen) {
        [_logFull deleteCharactersInRange:NSMakeRange(0, _logFull.length - kMaxLogLen)];
    }
    self.logView.text = _logFull;
    // 用户手动滚动时不打扰; 其余情况自动跟随最新日志
    if (!self.logView.isDragging && !self.logView.isDecelerating) {
        [self.logView scrollRangeToVisible:NSMakeRange(_logFull.length, 0)];
    }
}

@end
