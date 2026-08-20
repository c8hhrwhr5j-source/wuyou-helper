//
//  TSScriptListViewController.m
//  TrollAutoTouch
//
//  脚本列表 —— 配置标签页
//  显示 /var/mobile/touch/lua 下的 .lua/.tas 文件
//  浅色主题
//

#import "TSScriptListViewController.h"
#import "../Core/TSToolExecutor.h"
#import "../Common/TSPaths.h"
#import "TSLuaBridge.h"

@interface TSScriptListViewController () <UITableViewDelegate, UITableViewDataSource>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy)   NSArray<TSFileEntry *> *scripts;

@end

@implementation TSScriptListViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"配置";
    }
    return self;
}

#pragma mark - 选中脚本 (音量键快速运行)

+ (NSString *)selectedScriptName {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"LastSelectedScript"] ?: @"";
}

+ (void)setSelectedScriptName:(NSString *)name {
    [[NSUserDefaults standardUserDefaults] setObject:(name ?: @"") forKey:@"LastSelectedScript"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)loadView {
    [super loadView];
    self.view.backgroundColor = [TSColors bg];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // ── Table ──
    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.backgroundColor  = [TSColors bg];
    _tableView.separatorColor   = [TSColors separator];
    _tableView.delegate   = self;
    _tableView.dataSource = self;
    _tableView.rowHeight  = 52;
    [self.view addSubview:_tableView];

    [self _setupNavBar];

    // 脚本运行状态变化时刷新"运行中"标记
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_onLuaStateChanged:)
                                                 name:TSLuaRunningStateChangedNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_onLuaStateChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _reload];
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self _reload];
}

- (void)_setupNavBar {
    UILabel *title = [[UILabel alloc] init];
    title.text = @"脚本文件";
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textColor = [TSColors label];
    [title sizeToFit];
    self.navigationItem.titleView = title;

    UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                          target:self
                                                                          action:@selector(_addScript)];
    self.navigationItem.rightBarButtonItem = add;
}

- (void)_reload {
    [TSPaths ensureDirectoriesExist];

    NSArray *all = [[TSToolExecutor shared] listDirectory:[TSPaths luaDir]];
    NSPredicate *pred = [NSPredicate predicateWithBlock:^BOOL(TSFileEntry *e, NSDictionary *b) {
        if (e.isDirectory) return NO;
        NSString *ext = [e.name.pathExtension lowercaseString];
        return [ext isEqualToString:@"lua"] || [ext isEqualToString:@"tas"];
    }];
    _scripts = [[all filteredArrayUsingPredicate:pred]
                sortedArrayUsingComparator:^NSComparisonResult(TSFileEntry *a, TSFileEntry *b) {
        return [b.modificationDate compare:a.modificationDate];
    }];
    [_tableView reloadData];
}

#pragma mark - Actions

- (void)_addScript {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"新建脚本"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"脚本名称 (自动加 .lua)";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = ac.textFields[0].text ?: @"";
        if (name.length == 0) return;
        if (![name hasSuffix:@".lua"]) name = [name stringByAppendingString:@".lua"];
        NSString *path = [TSPaths pathForLua:name];
        NSString *tmpl = @"-- 新脚本\n-- 使用 tas.* API 控制设备\n\nfunction main()\n    print(\"hello\")\nend\n\nmain()\n";
        [[TSToolExecutor shared] writeTextFile:path content:tmpl];
        [self _reload];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)_deleteScript:(TSFileEntry *)e {
    // 删除的是选中脚本 → 清除选中状态
    if ([[TSScriptListViewController selectedScriptName] isEqualToString:e.name]) {
        [TSScriptListViewController setSelectedScriptName:@""];
    }
    [[TSToolExecutor shared] removeItem:e.path];
    [self _reload];
}

- (void)_runScript:(TSFileEntry *)e {
    NSString *content = [[TSToolExecutor shared] readTextFile:e.path];
    if (!content) {
        [self _alert:@"读取失败" msg:@"无法打开脚本文件"];
        return;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TSRunScript"
                                                        object:nil
                                                      userInfo:@{@"path": e.path, @"content": content}];
}

#pragma mark - TableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return MAX((NSInteger)_scripts.count, 1);
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    return [TSPaths luaDir];
}

- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *h = (UITableViewHeaderFooterView *)view;
        h.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        h.textLabel.textColor = [TSColors tertiaryLabel];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"ScriptCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    }

    cell.backgroundColor = [TSColors card];
    cell.textLabel.textColor   = [TSColors label];
    cell.textLabel.font        = [UIFont systemFontOfSize:14];
    cell.detailTextLabel.font  = [UIFont systemFontOfSize:11];
    cell.detailTextLabel.textColor = [TSColors tertiaryLabel];
    cell.imageView.tintColor   = [TSColors tint];
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (_scripts.count == 0) {
        cell.textLabel.text = @"暂无脚本";
        cell.textLabel.textColor = [TSColors tertiaryLabel];
        cell.detailTextLabel.text = @"点击右上角 + 创建新脚本";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (@available(iOS 13.0, *)) {
            cell.imageView.image = [UIImage systemImageNamed:@"tray"];
        } else {
            cell.imageView.image = nil;
        }
        return cell;
    }

    TSFileEntry *e = _scripts[ip.row];
    cell.textLabel.text = e.name;
    cell.textLabel.textColor = [TSColors label];

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm";
    NSString *dateStr = e.modificationDate ? [df stringFromDate:e.modificationDate] : @"";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  |  %lld B", dateStr, e.size];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    // 选中脚本显示打勾图标 + 淡色高亮背景 (音量键快速运行的对象)
    BOOL isSelected = [[TSScriptListViewController selectedScriptName] isEqualToString:e.name];
    if (@available(iOS 13.0, *)) {
        cell.imageView.image = [UIImage systemImageNamed:isSelected ? @"checkmark.circle.fill" : @"doc.text"];
    }
    if (isSelected) {
        cell.backgroundColor = [[TSColors tint] colorWithAlphaComponent:0.15];
    } else {
        cell.backgroundColor = [TSColors card];
    }

    // 当前正在运行的脚本，在名字最右侧显示"运行中"标签
    TSLuaBridge *lua = [TSLuaBridge shared];
    if (lua.isRunning && [lua.runningPath.lastPathComponent isEqualToString:e.name]) {
        UILabel *tag = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 50, 22)];
        tag.text = @"运行中";
        tag.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        tag.textColor = [UIColor whiteColor];
        tag.textAlignment = NSTextAlignmentCenter;
        tag.backgroundColor = [TSColors danger];
        tag.layer.cornerRadius = 4;
        tag.clipsToBounds = YES;
        cell.accessoryView = tag;
    } else {
        cell.accessoryView = nil;
    }

    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (_scripts.count == 0) return;
    TSFileEntry *e = _scripts[ip.row];
    // 点击即设为选中 (持久化, 供音量键快速运行), 刷新勾选显示
    [TSScriptListViewController setSelectedScriptName:e.name];
    [_tableView reloadData];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:e.name
                                                                   message:[NSString stringWithFormat:@"%@\n%lld B", e.modificationDate ?: @"", e.size]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    TSLuaBridge *lua = [TSLuaBridge shared];
    BOOL isThisRunning = lua.isRunning && [lua.runningPath.lastPathComponent isEqualToString:e.name];
    if (isThisRunning) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"■ 停止" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [lua stop];
        }]];
    } else {
        [sheet addAction:[UIAlertAction actionWithTitle:@"▶ 执行" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self _runScript:e];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"✎ 编辑" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self _editScript:e];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self _deleteScript:e];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (_scripts.count == 0) return nil;
    TSFileEntry *e = _scripts[ip.row];
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                         title:@"删除"
                                                                       handler:^(UIContextualAction *a, UIView *v, void (^h)(BOOL)) {
        [self _deleteScript:e];
        h(YES);
    }];
    UIContextualAction *edit = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                       title:@"编辑"
                                                                     handler:^(UIContextualAction *a, UIView *v, void (^h)(BOOL)) {
        [self _editScript:e];
        h(YES);
    }];
    edit.backgroundColor = [TSColors tint];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete, edit]];
}

#pragma mark - Helpers

- (void)_editScript:(TSFileEntry *)e {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:[@"编辑 " stringByAppendingString:e.name]
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [[TSToolExecutor shared] readTextFile:e.path] ?: @"";
        tf.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [[TSToolExecutor shared] writeTextFile:e.path content:ac.textFields[0].text ?: @""];
        [self _reload];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)_alert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end