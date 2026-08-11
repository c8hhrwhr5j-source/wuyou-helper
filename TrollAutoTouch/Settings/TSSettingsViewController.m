//
//  TSSettingsViewController.m
//  TrollAutoTouch
//
//  设置页：服务开关 (TAS/远程访问/触摸显示/悬浮窗) + 服务地址 + 性能面板
//  对齐 TAS 原版设置页布局；浅色主题
//

#import "TSSettingsViewController.h"
#import "../Views/TSPerformanceMonitorView.h"
#import "../Core/TSToolExecutor.h"
#import "../Script/TSHTTPServer.h"
#import "../HUD/TSHUDWindow.h"
#import "../Common/TSPaths.h"

#pragma mark - Switch Cell

@interface TSSwitchCell : UITableViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UISwitch *sw;
@property (nonatomic, copy)   void (^onToggle)(BOOL on);
@end

@implementation TSSwitchCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseId {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseId];
    if (self) {
        self.backgroundColor = [TSColors card];
        self.selectionStyle  = UITableViewCellSelectionStyleNone;

        _iconView = [[UIImageView alloc] initWithFrame:CGRectMake(14, 11, 22, 22)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.tintColor = [TSColors tint];
        [self.contentView addSubview:_iconView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(46, 12, 200, 20)];
        _titleLabel.font = [UIFont systemFontOfSize:15];
        _titleLabel.textColor = [TSColors label];
        [self.contentView addSubview:_titleLabel];

        _sw = [[UISwitch alloc] initWithFrame:CGRectZero];
        _sw.onTintColor = [TSColors switchOn];
        [self.contentView addSubview:_sw];

        [_sw addTarget:self action:@selector(_toggled:) forControlEvents:UIControlEventValueChanged];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize sz = [_sw sizeThatFits:CGSizeZero];
    _sw.frame = CGRectMake(self.contentView.bounds.size.width - sz.width - 14, 8, sz.width, sz.height);
}

- (void)_toggled:(UISwitch *)sender {
    if (_onToggle) _onToggle(sender.isOn);
}

@end

#pragma mark - URL Cell

@interface TSURLInfoCell : UITableViewCell
@property (nonatomic, strong) UILabel *urlLabel;
@end

@implementation TSURLInfoCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseId {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseId];
    if (self) {
        self.backgroundColor = [TSColors card];
        self.selectionStyle  = UITableViewCellSelectionStyleNone;

        _urlLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, 300, 44)];
        _urlLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        _urlLabel.textColor = [TSColors tint];
        _urlLabel.textAlignment = NSTextAlignmentLeft;
        _urlLabel.numberOfLines = 0;
        [self.contentView addSubview:_urlLabel];
    }
    return self;
}

@end

#pragma mark - Settings VC

@interface TSSettingsViewController () <UITableViewDelegate, UITableViewDataSource>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) TSPerformanceMonitorView *perfView;

@property (nonatomic, assign) BOOL tasServiceOn;
@property (nonatomic, assign) BOOL remoteAccessOn;
@property (nonatomic, assign) BOOL touchDisplayOn;
@property (nonatomic, assign) BOOL floatWindowOn;

@end

@implementation TSSettingsViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        _tasServiceOn    = NO;
        _remoteAccessOn  = NO;
        _touchDisplayOn  = NO;
        _floatWindowOn   = YES;
    }
    return self;
}

- (void)loadView {
    [super loadView];
    self.view.backgroundColor = [TSColors bg];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"设置";
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textColor = [TSColors label];
    [title sizeToFit];
    self.navigationItem.titleView = title;

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.backgroundColor  = [TSColors bg];
    _tableView.delegate   = self;
    _tableView.dataSource = self;
    _tableView.rowHeight  = 44;
    [_tableView registerClass:[TSSwitchCell class] forCellReuseIdentifier:@"switch"];
    [_tableView registerClass:[TSURLInfoCell class] forCellReuseIdentifier:@"url"];
    [self.view addSubview:_tableView];

    // 性能面板 (浅色背景)
    CGFloat perfH = 160;
    UIView *perfContainer = [[UIView alloc] initWithFrame:
        CGRectMake(8, self.view.bounds.size.height - perfH - 48 - 34, self.view.bounds.size.width - 16, perfH)];
    perfContainer.backgroundColor = [TSColors card];
    perfContainer.layer.cornerRadius = 12;
    perfContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:perfContainer];

    _perfView = [[TSPerformanceMonitorView alloc] initWithFrame:CGRectMake(0, 0, perfContainer.bounds.size.width, perfContainer.bounds.size.height)];
    _perfView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [perfContainer addSubview:_perfView];

    _tableView.contentInset = UIEdgeInsetsMake(0, 0, perfH + 24, 0);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [_perfView startUpdating];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_perfView stopUpdating];
}

#pragma mark - Actions

- (NSString *)_serviceURL {
    NSString *ip = [[TSToolExecutor shared] wifiIPAddress] ?: @"127.0.0.1";
    uint16_t port = [TSHTTPServer shared].port ?: 8080;
    return [NSString stringWithFormat:@"http://%@:%d/", ip, port];
}

- (void)_toggleTAS:(BOOL)on {
    _tasServiceOn = on;
    [_tableView reloadData];
}

- (void)_toggleRemote:(BOOL)on {
    _remoteAccessOn = on;
    if (on) {
        [[TSHTTPServer shared] start];
    } else {
        [[TSHTTPServer shared] stop];
    }
    [_tableView reloadData];
}

- (void)_toggleTouch:(BOOL)on {
    _touchDisplayOn = on;
}

- (void)_toggleFloat:(BOOL)on {
    _floatWindowOn = on;
    if (on) {
        [[TSHUDWindow shared] show];
    } else {
        [[TSHUDWindow shared] hide];
    }
}

#pragma mark - TableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return _tasServiceOn ? 5 : 1;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    return @"服务";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row == 0) {
        TSSwitchCell *c = [tv dequeueReusableCellWithIdentifier:@"switch"];
        c.iconView.image = [self _icon:@"bolt.fill"];
        c.titleLabel.text = @"TAS 服务";
        [c.sw setOn:_tasServiceOn animated:NO];
        __weak typeof(self) ws = self;
        c.onToggle = ^(BOOL on) { [ws _toggleTAS:on]; };
        return c;
    } else if (ip.row == 1) {
        TSSwitchCell *c = [tv dequeueReusableCellWithIdentifier:@"switch"];
        c.iconView.image = [self _icon:@"globe"];
        c.titleLabel.text = @"远程访问";
        [c.sw setOn:_remoteAccessOn animated:NO];
        __weak typeof(self) ws = self;
        c.onToggle = ^(BOOL on) { [ws _toggleRemote:on]; };
        return c;
    } else if (ip.row == 2) {
        TSSwitchCell *c = [tv dequeueReusableCellWithIdentifier:@"switch"];
        c.iconView.image = [self _icon:@"hand.point.up.fill"];
        c.titleLabel.text = @"触摸显示";
        [c.sw setOn:_touchDisplayOn animated:NO];
        __weak typeof(self) ws = self;
        c.onToggle = ^(BOOL on) { [ws _toggleTouch:on]; };
        return c;
    } else if (ip.row == 3) {
        TSSwitchCell *c = [tv dequeueReusableCellWithIdentifier:@"switch"];
        c.iconView.image = [self _icon:@"rectangle.on.rectangle"];
        c.titleLabel.text = @"悬浮窗口";
        [c.sw setOn:_floatWindowOn animated:NO];
        __weak typeof(self) ws = self;
        c.onToggle = ^(BOOL on) { [ws _toggleFloat:on]; };
        return c;
    } else {
        TSURLInfoCell *c = [tv dequeueReusableCellWithIdentifier:@"url"];
        c.urlLabel.text = [self _serviceURL];
        return c;
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row == 4) {
        UIPasteboard.generalPasteboard.string = [self _serviceURL];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil
                                                                   message:@"已复制" preferredStyle:UIAlertControllerStyleAlert];
        [self presentViewController:ac animated:YES completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [ac dismissViewControllerAnimated:YES completion:nil];
            });
        }];
    }
}

- (UIImage *)_icon:(NSString *)name {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16
                                                                                         weight:UIImageSymbolWeightMedium];
        return [[UIImage systemImageNamed:name] imageByApplyingSymbolConfiguration:cfg];
    }
    return nil;
}

@end