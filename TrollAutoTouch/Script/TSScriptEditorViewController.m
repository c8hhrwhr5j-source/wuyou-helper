//
//  TSScriptEditorViewController.m
//  TrollAutoTouch
//
//  全屏 Lua 文本编辑器（替代原弹窗式编辑）
//  界面: 全屏 UITextView + 导航栏右上角"保存" / 左上角"取消"
//  保存: 写回文件并退出; 取消: 放弃所有修改并退出。
//

#import "TSScriptEditorViewController.h"
#import "../Core/TSToolExecutor.h"
#import "../Common/TSPaths.h"

@interface TSScriptEditorViewController ()

@property (nonatomic, strong) UITextView *textView;

@end

@implementation TSScriptEditorViewController

- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        self.hidesBottomBarWhenPushed = YES; // 隐藏底部 tab bar, 全屏展示
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [TSColors bg];

    UILabel *title = [[UILabel alloc] init];
    title.text = self.filePath.lastPathComponent;
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textColor = [TSColors label];
    [title sizeToFit];
    self.navigationItem.titleView = title;

    // 左上角: 取消（放弃修改并退出）
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
                                             initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                             target:self action:@selector(_cancel)];
    // 右上角: 保存
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
                                              initWithTitle:@"保存" style:UIBarButtonItemStyleDone
                                              target:self action:@selector(_save)];

    // ── 全屏文本编辑区 ──
    _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _textView.backgroundColor = [TSColors bg];
    _textView.textColor = [TSColors label];
    _textView.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    _textView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _textView.alwaysBounceVertical = YES;
    [self.view addSubview:_textView];

    _textView.text = [[TSToolExecutor shared] readTextFile:self.filePath] ?: @"";
    [_textView becomeFirstResponder];
}

#pragma mark - Actions

- (void)_cancel {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)_save {
    NSString *content = _textView.text ?: @"";
    if ([[TSToolExecutor shared] writeTextFile:self.filePath content:content]) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"保存失败"
                                                                    message:@"无法写入文件"
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

@end
