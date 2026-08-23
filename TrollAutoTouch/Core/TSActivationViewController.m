//
//  TSActivationViewController.m
//  TrollAutoTouch
//

#import "TSActivationViewController.h"
#import "TSLicense.h"

@interface TSActivationViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *cardField;
@property (nonatomic, strong) UIButton *activateButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation TSActivationViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupUI];
    if (self.initialMessage.length) {
        [self showStatus:self.initialMessage isError:YES];
    }
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

// MARK: - UI

- (void)setupUI {
    self.view.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.09 alpha:1.0];

    UILabel *title = [UILabel new];
    title.text = @"TrollAutoTouch";
    title.font = [UIFont boldSystemFontOfSize:26];
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    UILabel *subtitle = [UILabel new];
    subtitle.text = @"输入卡密激活后使用\n卡密请向作者购买";
    subtitle.font = [UIFont systemFontOfSize:14];
    subtitle.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 2;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:subtitle];

    UITextField *field = [UITextField new];
    field.placeholder = @"请输入卡密";
    field.font = [UIFont systemFontOfSize:17];
    field.textColor = [UIColor whiteColor];
    field.textAlignment = NSTextAlignmentCenter;
    field.keyboardType = UIKeyboardTypeASCIICapable;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.returnKeyType = UIReturnKeyDone;
    field.delegate = self;
    field.layer.cornerRadius = 10;
    field.layer.borderWidth = 1;
    field.layer.borderColor = [UIColor colorWithWhite:0.30 alpha:1.0].CGColor;
    field.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1.0];
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    // placeholder 颜色
    NSAttributedString *ph = [[NSAttributedString alloc]
        initWithString:@"请输入卡密"
        attributes:@{NSForegroundColorAttributeName:
                         [UIColor colorWithWhite:0.45 alpha:1.0]}];
    field.attributedPlaceholder = ph;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:field];
    self.cardField = field;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"激 活" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    btn.backgroundColor = [UIColor colorWithRed:0.16 green:0.46 blue:0.96 alpha:1.0];
    btn.layer.cornerRadius = 10;
    [btn addTarget:self action:@selector(onActivateTap) forControlEvents:UIControlEventTouchUpInside];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:btn];
    self.activateButton = btn;

    UILabel *status = [UILabel new];
    status.font = [UIFont systemFontOfSize:14];
    status.textColor = [UIColor colorWithRed:1.0 green:0.38 blue:0.38 alpha:1.0];
    status.textAlignment = NSTextAlignmentCenter;
    status.numberOfLines = 0;
    status.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:status];
    self.statusLabel = status;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    spinner.hidesWhenStopped = YES;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:spinner];
    self.spinner = spinner;

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:guide.topAnchor constant:160],
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [subtitle.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [subtitle.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:40],
        [subtitle.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-40],

        [field.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:50],
        [field.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:40],
        [field.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-40],
        [field.heightAnchor constraintEqualToConstant:48],

        [btn.topAnchor constraintEqualToAnchor:field.bottomAnchor constant:24],
        [btn.leadingAnchor constraintEqualToAnchor:field.leadingAnchor],
        [btn.trailingAnchor constraintEqualToAnchor:field.trailingAnchor],
        [btn.heightAnchor constraintEqualToConstant:48],

        [spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [spinner.topAnchor constraintEqualToAnchor:btn.bottomAnchor constant:20],

        [status.topAnchor constraintEqualToAnchor:btn.bottomAnchor constant:16],
        [status.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:40],
        [status.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-40],
    ]];

    // 点击空白处收起键盘
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onBackgroundTap)];
    [self.view addGestureRecognizer:tap];
}

// MARK: - Actions

- (void)onBackgroundTap {
    [self.view endEditing:YES];
}

- (void)onActivateTap {
    [self.view endEditing:YES];
    NSString *card = [self.cardField.text
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (card.length == 0) {
        [self showStatus:@"请输入卡密" isError:YES];
        return;
    }
    [self setBusy:YES];
    __weak typeof(self) weakSelf = self;
    [[TSLicense shared] activateWithCard:card completion:^(BOOL ok, NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self setBusy:NO];
            if (ok) {
                [self showStatus:@"激活成功" isError:NO];
                if (self.onActivated) self.onActivated();
            } else {
                [self showStatus:msg.length ? msg : @"激活失败, 请检查卡密" isError:YES];
            }
        });
    }];
}

// MARK: - 状态

- (void)showStatus:(NSString *)text isError:(BOOL)isError {
    self.statusLabel.text = text;
    self.statusLabel.textColor = isError
        ? [UIColor colorWithRed:1.0 green:0.38 blue:0.38 alpha:1.0]
        : [UIColor colorWithRed:0.30 green:0.85 blue:0.45 alpha:1.0];
}

- (void)setBusy:(BOOL)busy {
    self.activateButton.enabled = !busy;
    self.cardField.enabled = !busy;
    if (busy) {
        [self.spinner startAnimating];
    } else {
        [self.spinner stopAnimating];
    }
}

// MARK: - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self onActivateTap];
    return YES;
}

@end
