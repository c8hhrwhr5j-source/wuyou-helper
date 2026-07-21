/**
 *  ViewController.m
 *  触控精灵主界面
 *
 *  布局:
 *   顶部: 状态栏 + 脚本控制按钮 (运行/暂停/停止)
 *   上部: 脚本编辑器
 *   下部: 运行日志面板
 */

#import "ViewController.h"
#import "ScriptEngine.h"
#import <UIKit/UIKit.h>

// ---- 颜色定义 ----
#define COLOR_BG        [UIColor colorWithWhite:0.08 alpha:1.0]
#define COLOR_SURFACE   [UIColor colorWithWhite:0.14 alpha:1.0]
#define COLOR_ACCENT    [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0]
#define COLOR_DANGER    [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:1.0]
#define COLOR_WARN      [UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:1.0]
#define COLOR_SUCCESS   [UIColor colorWithRed:0.2 green:0.8 blue:0.3 alpha:1.0]
#define COLOR_TEXT       [UIColor whiteColor]
#define COLOR_TEXT_DIM   [UIColor colorWithWhite:0.6 alpha:1.0]

@interface ViewController () <UITextViewDelegate>

// 控制栏
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *runBtn;
@property (nonatomic, strong) UIButton *pauseBtn;
@property (nonatomic, strong) UIButton *stopBtn;

// 编辑器
@property (nonatomic, strong) UITextView *editor;
@property (nonatomic, strong) UIButton *loadExampleBtn;

// 日志
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *clearLogBtn;

// 悬浮取色窗
@property (nonatomic, strong) UILabel *colorPickerLabel;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = COLOR_BG;

    [self _setupUI];
    [self _setupScriptEngine];
}

#pragma mark - UI Setup

- (void)_setupUI {
    CGFloat topY = 44;  // 状态栏下
    CGFloat pad = 12;

    // ---- 状态标签 ----
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, topY, self.view.bounds.size.width - pad*2, 24)];
    _statusLabel.text = @"● 就绪";
    _statusLabel.textColor = COLOR_TEXT_DIM;
    _statusLabel.font = [UIFont systemFontOfSize:14];
    [self.view addSubview:_statusLabel];
    topY += 30;

    // ---- 控制按钮 ----
    CGFloat btnW = (self.view.bounds.size.width - pad * 4) / 3;
    CGFloat btnH = 40;

    _runBtn = [self _makeButton:@"▶ 运行" color:COLOR_SUCCESS frame:CGRectMake(pad, topY, btnW, btnH)];
    [_runBtn addTarget:self action:@selector(_onRun) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_runBtn];

    _pauseBtn = [self _makeButton:@"⏸ 暂停" color:COLOR_WARN frame:CGRectMake(pad*2 + btnW, topY, btnW, btnH)];
    [_pauseBtn addTarget:self action:@selector(_onPause) forControlEvents:UIControlEventTouchUpInside];
    _pauseBtn.enabled = NO;
    [self.view addSubview:_pauseBtn];

    _stopBtn = [self _makeButton:@"⏹ 停止" color:COLOR_DANGER frame:CGRectMake(pad*3 + btnW*2, topY, btnW, btnH)];
    [_stopBtn addTarget:self action:@selector(_onStop) forControlEvents:UIControlEventTouchUpInside];
    _stopBtn.enabled = NO;
    [self.view addSubview:_stopBtn];
    topY += btnH + pad;

    // ---- 加载示例按钮 ----
    _loadExampleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _loadExampleBtn.frame = CGRectMake(pad, topY, 120, 28);
    [_loadExampleBtn setTitle:@"📄 加载示例" forState:UIControlStateNormal];
    _loadExampleBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [_loadExampleBtn setTitleColor:COLOR_ACCENT forState:UIControlStateNormal];
    [_loadExampleBtn addTarget:self action:@selector(_onLoadExample) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_loadExampleBtn];
    topY += 32;

    // ---- 脚本编辑器 ----
    CGFloat editorH = (self.view.bounds.size.height - topY) * 0.48;
    _editor = [[UITextView alloc] initWithFrame:CGRectMake(pad, topY, self.view.bounds.size.width - pad*2, editorH)];
    _editor.backgroundColor = COLOR_SURFACE;
    _editor.textColor = COLOR_TEXT;
    _editor.font = [UIFont fontWithName:@"Menlo" size:13];
    _editor.autocorrectionType = UITextAutocorrectionTypeNo;
    _editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _editor.layer.cornerRadius = 8;
    _editor.layer.borderWidth = 1;
    _editor.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:1.0].CGColor;
    _editor.text = @"-- 在此输入 Lua 脚本\n-- 点击「加载示例」查看模板";
    [self.view addSubview:_editor];
    topY += editorH + pad;

    // ---- 清除日志按钮 ----
    _clearLogBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _clearLogBtn.frame = CGRectMake(pad, topY, 100, 24);
    [_clearLogBtn setTitle:@"🗑 清除日志" forState:UIControlStateNormal];
    _clearLogBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [_clearLogBtn setTitleColor:COLOR_TEXT_DIM forState:UIControlStateNormal];
    [_clearLogBtn addTarget:self action:@selector(_onClearLog) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_clearLogBtn];
    topY += 28;

    // ---- 日志面板 ----
    CGFloat logH = self.view.bounds.size.height - topY - 20;
    _logView = [[UITextView alloc] initWithFrame:CGRectMake(pad, topY, self.view.bounds.size.width - pad*2, logH)];
    _logView.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
    _logView.textColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.3 alpha:1.0]; // 终端绿
    _logView.font = [UIFont fontWithName:@"Menlo" size:11];
    _logView.editable = NO;
    _logView.layer.cornerRadius = 8;
    _logView.layer.borderWidth = 1;
    _logView.layer.borderColor = [UIColor colorWithWhite:0.2 alpha:1.0].CGColor;
    _logView.text = @"--- 触控精灵 运行日志 ---\n";
    [self.view addSubview:_logView];
}

- (UIButton *)_makeButton:(NSString *)title color:(UIColor *)color frame:(CGRect)frame {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = frame;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor colorWithWhite:0.6 alpha:1.0] forState:UIControlStateDisabled];
    btn.backgroundColor = [color colorWithAlphaComponent:0.25];
    btn.layer.cornerRadius = 8;
    btn.layer.borderWidth = 1;
    btn.layer.borderColor = [color colorWithAlphaComponent:0.5].CGColor;
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    return btn;
}

#pragma mark - ScriptEngine 绑定

- (void)_setupScriptEngine {
    ScriptEngine *engine = [ScriptEngine shared];

    __weak typeof(self) ws = self;
    engine.logHandler = ^(NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws _appendLog:msg];
        });
    };
    engine.stateChangeHandler = ^(ScriptState state) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws _updateUIForState:state];
        });
    };
}

#pragma mark - 按钮事件

- (void)_onRun {
    NSString *code = _editor.text;
    if (code.length == 0) {
        [self _appendLog:@"⚠️ 脚本为空，无法运行"];
        return;
    }
    [_logView setText:@"--- 运行日志 ---\n"];

    [[ScriptEngine shared] runScript:code];
}

- (void)_onPause {
    ScriptEngine *e = [ScriptEngine shared];
    if (e.state == ScriptStateRunning) {
        [e pause];
    } else if (e.state == ScriptStatePaused) {
        [e resume];
    }
}

- (void)_onStop {
    [[ScriptEngine shared] stop];
}

- (void)_onClearLog {
    [_logView setText:@"--- 运行日志 ---\n"];
}

- (void)_onLoadExample {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"test_script" ofType:@"lua"];
    if (path) {
        NSError *err;
        NSString *code = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
        if (code) {
            _editor.text = code;
            [self _appendLog:@"✅ 已加载示例脚本"];
        } else {
            [self _appendLog:[NSString stringWithFormat:@"❌ 加载失败: %@", err.localizedDescription]];
        }
    } else {
        // 硬编码的示例脚本
        NSString *example =
        @"-- 触控精灵 测试脚本\n"
        @"log(\"========== 脚本启动 ==========\")\n"
        @"local w, h = get_screen_size()\n"
        @"log(\"屏幕: \"..w..\"x\"..h)\n"
        @"\n"
        @"local r, g, b = get_screen_color(w/2, h/2)\n"
        @"log(\"中心像素: (\"..r..\",\"..g..\",\"..b..\")\")\n"
        @"\n"
        @"-- 查找白色像素\n"
        @"local tx, ty = find_color(100,200,500,800, 255,255,255, 90)\n"
        @"log(\"找色结果: (\"..tx..\",\"..ty..\")\")\n"
        @"\n"
        @"if tx > 0 then\n"
        @"    click(tx, ty)\n"
        @"    log(\"已点击\")\n"
        @"end\n"
        @"\n"
        @"log(\"========== 脚本结束 ==========\")";
        _editor.text = example;
        [self _appendLog:@"✅ 已加载内置示例脚本"];
    }
}

#pragma mark - UI 状态更新

- (void)_updateUIForState:(ScriptState)state {
    switch (state) {
        case ScriptStateIdle:
            _statusLabel.text = @"● 就绪";
            _statusLabel.textColor = COLOR_TEXT_DIM;
            _runBtn.enabled = YES;
            _pauseBtn.enabled = NO;
            [_pauseBtn setTitle:@"⏸ 暂停" forState:UIControlStateNormal];
            _stopBtn.enabled = NO;
            _editor.editable = YES;
            break;
        case ScriptStateRunning:
            _statusLabel.text = @"● 运行中...";
            _statusLabel.textColor = COLOR_SUCCESS;
            _runBtn.enabled = NO;
            _pauseBtn.enabled = YES;
            [_pauseBtn setTitle:@"⏸ 暂停" forState:UIControlStateNormal];
            _stopBtn.enabled = YES;
            _editor.editable = NO;
            break;
        case ScriptStatePaused:
            _statusLabel.text = @"⏸ 已暂停";
            _statusLabel.textColor = COLOR_WARN;
            _runBtn.enabled = NO;
            _pauseBtn.enabled = YES;
            [_pauseBtn setTitle:@"▶ 继续" forState:UIControlStateNormal];
            _stopBtn.enabled = YES;
            _editor.editable = NO;
            break;
        case ScriptStateStopping:
            _statusLabel.text = @"● 停止中...";
            _statusLabel.textColor = COLOR_DANGER;
            _runBtn.enabled = NO;
            _pauseBtn.enabled = NO;
            _stopBtn.enabled = NO;
            _editor.editable = NO;
            break;
    }
}

- (void)_appendLog:(NSString *)msg {
    NSString *line = [NSString stringWithFormat:@"%@\n", msg];
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:line];
    [attr addAttribute:NSForegroundColorAttributeName
                 value:_logView.textColor
                 range:NSMakeRange(0, line.length)];
    [_logView.textStorage appendAttributedString:attr];

    // 自动滚动到底部
    NSRange bottom = NSMakeRange(_logView.textStorage.length - 1, 1);
    [_logView scrollRangeToVisible:bottom];
}

@end
