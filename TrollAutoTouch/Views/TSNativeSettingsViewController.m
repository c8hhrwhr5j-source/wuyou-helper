//
//  TSNativeSettingsViewController.m
//  TrollAutoTouch
//
//  UIKit 原生设置页实现: UITableView 分组列表 + 各类型控件 cell。
//  16 种 row 类型对应 16 套 cell 子视图, 单一 TSSettingsCell 复用,
//  prepareForReuse 重置, 按 type 应用子视图 (可见性 + frame + 事件)。
//
//  数据流:
//    initWithSchema:  -> 内部 schema
//    viewDidLoad:     -> 从 settings.json 读初值填 currentValue; 渲染
//    用户操作:        -> cell 直接改 row.currentValue, 触发依赖重算
//    底部 [保存]/[保存运行]/[取消]:
//                     -> 收集 currentValue -> NSDictionary -> 写 settings.json
//                     -> onFinish(didRun) 通知上层 l_ui_open 走与 HTML 版相同的
//                        注入 + 启动脚本 / 取消流程
//

#import "TSNativeSettingsViewController.h"
#import "TSPaths.h"
#import "TSHUDHost.h"
#import "TSLuaBridge.h"
#import "TSLogStore.h"
#import <objc/runtime.h>
#import "lua.h"
#import "lauxlib.h"   // LUA_NOREF (-2) / LUA_REFNIL 在此头

// 桥接函数 (定义在 TSLuaBridge.m, 通过 _tsCurrentLuaState 访问 Lua 栈)
extern void TSLuaInvokeActionWithCurrentSettings(int ref, NSDictionary *settingsDict);
extern void TSLuaUnrefAction(int ref);

#pragma mark - Cell delegate 协议
// TSSettingsCell 只能通过此协议访问 view controller, 避免 cell 文件需要 import
// view controller 的 class extension (解耦)
@protocol TSNativeSettingsCellDelegate <NSObject>
- (void)refreshAfterValueChange;
- (void)openSubListForRow:(TSSettingsRow *)row;
- (void)invokeActionForRow:(TSSettingsRow *)row;
@end

#pragma mark - 辅助

static NSString *TSColorHexFromUIColor(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        // 灰度颜色
        CGFloat w = 0;
        if ([color getWhite:&w alpha:&a]) { r = g = b = w; }
    }
    return [NSString stringWithFormat:@"#%02X%02X%02X",
            (int)round(r * 255), (int)round(g * 255), (int)round(b * 255)];
}

static UIColor *TSUIColorFromHex(NSString *hex) {
    if (hex.length == 0) return [UIColor blackColor];
    NSString *s = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (s.length != 6) return [UIColor blackColor];
    unsigned int v = 0;
    NSScanner *scanner = [NSScanner scannerWithString:s];
    if (![scanner scanHexInt:&v]) return [UIColor blackColor];
    CGFloat r = ((v >> 16) & 0xFF) / 255.0;
    CGFloat g = ((v >>  8) & 0xFF) / 255.0;
    CGFloat b = ( v        & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:1];
}

static NSString *TSFormatNumber(double v, NSString *format) {
    if (format.length == 0) {
        if (fabs(v - (int)v) < 1e-9) return [NSString stringWithFormat:@"%d", (int)v];
        return [NSString stringWithFormat:@"%g", v];
    }
    return [NSString stringWithFormat:format, v];
}

static id _Nullable TSValueForKey(TSSettingsRow *row) {
    return row.currentValue ?: row.defaultValue;
}

static BOOL TSValueEqual(id a, id b) {
    if (a == b) return YES;
    if (!a || !b) return NO;
    if ([a isKindOfClass:[NSNumber class]] && [b isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)a doubleValue] == [(NSNumber *)b doubleValue];
    }
    return [a isEqual:b];
}

#pragma mark - 单选/多选子页面

/// 单选列表 (从 options 里选一项, 写入 row.currentValue = 选中字符串)
@interface TSSelectListVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, weak) TSSettingsRow *row;
@property (nonatomic, weak) id<TSNativeSettingsCellDelegate> parent;
@property (nonatomic, strong) UITableView *tableView;
@end

@implementation TSSelectListVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.row.label;
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return self.row.options.count;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"c";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    NSString *opt = self.row.options[ip.row];
    cell.textLabel.text = opt;
    id cur = TSValueForKey(self.row);
    cell.accessoryType = TSValueEqual(cur, opt) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    self.row.currentValue = self.row.options[ip.row];
    [self.parent refreshAfterValueChange];
    [self.navigationController popViewControllerAnimated:YES];
}
@end

/// 多选列表 (子页面勾选多个, 完成时写回 array)
@interface TSMultiListVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, weak) TSSettingsRow *row;
@property (nonatomic, weak) id<TSNativeSettingsCellDelegate> parent;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableSet<NSString *> *selected;
@end

@implementation TSMultiListVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.row.label;
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    // 完成按钮
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(_onDone)];

    id cur = TSValueForKey(self.row);
    self.selected = [NSMutableSet set];
    if ([cur isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)cur) {
            if ([v isKindOfClass:[NSString class]]) [self.selected addObject:v];
        }
    }
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return self.row.multiOptions.count;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"c";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    NSString *opt = self.row.multiOptions[ip.row];
    cell.textLabel.text = opt;
    cell.accessoryType = [self.selected containsObject:opt]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *opt = self.row.multiOptions[ip.row];
    if ([self.selected containsObject:opt]) {
        [self.selected removeObject:opt];
    } else {
        [self.selected addObject:opt];
    }
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)_onDone {
    self.row.currentValue = [self.selected allObjects];
    [self.parent refreshAfterValueChange];
    [self.navigationController popViewControllerAnimated:YES];
}
@end

#pragma mark - Cell

@interface TSSettingsCell : UITableViewCell <UITextFieldDelegate>

// 左侧标题
@property (nonatomic, strong) UILabel *titleLabel;
// 各类型控件
@property (nonatomic, strong) UISwitch *switchView;
@property (nonatomic, strong) UIButton *checkboxView;   // 复选框 (右侧色块, 选中=蓝色填充)
@property (nonatomic, strong) UIView *chipContainer;    // checkGroup 的色块容器
@property (nonatomic, strong) NSMutableArray<UIButton *> *chipButtons; // 当前色块按钮
@property (nonatomic, strong) UIStepper *stepperView;
@property (nonatomic, strong) UILabel *stepperValueLabel;
@property (nonatomic, strong) UISlider *sliderView;
@property (nonatomic, strong) UILabel *sliderValueLabel;
@property (nonatomic, strong) UISegmentedControl *segmentedView;
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIDatePicker *datePicker;
@property (nonatomic, strong) UIButton *disclosureButton;
@property (nonatomic, strong) UIView *colorSwatch;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UILabel *hintLabel;     // 提示/警告

@property (nonatomic, weak) TSSettingsRow *row;
@property (nonatomic, weak) id<TSNativeSettingsCellDelegate> vc;

@end

@implementation TSSettingsCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:15];
        _titleLabel.textColor = [UIColor labelColor];
        [self.contentView addSubview:_titleLabel];

        _hintLabel = [[UILabel alloc] init];
        _hintLabel.font = [UIFont systemFontOfSize:11];
        _hintLabel.textColor = [UIColor systemRedColor];
        _hintLabel.numberOfLines = 0;
        _hintLabel.hidden = YES;
        [self.contentView addSubview:_hintLabel];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // 子控件全部懒创建, 复用前可能只有一个被创建过 —— 其余是 nil。
    // ⚠️ 不能用 @[...] 数组字面量收集: 含 nil 会直接抛 NSInvalidArgumentException
    //    (attempt to insert nil object) → SIGABRT 整个 App 闪退 (点/滑动列表触发复用即崩)。
    //    改用 C 数组 + **逐个判空**遍历。
    // ⚠️ 历史 bug: 循环条件写成 `i < count && lazyViews[i]`, 第 0 个元素为 nil 时
    //    整个循环立即退出 → 旧 cell 的控件全都没被隐藏 → 新行叠旧行"重影"
    //    (复选框 ✓ 出现在 segmented/info 行上, info 文字叠在 50pt 行上)。
    //    必须遍历完整长度, 每个元素单独判空。
    UIView *lazyViews[] = {
        self.switchView, self.checkboxView, self.stepperView, self.stepperValueLabel,
        self.sliderView, self.sliderValueLabel, self.segmentedView,
        self.textField, self.textView, self.datePicker,
        self.disclosureButton, self.colorSwatch, self.actionButton,
        self.infoLabel, self.chipContainer, nil,
    };
    for (NSUInteger i = 0; i < sizeof(lazyViews) / sizeof(lazyViews[0]); i++) {
        if (lazyViews[i]) lazyViews[i].hidden = YES;
    }
    self.hintLabel.hidden = YES;
    self.hintLabel.text = nil;
}

- (void)_ensureSwitch {
    if (!self.switchView) {
        self.switchView = [[UISwitch alloc] init];
        [self.switchView addTarget:self action:@selector(_onSwitchChange) forControlEvents:UIControlEventValueChanged];
        [self.contentView addSubview:self.switchView];
    }
    self.switchView.hidden = NO;
}
- (void)_ensureCheckbox {
    if (!self.checkboxView) {
        self.checkboxView = [UIButton buttonWithType:UIButtonTypeCustom];
        self.checkboxView.layer.cornerRadius = 7;
        self.checkboxView.layer.borderWidth = 1.5;
        self.checkboxView.layer.masksToBounds = YES;
        [self.checkboxView addTarget:self action:@selector(_onCheckboxToggle) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:self.checkboxView];
    }
    self.checkboxView.hidden = NO;
    [self _styleCheckbox:self.checkboxView.isSelected];
}
/// 单选复选框: 只用颜色表达选中 (选中=蓝底白边, 未选=空心灰边), 不打 ✓
- (void)_styleCheckbox:(BOOL)on {
    self.checkboxView.backgroundColor = on ? [UIColor systemBlueColor] : [UIColor clearColor];
    self.checkboxView.layer.borderColor = (on ? [UIColor systemBlueColor] : [UIColor separatorColor]).CGColor;
}

#pragma mark - checkGroup (多选色块)

- (void)_ensureChipContainer {
    if (!self.chipContainer) {
        self.chipContainer = [[UIView alloc] init];
        [self.contentView addSubview:self.chipContainer];
    }
    self.chipContainer.hidden = NO;
}
/// 色块样式: 选中 = 蓝底白字, 未选 = 浅灰底深色字 (靠颜色区分, 无勾选标记)
- (void)_styleChip:(UIButton *)chip selected:(BOOL)on {
    chip.selected = on;
    chip.backgroundColor = on ? [UIColor systemBlueColor] : [UIColor secondarySystemBackgroundColor];
    [chip setTitleColor:(on ? [UIColor whiteColor] : [UIColor labelColor]) forState:UIControlStateNormal];
    [chip setTitleColor:(on ? [UIColor whiteColor] : [UIColor labelColor]) forState:UIControlStateSelected];
    chip.layer.borderWidth = on ? 0 : 0.5;
    chip.layer.borderColor = [UIColor separatorColor].CGColor;
}
/// 按当前值重建色块按钮 (行数随 options 变化, 直接重建最省心)
- (void)_rebuildChipsForRow:(TSSettingsRow *)row {
    [self _ensureChipContainer];
    for (UIButton *b in self.chipButtons) [b removeFromSuperview];
    if (!self.chipButtons) self.chipButtons = [NSMutableArray array];
    [self.chipButtons removeAllObjects];

    NSArray *cur = TSValueForKey(row);
    NSMutableSet<NSString *> *selected = [NSMutableSet set];
    if ([cur isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)cur) {
            if ([v isKindOfClass:[NSString class]]) [selected addObject:v];
        }
    }
    for (NSUInteger i = 0; i < row.options.count; i++) {
        NSString *opt = row.options[i];
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeCustom];
        chip.tag = (NSInteger)i;
        chip.titleLabel.font = [UIFont systemFontOfSize:14];
        chip.titleLabel.adjustsFontSizeToFitWidth = YES;
        chip.titleLabel.minimumScaleFactor = 0.8;
        chip.layer.cornerRadius = 8;
        chip.layer.masksToBounds = YES;
        [chip setTitle:opt forState:UIControlStateNormal];
        [chip addTarget:self action:@selector(_onChipTap:) forControlEvents:UIControlEventTouchUpInside];
        [self _styleChip:chip selected:[selected containsObject:opt]];
        [self.chipContainer addSubview:chip];
        [self.chipButtons addObject:chip];
    }
    [self _layoutChips];
}

/// 色块网格定位 (标题行下方, 每行 columns 个, 间距 8, 高 32)
- (void)_layoutChips {
    if (self.chipButtons.count == 0) return;
    NSInteger columns = self.row.columns > 0 ? self.row.columns : 3;
    CGFloat left = 16, right = 16, gap = 8, chipH = 32, titleBottom = 34;
    CGFloat totalW = self.contentView.bounds.size.width;
    if (totalW <= 0) totalW = [UIScreen mainScreen].bounds.size.width;
    CGFloat chipW = (totalW - left - right - (columns - 1) * gap) / (CGFloat)columns;
    if (chipW < 44) chipW = 44;
    for (NSUInteger i = 0; i < self.chipButtons.count; i++) {
        NSInteger col = (NSInteger)i % columns;
        NSInteger line = (NSInteger)i / columns;
        self.chipButtons[i].frame = CGRectMake(left + col * (chipW + gap),
                                               titleBottom + line * (chipH + gap),
                                               chipW, chipH);
    }
}
- (void)_ensureStepper {
    if (!self.stepperView) {
        self.stepperView = [[UIStepper alloc] init];
        [self.stepperView addTarget:self action:@selector(_onStepperChange) forControlEvents:UIControlEventValueChanged];
        [self.contentView addSubview:self.stepperView];
    }
    if (!self.stepperValueLabel) {
        self.stepperValueLabel = [[UILabel alloc] init];
        self.stepperValueLabel.font = [UIFont systemFontOfSize:15];
        self.stepperValueLabel.textColor = [UIColor secondaryLabelColor];
        self.stepperValueLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:self.stepperValueLabel];
    }
    self.stepperView.hidden = NO;
    self.stepperValueLabel.hidden = NO;
}
- (void)_ensureSlider {
    if (!self.sliderView) {
        self.sliderView = [[UISlider alloc] init];
        [self.sliderView addTarget:self action:@selector(_onSliderChange) forControlEvents:UIControlEventValueChanged];
        [self.contentView addSubview:self.sliderView];
    }
    if (!self.sliderValueLabel) {
        self.sliderValueLabel = [[UILabel alloc] init];
        self.sliderValueLabel.font = [UIFont systemFontOfSize:13];
        self.sliderValueLabel.textColor = [UIColor secondaryLabelColor];
        self.sliderValueLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:self.sliderValueLabel];
    }
    self.sliderView.hidden = NO;
    if (self.row.showValueInline) self.sliderValueLabel.hidden = NO;
}
- (void)_ensureSegmented {
    if (!self.segmentedView) {
        self.segmentedView = [[UISegmentedControl alloc] initWithItems:self.row.options ?: @[]];
        [self.segmentedView addTarget:self action:@selector(_onSegmentedChange) forControlEvents:UIControlEventValueChanged];
        [self.contentView addSubview:self.segmentedView];
    } else if (self.segmentedView.numberOfSegments != self.row.options.count) {
        // options 变化, 重建
        [self.segmentedView removeFromSuperview];
        self.segmentedView = [[UISegmentedControl alloc] initWithItems:self.row.options ?: @[]];
        [self.segmentedView addTarget:self action:@selector(_onSegmentedChange) forControlEvents:UIControlEventValueChanged];
        [self.contentView addSubview:self.segmentedView];
    }
    self.segmentedView.hidden = NO;
}
- (void)_ensureTextField {
    if (!self.textField) {
        self.textField = [[UITextField alloc] init];
        self.textField.delegate = self;
        self.textField.font = [UIFont systemFontOfSize:15];
        self.textField.textAlignment = NSTextAlignmentRight;
        self.textField.returnKeyType = UIReturnKeyDone;
        [self.textField addTarget:self action:@selector(_onTextFieldChange) forControlEvents:UIControlEventEditingDidEnd];
        [self.contentView addSubview:self.textField];
    }
    self.textField.hidden = NO;
}
- (void)_ensureTextView {
    if (!self.textView) {
        self.textView = [[UITextView alloc] init];
        self.textView.font = [UIFont systemFontOfSize:14];
        self.textView.layer.borderColor = [UIColor separatorColor].CGColor;
        self.textView.layer.borderWidth = 0.5;
        self.textView.layer.cornerRadius = 6;
        self.textView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
        [self.textView addObserver:self forKeyPath:@"text" options:NSKeyValueObservingOptionNew context:NULL];
        [self.contentView addSubview:self.textView];
    }
    self.textView.hidden = NO;
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (object == self.textView) {
        if ([change[NSKeyValueChangeNewKey] isKindOfClass:[NSString class]]) {
            self.row.currentValue = change[NSKeyValueChangeNewKey];
        }
    }
}
- (void)_ensureDatePicker {
    if (!self.datePicker) {
        self.datePicker = [[UIDatePicker alloc] init];
        self.datePicker.preferredDatePickerStyle = UIDatePickerStyleCompact;
        [self.datePicker addTarget:self action:@selector(_onDateChange) forControlEvents:UIControlEventValueChanged];
        [self.contentView addSubview:self.datePicker];
    }
    self.datePicker.hidden = NO;
}
- (void)_ensureDisclosure {
    if (!self.disclosureButton) {
        self.disclosureButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.disclosureButton addTarget:self action:@selector(_onDisclosureTap) forControlEvents:UIControlEventTouchUpInside];
        self.disclosureButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
        [self.contentView addSubview:self.disclosureButton];
    }
    self.disclosureButton.hidden = NO;
}
- (void)_ensureColorSwatch {
    if (!self.colorSwatch) {
        self.colorSwatch = [[UIView alloc] init];
        self.colorSwatch.layer.borderWidth = 0.5;
        self.colorSwatch.layer.borderColor = [UIColor separatorColor].CGColor;
        self.colorSwatch.layer.cornerRadius = 4;
        [self.contentView addSubview:self.colorSwatch];
    }
    self.colorSwatch.hidden = NO;
}
- (void)_ensureAction {
    if (!self.actionButton) {
        self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.actionButton setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
        self.actionButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        [self.actionButton addTarget:self action:@selector(_onActionTap) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:self.actionButton];
    }
    self.actionButton.hidden = NO;
}
- (void)_ensureInfo {
    if (!self.infoLabel) {
        self.infoLabel = [[UILabel alloc] init];
        self.infoLabel.font = [UIFont systemFontOfSize:13];
        self.infoLabel.textColor = [UIColor secondaryLabelColor];
        self.infoLabel.numberOfLines = 0;
        [self.contentView addSubview:self.infoLabel];
    }
    self.infoLabel.hidden = NO;
}

#pragma mark - 应用行

- (void)applyWithRow:(TSSettingsRow *)row vc:(id<TSNativeSettingsCellDelegate>)vc {
    self.row = row;
    self.vc = vc;
    self.titleLabel.text = row.label;

    switch (row.type) {
        case TSSettingsRowTypeSwitch: {
            [self _ensureSwitch];
            id v = TSValueForKey(row);
            self.switchView.on = [v boolValue];
        } break;
        case TSSettingsRowTypeCheckbox: {
            [self _ensureCheckbox];
            BOOL on = [TSValueForKey(row) boolValue];
            self.checkboxView.selected = on;
            [self _styleCheckbox:on];
            row.currentValue = @(on);
        } break;
        case TSSettingsRowTypeCheckGroup: {
            self.titleLabel.text = row.label;
            [self _rebuildChipsForRow:row];
            id v = TSValueForKey(row);
            row.currentValue = [v isKindOfClass:[NSArray class]] ? v : @[];
        } break;
        case TSSettingsRowTypeStepper: {
            [self _ensureStepper];
            self.stepperView.minimumValue = row.minValue;
            self.stepperView.maximumValue = row.maxValue;
            self.stepperView.stepValue = row.step > 0 ? row.step : 1;
            id v = TSValueForKey(row);
            double d = [v doubleValue];
            if (d < row.minValue) d = row.minValue;
            if (d > row.maxValue) d = row.maxValue;
            self.stepperView.value = d;
            self.row.currentValue = @(d);
            self.stepperValueLabel.text = TSFormatNumber(d, row.format);
        } break;
        case TSSettingsRowTypeSlider: {
            [self _ensureSlider];
            self.sliderView.minimumValue = row.minValue;
            self.sliderView.maximumValue = row.maxValue;
            id v = TSValueForKey(row);
            double d = [v doubleValue];
            if (d < row.minValue) d = row.minValue;
            if (d > row.maxValue) d = row.maxValue;
            self.sliderView.value = d;
            self.row.currentValue = @(d);
            self.sliderValueLabel.text = TSFormatNumber(d, row.format);
        } break;
        case TSSettingsRowTypeSegmented: {
            [self _ensureSegmented];
            id v = TSValueForKey(row);
            NSInteger idx = [row.options indexOfObject:v];
            if (idx == NSNotFound) idx = 0;
            self.segmentedView.selectedSegmentIndex = idx;
            self.row.currentValue = row.options[idx];
        } break;
        case TSSettingsRowTypeSelect: {
            [self _ensureDisclosure];
            id v = TSValueForKey(row);
            [self.disclosureButton setTitle:[v description] ?: @"未选择" forState:UIControlStateNormal];
        } break;
        case TSSettingsRowTypeText:
        case TSSettingsRowTypeNumber: {
            [self _ensureTextField];
            self.textField.text = [TSValueForKey(row) description] ?: @"";
            self.textField.placeholder = row.placeholder ?: @"";
            self.textField.secureTextEntry = NO;
            // 键盘
            NSString *kb = row.keyboardType ?: @"default";
            if ([kb isEqualToString:@"number"]) self.textField.keyboardType = UIKeyboardTypeNumberPad;
            else if ([kb isEqualToString:@"decimal"]) self.textField.keyboardType = UIKeyboardTypeDecimalPad;
            else if ([kb isEqualToString:@"url"]) self.textField.keyboardType = UIKeyboardTypeURL;
            else if ([kb isEqualToString:@"email"]) self.textField.keyboardType = UIKeyboardTypeEmailAddress;
            else self.textField.keyboardType = UIKeyboardTypeDefault;
        } break;
        case TSSettingsRowTypeTextLong: {
            [self _ensureTextView];
            self.textView.text = [TSValueForKey(row) description] ?: @"";
        } break;
        case TSSettingsRowTypeDate: {
            [self _ensureDatePicker];
            NSDate *d = [TSValueForKey(row) isKindOfClass:[NSNumber class]]
                ? [NSDate dateWithTimeIntervalSince1970:[(NSNumber *)TSValueForKey(row) doubleValue]]
                : [NSDate date];
            self.datePicker.date = d;
            self.datePicker.datePickerMode = (row.dateMode == TSSettingsDateModeDate) ? UIDatePickerModeDate
                : (row.dateMode == TSSettingsDateModeTime) ? UIDatePickerModeTime
                : UIDatePickerModeDateAndTime;
        } break;
        case TSSettingsRowTypeDuration: {
            [self _ensureDatePicker];
            NSDate *ref = [NSDate date];
            id v = TSValueForKey(row);
            double secs = [v doubleValue];
            self.datePicker.datePickerMode = UIDatePickerModeCountDownTimer;
            self.datePicker.countDownDuration = secs;
            (void)ref;
        } break;
        case TSSettingsRowTypeColor: {
            [self _ensureColorSwatch];
            id v = TSValueForKey(row);
            UIColor *c = [v isKindOfClass:[NSString class]] ? TSUIColorFromHex(v) : [UIColor blackColor];
            self.colorSwatch.backgroundColor = c;
        } break;
        case TSSettingsRowTypeMulti: {
            [self _ensureDisclosure];
            id v = TSValueForKey(row);
            NSUInteger n = [v isKindOfClass:[NSArray class]] ? [(NSArray *)v count] : 0;
            [self.disclosureButton setTitle:[NSString stringWithFormat:@"已选 %lu 项", (unsigned long)n] forState:UIControlStateNormal];
        } break;
        case TSSettingsRowTypeAction: {
            [self _ensureAction];
            [self.actionButton setTitle:row.label forState:UIControlStateNormal];
        } break;
        case TSSettingsRowTypeInfo: {
            [self _ensureInfo];
            self.infoLabel.text = row.label;
            self.titleLabel.text = nil;
        } break;
    }
}

#pragma mark - 布局

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat left = 16, right = 16, top = 8, bottom = 8;
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;

    if (self.row.type == TSSettingsRowTypeInfo) {
        self.infoLabel.frame = CGRectMake(left, top, w - left - right, h - top - bottom);
        return;
    }
    if (self.row.type == TSSettingsRowTypeTextLong) {
        self.titleLabel.frame = CGRectMake(left, top, w - left - right, 18);
        CGFloat tvTop = top + 22;
        CGFloat tvH = h - tvTop - bottom - 16;
        self.textView.frame = CGRectMake(left, tvTop, w - left - right, tvH);
        return;
    }
    if (self.row.type == TSSettingsRowTypeDate || self.row.type == TSSettingsRowTypeDuration) {
        self.titleLabel.frame = CGRectMake(left, (h - 20) / 2, w - 140, 20);
        self.datePicker.frame = CGRectMake(w - 160, (h - 36) / 2, 150, 36);
        return;
    }
    if (self.row.type == TSSettingsRowTypeSlider) {
        self.titleLabel.frame = CGRectMake(left, top, w - left - right, 18);
        CGFloat sliderTop = top + 22;
        CGFloat valueW = 56;
        CGFloat sliderW = w - left - right - valueW - 8;
        self.sliderView.frame = CGRectMake(left, sliderTop, sliderW, h - sliderTop - bottom);
        self.sliderValueLabel.frame = CGRectMake(left + sliderW + 8, sliderTop, valueW, 30);
        return;
    }
    if (self.row.type == TSSettingsRowTypeAction) {
        // 整行当按钮
        self.actionButton.frame = CGRectMake(left, 0, w - left - right, h);
        return;
    }
    if (self.row.type == TSSettingsRowTypeCheckGroup) {
        // 标题一行 + 下方色块网格 (网格宽度依赖实际宽度, 在这里重新定位)
        self.titleLabel.frame = CGRectMake(left, top, w - left - right, 18);
        self.chipContainer.frame = CGRectMake(0, 0, w, h);
        [self _layoutChips];
        return;
    }

    // 其余: 左 titleLabel, 右控件
    CGFloat titleW = 110;
    self.titleLabel.frame = CGRectMake(left, (h - 20) / 2, titleW, 20);
    CGFloat ctrlX = left + titleW;
    CGFloat ctrlW = w - ctrlX - right;
    CGFloat ctrlY = (h - 30) / 2;
    CGFloat ctrlH = 30;
    switch (self.row.type) {
        case TSSettingsRowTypeSwitch:
            self.switchView.frame = CGRectMake(w - right - 51, (h - 31) / 2, 51, 31);
            break;
        case TSSettingsRowTypeCheckbox:
            self.checkboxView.frame = CGRectMake(w - right - 28, (h - 28) / 2, 28, 28);
            break;
        case TSSettingsRowTypeStepper: {
            self.stepperValueLabel.frame = CGRectMake(ctrlX, ctrlY, ctrlW - 94, ctrlH);
            self.stepperView.frame = CGRectMake(w - right - 94, (h - 32) / 2, 94, 32);
            break;
        }
        case TSSettingsRowTypeSegmented:
            self.segmentedView.frame = CGRectMake(ctrlX, ctrlY, ctrlW, ctrlH);
            break;
        case TSSettingsRowTypeSelect:
        case TSSettingsRowTypeMulti: {
            CGRect f = CGRectMake(ctrlX, 0, ctrlW, h);
            self.disclosureButton.frame = f;
            break;
        }
        case TSSettingsRowTypeColor: {
            CGFloat sw = 36;
            self.colorSwatch.frame = CGRectMake(w - right - sw, (h - sw) / 2, sw, sw);
            break;
        }
        case TSSettingsRowTypeText:
        case TSSettingsRowTypeNumber: {
            self.textField.frame = CGRectMake(ctrlX, ctrlY, ctrlW, ctrlH);
            break;
        }
        default: break;
    }
}

#pragma mark - 事件

- (void)_onSwitchChange {
    self.row.currentValue = @(self.switchView.isOn);
    [self.vc refreshAfterValueChange];
}
- (void)_onCheckboxToggle {
    BOOL next = !self.checkboxView.isSelected;
    self.checkboxView.selected = next;
    [self _styleCheckbox:next];
    self.row.currentValue = @(next);
    [self.vc refreshAfterValueChange];
}
/// 点色块 = 该项在选中集合里取反 (选中只改颜色, 不带勾选标记)
- (void)_onChipTap:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || idx >= (NSInteger)self.row.options.count) return;
    NSString *opt = self.row.options[idx];

    NSMutableArray<NSString *> *cur = [NSMutableArray array];
    id v = self.row.currentValue;
    if ([v isKindOfClass:[NSArray class]]) {
        for (id o in (NSArray *)v) {
            if ([o isKindOfClass:[NSString class]]) [cur addObject:o];
        }
    }
    NSUInteger before = cur.count;
    [cur removeObject:opt];
    if (cur.count == before) [cur addObject:opt];   // 原本没有 → 加入

    self.row.currentValue = [cur copy];
    for (UIButton *chip in self.chipButtons) {
        if (chip.tag >= 0 && chip.tag < (NSInteger)self.row.options.count) {
            [self _styleChip:chip selected:[cur containsObject:self.row.options[chip.tag]]];
        }
    }
    [self.vc refreshAfterValueChange];
}
- (void)_onStepperChange {
    self.row.currentValue = @(self.stepperView.value);
    self.stepperValueLabel.text = TSFormatNumber(self.stepperView.value, self.row.format);
    [self.vc refreshAfterValueChange];
}
- (void)_onSliderChange {
    self.row.currentValue = @(self.sliderView.value);
    self.sliderValueLabel.text = TSFormatNumber(self.sliderView.value, self.row.format);
    [self.vc refreshAfterValueChange];
}
- (void)_onSegmentedChange {
    NSInteger idx = self.segmentedView.selectedSegmentIndex;
    if (idx >= 0 && idx < (NSInteger)self.row.options.count) {
        self.row.currentValue = self.row.options[idx];
        [self.vc refreshAfterValueChange];
    }
}
- (void)_onTextFieldChange {
    NSString *t = self.textField.text ?: @"";
    if (self.row.type == TSSettingsRowTypeNumber) {
        // 数字字段: 解析为 number
        NSNumberFormatter *nf = [[NSNumberFormatter alloc] init];
        nf.locale = [NSLocale currentLocale];
        NSNumber *n = [nf numberFromString:t];
        if (n) {
            self.row.currentValue = n;
        } else {
            self.row.currentValue = @(t.doubleValue);
        }
    } else {
        self.row.currentValue = t;
    }
    [self.vc refreshAfterValueChange];
}
- (void)_onDateChange {
    if (self.row.type == TSSettingsRowTypeDuration) {
        self.row.currentValue = @(self.datePicker.countDownDuration);
    } else {
        self.row.currentValue = @([self.datePicker.date timeIntervalSince1970]);
    }
    [self.vc refreshAfterValueChange];
}
- (void)_onDisclosureTap {
    [self.vc openSubListForRow:self.row];
}
- (void)_onActionTap {
    [self.vc invokeActionForRow:self.row];
}

#pragma mark - UITextFieldDelegate
- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

- (void)dealloc {
    if (self.textView) {
        @try { [self.textView removeObserver:self forKeyPath:@"text"]; } @catch (id e) {}
    }
}

@end

#pragma mark - 取色器 (iOS 14+ UIColorWell, 这里也用 UIDialog 弹出色板做兜底)

#pragma mark - 主 view controller

@interface TSNativeSettingsViewController () <UITableViewDataSource, UITableViewDelegate,
                                                UIColorPickerViewControllerDelegate,
                                                TSNativeSettingsCellDelegate>

@property (nonatomic, strong) TSSettingsSchema *schema;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *footerBar;
@property (nonatomic, weak) TSSettingsRow *colorPickerRow;   // 当前色板操作的 row
@end

@implementation TSNativeSettingsViewController {
    BOOL _cancelRequested;
}

- (instancetype)initWithSchema:(TSSettingsSchema *)schema {
    if ((self = [super init])) {
        _schema = schema;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // 释放 Lua action 回调 registry 引用
    for (TSSettingsSection *s in self.schema.sections) {
        for (TSSettingsRow *r in s.rows) {
            if (r.luaCallbackRef != LUA_NOREF) {
                TSLuaUnrefAction(r.luaCallbackRef);
            }
        }
    }
}

- (BOOL)prefersStatusBarHidden { return NO; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleDefault; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.schema.title ?: self.schema.scriptName;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(_onCancelTapped)];
    if (@available(iOS 11.0, *)) {
        self.navigationController.navigationBar.prefersLargeTitles = NO;
    }

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.estimatedRowHeight = 50;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.tableView registerClass:[TSSettingsCell class] forCellReuseIdentifier:@"cell"];
    [self.view addSubview:self.tableView];

    self.footerBar = [self _buildFooterBar];
    [self.view addSubview:self.footerBar];

    [self _layoutSubviews];

    [self _loadInitialValuesFromJSON];
    [self _evaluateDependencyVisibility];
    [self.tableView reloadData];
}

- (void)_layoutSubviews {
    CGFloat footerH = 56;
    CGRect b = self.view.bounds;
    self.footerBar.frame = CGRectMake(0, b.size.height - footerH, b.size.width, footerH);
    self.tableView.frame = CGRectMake(0, 0, b.size.width, b.size.height - footerH);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self _layoutSubviews];
}

- (UIView *)_buildFooterBar {
    UIView *bar = [[UIView alloc] init];
    bar.backgroundColor = [UIColor secondarySystemBackgroundColor];
    // 顶部分割线
    UIView *sep = [[UIView alloc] init];
    sep.backgroundColor = [UIColor separatorColor];
    [bar addSubview:sep];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [sep.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [sep.leftAnchor constraintEqualToAnchor:bar.leftAnchor],
        [sep.rightAnchor constraintEqualToAnchor:bar.rightAnchor],
        [sep.heightAnchor constraintEqualToConstant:0.5],
    ]];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:15];
    [cancel addTarget:self action:@selector(_onCancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:cancel];

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    [save setTitle:@"保存" forState:UIControlStateNormal];
    save.titleLabel.font = [UIFont systemFontOfSize:15];
    [save addTarget:self action:@selector(_onSaveTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:save];

    UIButton *run = [UIButton buttonWithType:UIButtonTypeSystem];
    [run setTitle:@"保存并运行" forState:UIControlStateNormal];
    run.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [run setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    [run addTarget:self action:@selector(_onRunTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:run];

    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    save.translatesAutoresizingMaskIntoConstraints = NO;
    run.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [cancel.leftAnchor constraintEqualToAnchor:bar.leftAnchor constant:16],
        [cancel.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [run.rightAnchor constraintEqualToAnchor:bar.rightAnchor constant:-16],
        [run.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [save.rightAnchor constraintEqualToAnchor:run.leftAnchor constant:-24],
        [save.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
    ]];
    return bar;
}

#pragma mark - 数据读写

- (NSString *)_settingsPath {
    NSString *base = [[TSPaths luaDir] stringByAppendingPathComponent:
                      [self.schema.scriptName stringByAppendingString:@".settings.json"]];
    return base;
}

- (void)_loadInitialValuesFromJSON {
    NSString *path = [self _settingsPath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *dict = [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
    for (TSSettingsSection *s in self.schema.sections) {
        for (TSSettingsRow *r in s.rows) {
            id saved = dict[r.key];
            if (saved) {
                r.currentValue = saved;
            } else if (r.defaultValue) {
                r.currentValue = r.defaultValue;
            }
        }
    }
}

- (NSDictionary *)_collectValues {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (TSSettingsSection *s in self.schema.sections) {
        for (TSSettingsRow *r in s.rows) {
            if (r.type == TSSettingsRowTypeInfo || r.type == TSSettingsRowTypeAction) continue;
            if (r.hiddenByDependency) continue;
            id v = r.currentValue ?: r.defaultValue;
            if (v) out[r.key] = v;
        }
    }
    return out;
}

- (BOOL)_validateWithErrorMessage:(NSString **)errMsg {
    for (TSSettingsSection *s in self.schema.sections) {
        for (TSSettingsRow *r in s.rows) {
            if (r.type == TSSettingsRowTypeInfo || r.type == TSSettingsRowTypeAction) continue;
            if (r.hiddenByDependency) continue;
            id v = r.currentValue ?: r.defaultValue;
            if (!v || v == [NSNull null]) continue;
            if (r.validatorType.length == 0) continue;
            NSString *str = [v isKindOfClass:[NSString class]] ? v : [v description];
            if ([r.validatorType isEqualToString:@"url"]) {
                if (![str containsString:@"://"]) {
                    if (errMsg) *errMsg = r.validatorMessage ?: [NSString stringWithFormat:@"%@: URL 格式不正确", r.label];
                    return NO;
                }
            } else if ([r.validatorType isEqualToString:@"email"]) {
                if (![str containsString:@"@"] || ![str containsString:@"."]) {
                    if (errMsg) *errMsg = r.validatorMessage ?: [NSString stringWithFormat:@"%@: 邮箱格式不正确", r.label];
                    return NO;
                }
            } else if ([r.validatorType isEqualToString:@"number"]) {
                if ([str doubleValue] == 0 && ![str isEqualToString:@"0"] && ![str isEqualToString:@"0.0"]) {
                    if (errMsg) *errMsg = r.validatorMessage ?: [NSString stringWithFormat:@"%@: 必须为数字", r.label];
                    return NO;
                }
            } else if ([r.validatorType isEqualToString:@"decimal"]) {
                if (![str containsString:@"."] && ![str isEqualToString:@"0"]) {
                    // 允许纯整数
                }
            }
        }
    }
    return YES;
}

- (BOOL)_saveSettingsToJSON {
    NSString *path = [self _settingsPath];
    NSDictionary *dict = [self _collectValues];
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&err];
    if (!data) {
        NSLog(@"[NativeSettings] 序列化失败: %@", err.localizedDescription);
        return NO;
    }
    if (![data writeToFile:path atomically:YES]) {
        NSLog(@"[NativeSettings] 写文件失败: %@", path);
        return NO;
    }
    NSLog(@"[NativeSettings] 已保存 %@ (%lu 项)", path.lastPathComponent, (unsigned long)dict.count);
    return YES;
}

#pragma mark - 依赖显示

- (void)_evaluateDependencyVisibility {
    // 第一次: 默认隐藏 (有 visibleWhenKey 的行), 待条件满足再显示
    for (TSSettingsSection *s in self.schema.sections) {
        for (TSSettingsRow *r in s.rows) {
            if (r.visibleWhenKey.length == 0) {
                r.hiddenByDependency = NO;
                continue;
            }
            TSSettingsRow *dep = [self _findRowByKey:r.visibleWhenKey];
            if (!dep) {
                r.hiddenByDependency = NO;
                continue;
            }
            id depVal = dep.currentValue ?: dep.defaultValue;
            r.hiddenByDependency = !TSValueEqual(depVal, r.visibleWhenValue);
        }
    }
}

- (TSSettingsRow *)_findRowByKey:(NSString *)key {
    for (TSSettingsSection *s in self.schema.sections) {
        for (TSSettingsRow *r in s.rows) {
            if ([r.key isEqualToString:key]) return r;
        }
    }
    return nil;
}

/// 行值改变后调用: 重算依赖, 重新加载表
- (void)refreshAfterValueChange {
    BOOL before = NO, after = NO;
    for (TSSettingsSection *s in self.schema.sections) {
        for (TSSettingsRow *r in s.rows) {
            if (r.visibleWhenKey.length == 0) continue;
            TSSettingsRow *dep = [self _findRowByKey:r.visibleWhenKey];
            if (!dep) continue;
            id depVal = dep.currentValue ?: dep.defaultValue;
            BOOL shouldShow = TSValueEqual(depVal, r.visibleWhenValue);
            if (r.hiddenByDependency == shouldShow) {
                r.hiddenByDependency = !shouldShow;
                // 变化标记
                before = before || r.hiddenByDependency;
                after = after || !r.hiddenByDependency;
            }
        }
    }
    if (before || after) {
        [self.tableView reloadData];
    }
}

#pragma mark - 子页面 (select / multi / color)

- (void)openSubListForRow:(TSSettingsRow *)row {
    if (row.type == TSSettingsRowTypeSelect) {
        TSSelectListVC *vc = [[TSSelectListVC alloc] init];
        vc.row = row;
        vc.parent = self;
        [self.navigationController pushViewController:vc animated:YES];
    } else if (row.type == TSSettingsRowTypeMulti) {
        TSMultiListVC *vc = [[TSMultiListVC alloc] init];
        vc.row = row;
        vc.parent = self;
        [self.navigationController pushViewController:vc animated:YES];
    } else if (row.type == TSSettingsRowTypeColor) {
        // iOS 14+: 系统取色器
        if (@available(iOS 14.0, *)) {
            UIColorPickerViewController *p = [[UIColorPickerViewController alloc] init];
            p.delegate = self;
            id v = TSValueForKey(row);
            p.selectedColor = [v isKindOfClass:[NSString class]] ? TSUIColorFromHex(v) : [UIColor blackColor];
            self.colorPickerRow = row;
            // hostedInHUD 时也要走 present, 因为 UIColorPickerViewController 是普通 view controller
            [self presentViewController:p animated:YES completion:nil];
        }
    }
}

#pragma mark - UIColorPickerViewControllerDelegate (iOS 14+)
- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)p {
    TSSettingsRow *r = self.colorPickerRow;
    if (r) {
        r.currentValue = TSColorHexFromUIColor(p.selectedColor);
        [self refreshAfterValueChange];
        [self.tableView reloadData];
    }
}
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)p {
    [p dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - action 回调

- (void)invokeActionForRow:(TSSettingsRow *)row {
    if (row.luaCallbackRef == LUA_NOREF) return;
    // 通过 TSLuaBridge 调用 Lua 注册表引用
    TSLuaInvokeActionWithCurrentSettings(row.luaCallbackRef, [self _collectValues]);
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.schema.sections.count;
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    TSSettingsSection *s = self.schema.sections[section];
    NSInteger n = 0;
    for (TSSettingsRow *r in s.rows) if (!r.hiddenByDependency) n++;
    return n;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    return self.schema.sections[section].title;
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    return self.schema.sections[section].footer;
}
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    TSSettingsRow *r = [self _rowAtIndexPath:ip];
    if (r.type == TSSettingsRowTypeInfo) {
        // 自适应文字
        CGFloat w = tv.bounds.size.width - 32;
        CGSize sz = [r.label boundingRectWithSize:CGSizeMake(w, CGFLOAT_MAX)
                                         options:NSStringDrawingUsesLineFragmentOrigin
                                      attributes:@{NSFontAttributeName:[UIFont systemFontOfSize:13]}
                                         context:nil].size;
        return MAX(36, sz.height + 20);
    }
    if (r.type == TSSettingsRowTypeCheckGroup) {
        // 标题行 34 + 每行色块 40 (高 32 + 间距 8)
        NSInteger columns = r.columns > 0 ? r.columns : 3;
        NSInteger lines = (NSInteger)((r.options.count + columns - 1) / columns);
        if (lines < 1) lines = 1;
        return 34 + lines * 40;
    }
    if (r.type == TSSettingsRowTypeTextLong) return 110;
    if (r.type == TSSettingsRowTypeDate || r.type == TSSettingsRowTypeDuration) return 56;
    return 50;
}
- (TSSettingsRow *)_rowAtIndexPath:(NSIndexPath *)ip {
    TSSettingsSection *s = self.schema.sections[ip.section];
    NSInteger n = 0;
    for (TSSettingsRow *r in s.rows) {
        if (r.hiddenByDependency) continue;
        if (n == ip.row) return r;
        n++;
    }
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    TSSettingsCell *cell = [tv dequeueReusableCellWithIdentifier:@"cell" forIndexPath:ip];
    TSSettingsRow *r = [self _rowAtIndexPath:ip];
    [cell applyWithRow:r vc:self];
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    // checkbox 行支持点击整行切换 (打勾控件只有 28pt, 任务清单场景用户习惯点文字)
    [tv deselectRowAtIndexPath:ip animated:NO];
    TSSettingsRow *r = [self _rowAtIndexPath:ip];
    if (r.type == TSSettingsRowTypeCheckbox) {
        TSSettingsCell *cell = (TSSettingsCell *)[tv cellForRowAtIndexPath:ip];
        if ([cell isKindOfClass:[TSSettingsCell class]]) {
            [cell _onCheckboxToggle];
        }
    }
}

#pragma mark - 底部按钮

- (void)_onCancelTapped {
    if (_cancelRequested) return;
    _cancelRequested = YES;
    [self _dismissAndFinish:NO];
}
- (void)_onSaveTapped {
    NSString *err = nil;
    if (![self _validateWithErrorMessage:&err]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"参数有误"
                                                                   message:err
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    [self _saveSettingsToJSON];
    [self _dismissAndFinish:NO];
}
- (void)_onRunTapped {
    NSString *err = nil;
    if (![self _validateWithErrorMessage:&err]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"参数有误"
                                                                   message:err
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    [self _saveSettingsToJSON];
    [self _dismissAndFinish:YES];
}

- (void)_dismissAndFinish:(BOOL)didRun {
    if (self.hostedInHUD) {
        [[TSHUDHost shared] dismissViewControllerFromHUD:self];
        if (self.onFinish) self.onFinish(didRun);
        return;
    }
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.onFinish) self.onFinish(didRun);
    }];
}

@end
