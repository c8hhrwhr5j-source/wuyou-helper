//
//  TSSettingsViewController.m
//  TrollAutoTouch
//
//  设置页：服务开关 (TAS/悬浮窗) + 服务地址 + 设备信息 + 性能面板
//  对齐 TAS 原版设置页布局；浅色主题
//
//  说明:
//    - 远程访问默认常开: 端口随 TAS 服务联动, 不再有独立开关。
//    - 触摸显示已移除: 不再提供该开关及关联代码。
//    - 新增设备信息区: 显示设备信息 / 版本号 / 包名。

#import "TSSettingsViewController.h"
#import "../Views/TSPerformanceMonitorView.h"
#import "../Core/TSToolExecutor.h"
#import "../Core/TSDaemonManager.h"
#import "../Core/TSDeviceInfo.h"
#import "../Script/TSHTTPServer.h"
#import "../Script/TSLuaBridge.h"
#import "../HUD/TSHUDWindow.h"
#import "../HUD/TSHUDHost.h"
#import "../Common/TSPaths.h"
#import "TSLogViewController.h"

// TAS 服务开关的持久化 key。开 → App 启动即运行服务 + 常驻音量键监听;
// 关 → 停止服务/监听, 进后台也不保活。默认开。
static NSString *const kTASServiceEnabledKey = @"TASServiceEnabled";

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

#pragma mark - Info Cell

// 通用"图标 + 标题 + 详情"行: 服务地址 / 设备信息 / 版本号 / 包名
@interface TSInfoCell : UITableViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@end

@implementation TSInfoCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseId {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseId];
    if (self) {
        self.backgroundColor = [TSColors card];
        self.selectionStyle  = UITableViewCellSelectionStyleNone;

        _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.tintColor = [TSColors tint];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_iconView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont systemFontOfSize:15];
        _titleLabel.textColor = [TSColors label];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_titleLabel];

        _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _detailLabel.font = [UIFont systemFontOfSize:13];
        _detailLabel.textColor = [TSColors secondaryLabel];
        _detailLabel.textAlignment = NSTextAlignmentRight;
        _detailLabel.numberOfLines = 0;
        _detailLabel.lineBreakMode = NSLineBreakByCharWrapping;
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_detailLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:22],
            [_iconView.heightAnchor constraintEqualToConstant:22],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:10],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:13],
            [_titleLabel.widthAnchor constraintEqualToConstant:88],

            [_detailLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor constant:8],
            [_detailLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],
            [_detailLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:9],
            [_detailLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-9],
        ]];
        [_titleLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_titleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    }
    return self;
}

@end

#pragma mark - Settings VC

@interface TSSettingsViewController () <UITableViewDelegate, UITableViewDataSource>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) TSPerformanceMonitorView *perfView;

@property (nonatomic, assign) BOOL tasServiceOn;
@property (nonatomic, assign) BOOL floatWindowOn;

@end

@implementation TSSettingsViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        // TAS 服务默认开启: 安装即处于运行保活状态。状态持久化, 重启后保持上次选择。
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        _tasServiceOn = [ud objectForKey:kTASServiceEnabledKey] ? [ud boolForKey:kTASServiceEnabledKey] : YES;
        // 悬浮窗口默认关闭: 用户需要时手动开启
        _floatWindowOn = NO;
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
    _tableView.estimatedRowHeight = 44;
    [_tableView registerClass:[TSSwitchCell class] forCellReuseIdentifier:@"switch"];
    [_tableView registerClass:[TSInfoCell class] forCellReuseIdentifier:@"info"];
    [_tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"action"];
    [_tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"perf"];
    [self.view addSubview:_tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 性能面板现在作为表格中的一行，可能尚未创建
    if (_perfView) [_perfView startUpdating];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (_perfView) [_perfView stopUpdating];
}

#pragma mark - Actions

- (NSString *)_serviceURL {
    NSString *ip = [[TSToolExecutor shared] wifiIPAddress] ?: @"127.0.0.1";
    uint16_t port = [TSHTTPServer shared].port ?: 8080;
    return [NSString stringWithFormat:@"http://%@:%d/", ip, port];
}

- (void)_toggleTAS:(BOOL)on {
    _tasServiceOn = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kTASServiceEnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if (on) {
        // 开启: 启动服务 + 常驻音量键监听 + 远程访问端口(默认常开, 随 TAS 联动)
        [[TSDaemonManager shared] startAll];
        [[TSLuaBridge shared] startGlobalVolumeMonitoring];
        [[TSHTTPServer shared] start];
        [[TSHUDHost shared] showToast:@"TAS 服务已开启" duration:1.2 hidden:NO];
    } else {
        // 关闭: 停止音量键监听 + 停止服务 (含后台保活/心跳) + 关闭远程访问端口
        [[TSLuaBridge shared] stopGlobalVolumeMonitoring];
        [[TSDaemonManager shared] stopAll];
        [[TSHTTPServer shared] stop];
        [[TSHUDHost shared] showToast:@"TAS 服务已关闭" duration:1.2 hidden:NO];
    }
    [_tableView reloadData];
}

- (void)_toggleFloat:(BOOL)on {
    _floatWindowOn = on;
    if (on) {
        [[TSHUDWindow shared] show];
    } else {
        [[TSHUDWindow shared] hide];
    }
}

#pragma mark - 设备信息 / 版本 / 包名

- (NSString *)_deviceInfoDetail {
    TSDeviceInfo *info = [TSDeviceInfo shared];
    NSString *name  = [info deviceName] ?: @"";
    NSString *model = [info modelIdentifier] ?: @"";
    NSString *os    = [NSString stringWithFormat:@"iOS %@", [info osVersion] ?: @""];
    return [NSString stringWithFormat:@"%@\n%@ · %@", name, model, os];
}

- (NSString *)_appVersionDetail {
    NSDictionary *bundle = [NSBundle mainBundle].infoDictionary;
    NSString *v = bundle[@"CFBundleShortVersionString"] ?: @"";
    NSString *b = bundle[@"CFBundleVersion"] ?: @"";
    return b.length ? [NSString stringWithFormat:@"%@ (%@)", v, b] : v;
}

- (NSString *)_bundleIDDetail {
    return [NSBundle mainBundle].bundleIdentifier ?: @"";
}

- (void)_showCopiedToast:(NSString *)text {
    UIPasteboard.generalPasteboard.string = text;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil
                                                               message:@"已复制" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:ac animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ac dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

#pragma mark - TableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 3; // TAS 服务 + 悬浮窗口 + 服务地址
    if (section == 1) return 3; // 通用: 查看脚本日志 + 查看系统日志 + 性能面板
    return 3;                    // 设备信息: 设备 + 版本号 + 包名
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"服务";
    if (section == 1) return @"通用";
    return @"设备信息";
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 1 && ip.row == 2) return 160;
    if (ip.section == 2) return UITableViewAutomaticDimension;
    return 44;
}

- (CGFloat)tableView:(UITableView *)tv estimatedHeightForRowAtIndexPath:(NSIndexPath *)ip {
    return 44;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    // ── 通用区: 查看日志 + 性能面板 ──
    if (ip.section == 1) {
        if (ip.row == 2) {
            // 性能面板: 作为表格行随主界面上下滑动
            UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"perf"];
            c.backgroundColor = [TSColors card];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            if (!_perfView) {
                _perfView = [[TSPerformanceMonitorView alloc]
                             initWithFrame:CGRectMake(0, 0, c.contentView.bounds.size.width, 160)];
                _perfView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            }
            // addSubview 会自动将其从旧父视图移除，cell 复用时不会重复添加
            [c.contentView addSubview:_perfView];
            [_perfView startUpdating];
            return c;
        }

        UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"action"];
        c.backgroundColor = [TSColors card];
        c.textLabel.textColor = [TSColors label];
        c.textLabel.font = [UIFont systemFontOfSize:15];
        if (ip.row == 0) {
            // 查看脚本日志: main.lua 主动 log/logStr/print (debug.log)
            c.textLabel.text = @"查看脚本日志";
            c.imageView.image = [self _icon:@"text.bubble"];
        } else {
            // 查看系统日志: 程序自身日志 (touch.log)
            c.textLabel.text = @"查看系统日志";
            c.imageView.image = [self _icon:@"list.bullet.rectangle"];
        }
        c.imageView.tintColor = [TSColors tint];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        return c;
    }

    // ── 设备信息区 ──
    if (ip.section == 2) {
        TSInfoCell *c = [tv dequeueReusableCellWithIdentifier:@"info"];
        c.detailLabel.font = [UIFont systemFontOfSize:13];
        c.detailLabel.textColor = [TSColors secondaryLabel];
        if (ip.row == 0) {
            c.iconView.image = [self _icon:@"iphone"];
            c.titleLabel.text = @"设备";
            c.detailLabel.text = [self _deviceInfoDetail];
        } else if (ip.row == 1) {
            c.iconView.image = [self _icon:@"number"];
            c.titleLabel.text = @"版本";
            c.detailLabel.text = [self _appVersionDetail];
            c.detailLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
        } else {
            c.iconView.image = [self _icon:@"shippingbox"];
            c.titleLabel.text = @"包名";
            c.detailLabel.text = [self _bundleIDDetail];
            c.detailLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        }
        return c;
    }

    // ── 服务区: TAS 服务 / 悬浮窗口 / 服务地址 ──
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
        c.iconView.image = [self _icon:@"rectangle.on.rectangle"];
        c.titleLabel.text = @"悬浮窗口";
        [c.sw setOn:_floatWindowOn animated:NO];
        __weak typeof(self) ws = self;
        c.onToggle = ^(BOOL on) { [ws _toggleFloat:on]; };
        return c;
    } else {
        TSInfoCell *c = [tv dequeueReusableCellWithIdentifier:@"info"];
        c.iconView.image = [self _icon:@"globe"];
        c.titleLabel.text = @"服务地址";
        c.detailLabel.text = [self _serviceURL];
        c.detailLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        c.detailLabel.textColor = [TSColors tint];
        return c;
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 1) {
        if (ip.row == 2) return; // 性能面板行
        // row0 = 查看脚本日志(debug.log), row1 = 查看系统日志(touch.log)
        TSLogViewController *vc = [[TSLogViewController alloc]
                                   initWithMode:(ip.row == 0 ? @"script" : @"system")];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }

    if (ip.section == 0 && ip.row == 2) {
        [self _showCopiedToast:[self _serviceURL]];
        return;
    }

    if (ip.section == 2) {
        NSString *copy = nil;
        if (ip.row == 0)      copy = [self _deviceInfoDetail];
        else if (ip.row == 1) copy = [self _appVersionDetail];
        else                  copy = [self _bundleIDDetail];
        [self _showCopiedToast:copy];
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
