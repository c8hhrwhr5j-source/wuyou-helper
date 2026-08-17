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
#import "Core/TSInjectedTouchClient.h"
#import "Injected/TSInjectedTouchService.h"

@interface ViewController () <TSLogDelegate, TSWebControlDelegate>
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIImageView *preview;
@property (nonatomic, strong) UIScrollView *scrollView;
@end

@implementation ViewController

// "暂停 Lua"按钮的暂停/继续状态 (音量键面板也会同步更新它)
static BOOL _luaPausedByButton = NO;

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.06 green:0.08 blue:0.12 alpha:1.0];
    [self _buildUI];
    [self _log:@"TrollAutoTouch v2.0 已启动。"];

    // 音量键控制面板事件: 在任意 app(游戏)前台按音量键,
    // SpringBoard 侧注入的 dylib 弹菜单, 用户选择后经 TCP 回调到这里。
    __weak typeof(self) ws2 = self;
    [TSInjectedTouchClient shared].controlEventHandler = ^(uint8_t event) {
        if (event == TS_EVENT_PAUSE) {
            _luaPausedByButton = YES;
            [[TSLuaBridge shared] pause];
            [ws2 _log:@"[音量键] 脚本已暂停"];
        } else if (event == TS_EVENT_RESUME) {
            _luaPausedByButton = NO;
            [[TSLuaBridge shared] resume];
            [ws2 _log:@"[音量键] 脚本已继续"];
        } else if (event == TS_EVENT_STOP) {
            _luaPausedByButton = NO;
            [[TSLuaBridge shared] stop];
            [[TSScriptEngine shared] stop];
            [[TSHUDWindow shared] setScriptRunning:NO];
            [ws2 _log:@"[音量键] 脚本已停止"];
        }
    };

    // 设置 HUD 操作回调
    __weak typeof(self) ws = self;
    [[TSHUDWindow shared] setActionHandler:^(TSHUDAction action) {
        [ws _handleHUDAction:action];
    }];

    // 设置 Web 服务器回调
    [TSHTTPServer shared].delegate = self;
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
        @"暂停 Lua",
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
    }
}

#pragma mark - HUD 操作

- (void)_handleHUDAction:(TSHUDAction)action {
    switch (action) {
        case TSHUDActionToggleScript: {
            if ([TSScriptEngine shared].isRunning) {
                [[TSScriptEngine shared] stop];
                [[TSHUDWindow shared] setScriptRunning:NO];
                [self _log:@"[HUD] 脚本已停止"];
            } else {
                NSString *path = [[NSBundle mainBundle] pathForResource:@"demo" ofType:@"script"];
                if (path) {
                    [[TSScriptEngine shared] runFile:path delegate:self];
                    [[TSHUDWindow shared] setScriptRunning:YES];
                    [self _log:@"[HUD] 脚本已启动"];
                } else {
                    [self _log:@"[HUD] 未找到 demo.script"];
                }
            }
            break;
        }
        case TSHUDActionRecord: {
            if ([TSTouchRecorder shared].isRecording) {
                [[TSTouchRecorder shared] stopRecording];
                [self _log:@"[HUD] 录制已停止"];
            } else {
                [[TSTouchRecorder shared] startRecordingWithInterval:0.016];
                [self _log:@"[HUD] 开始录制触控..."];
            }
            [[TSHUDWindow shared] setRecording:[TSTouchRecorder shared].isRecording];
            break;
        }
        case TSHUDActionPlayRecord: {
            [[TSTouchRecorder shared] playRecordingWithSpeed:1.0];
            [self _log:@"[HUD] 回放录制中..."];
            break;
        }
        case TSHUDActionKeepScreen: {
            [[TSScreenCapture shared] keepPixels];
            [self _log:@"[HUD] 截屏已缓存"];
            break;
        }
        case TSHUDActionScreenshot: {
            UIImage *img = [[TSScreenCapture shared] captureImage];
            if (img) {
                NSDateFormatter *f = [[NSDateFormatter alloc] init];
                f.dateFormat = @"yyyyMMdd_HHmmss";
                NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                    NSUserDomainMask, YES).firstObject
                    stringByAppendingFormat:@"/screenshot_%@.png", [f stringFromDate:[NSDate date]]];
                [UIImagePNGRepresentation(img) writeToFile:path atomically:YES];
                [self _log:[NSString stringWithFormat:@"[HUD] 截屏已保存: %@", path.lastPathComponent]];
            }
            break;
        }
        case TSHUDActionDeviceInfo: {
            [self _log:[NSString stringWithFormat:@"[设备] %@", [[TSDeviceInfo shared] fullInfo]]];
            break;
        }
        case TSHUDActionAppTree: {
            NSString *json = [[TSAppNodeInfo shared] fullTreeJSON];
            [self _log:[NSString stringWithFormat:@"[UI树] %@", [json substringToIndex:MIN(500, json.length)]]];
            break;
        }
        case TSHUDActionStopAll: {
            [[TSScriptEngine shared] stop];
            [[TSHUDWindow shared] setScriptRunning:NO];
            [[TSTouchRecorder shared] stopRecording];
            [[TSTouchRecorder shared] stopPlayback];
            [[TSHUDWindow shared] setRecording:NO];
            [self _log:@"[HUD] 全部已停止"];
            break;
        }
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
    dispatch_async(dispatch_get_main_queue(), ^{
        self.logView.text = [NSString stringWithFormat:@"%@\n%@", self.logView.text ?: @"", message];
    });
}

- (void)_log:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.logView.text = [NSString stringWithFormat:@"%@\n%@", self.logView.text ?: @"", s];
    });
    NSLog(@"[VC] %@", s);
}

@end
