//
//  TSScriptListViewController.m
//  TrollAutoTouch
//
//  脚本列表 —— 配置标签页
//  显示 /var/mobile/Media/svip/lua (可降落至 Documents/lua) 下的 .lua/.tas 文件
//  对齐 TAS 原版脚本文件列表
//

#import "TSScriptListViewController.h"
#import "../Core/TSToolExecutor.h"

@interface TSScriptListViewController () <UITableViewDelegate, UITableViewDataSource>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy)   NSArray<TSFileEntry *> *scripts;
@property (nonatomic, copy)   NSString *scriptsDir;

@end

@implementation TSScriptListViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"配置";
    }
    return self;
}

- (void)loadView {
    [super loadView];
    self.view.backgroundColor = [UIColor colorWithWhite:0.04 alpha:1];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // ── 脚本目录 ──
    // 优先 /var/mobile/Media/svip/lua（TAS 默认路径），fallback 到 Documents/lua
    NSArray *candidates = @[ @"/var/mobile/Media/svip/lua",
                             [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"lua"] ];
    _scriptsDir = nil;
    for (NSString *p in candidates) {
        if ([[TSToolExecutor shared] isReadable:p]) {
            _scriptsDir = p;
            break;
        }
    }
    if (!_scriptsDir) {
        _scriptsDir = candidates.lastObject;
        [[TSToolExecutor shared] createDirectory:_scriptsDir];
    }

    // ── Table ──
    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.backgroundColor  = [UIColor colorWithWhite:0.04 alpha:1];
    _tableView.separatorColor   = [UIColor colorWithWhite:0.12 alpha:1];
    _tableView.delegate   = self;
    _tableView.dataSource = self;
    _tableView.rowHeight  = 52;
    [self.view addSubview:_tableView];

    // ── 标题栏 ──
    [self _setupNavBar];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self _reload];
}

- (void)_setupNavBar {
    UILabel *title = [[UILabel alloc] init];
    title.text = @"脚本文件";
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textColor = [UIColor whiteColor];
    [title sizeToFit];
    self.navigationItem.titleView = title;

    UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                          target:self
                                                                          action:@selector(_addScript)];
    self.navigationItem.rightBarButtonItem = add;
}

- (void)_reload {
    _scripts = [[TSToolExecutor shared] listDirectory:_scriptsDir];
    // 只保留 .lua 和 .tas 文件
    NSPredicate *pred = [NSPredicate predicateWithBlock:^BOOL(TSFileEntry *e, NSDictionary *b) {
        if (e.isDirectory) return NO;
        NSString *ext = [e.name.pathExtension lowercaseString];
        return [ext isEqualToString:@"lua"] || [ext isEqualToString:@"tas"];
    }];
    _scripts = [_scripts filteredArrayUsingPredicate:pred];
    // 按修改时间倒序
    _scripts = [_scripts sortedArrayUsingComparator:^NSComparisonResult(TSFileEntry *a, TSFileEntry *b) {
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
        NSString *path = [self.scriptsDir stringByAppendingPathComponent:name];
        NSString *tmpl = @"-- 新脚本\n-- 使用 tas.* API 控制设备\n\nfunction main()\n    print(\"hello\")\nend\n\nmain()\n";
        [[TSToolExecutor shared] writeTextFile:path content:tmpl];
        [self _reload];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)_deleteScript:(TSFileEntry *)e {
    [[TSToolExecutor shared] removeItem:e.path];
    [self _reload];
}

- (void)_runScript:(TSFileEntry *)e {
    NSString *content = [[TSToolExecutor shared] readTextFile:e.path];
    if (!content) {
        [self _alert:@"读取失败" msg:@"无法打开脚本文件"];
        return;
    }
    // 通知 HUD 面板执行脚本（通过通知机制）
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TSRunScript"
                                                        object:nil
                                                      userInfo:@{@"path": e.path, @"content": content}];
}

#pragma mark - TableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return _scripts.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    return _scriptsDir;
}

- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *h = (UITableViewHeaderFooterView *)view;
        h.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        h.textLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"ScriptCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
        cell.textLabel.textColor   = [UIColor whiteColor];
        cell.textLabel.font        = [UIFont systemFontOfSize:14];
        cell.detailTextLabel.font  = [UIFont systemFontOfSize:11];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1];
        cell.imageView.tintColor   = [UIColor colorWithRed:0.3 green:0.6 blue:1.0 alpha:1];
        cell.accessoryType = UITableViewCellAccessoryNone;
    }

    TSFileEntry *e = _scripts[ip.row];
    cell.textLabel.text = e.name;

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm";
    NSString *dateStr = e.modificationDate ? [df stringFromDate:e.modificationDate] : @"";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  |  %lld B", dateStr, e.size];

    if (@available(iOS 13.0, *)) {
        cell.imageView.image = [UIImage systemImageNamed:@"doc.text"];
    }

    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    TSFileEntry *e = _scripts[ip.row];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:e.name
                                                                   message:[NSString stringWithFormat:@"%@\n%lld B", e.modificationDate ?: @"", e.size]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"▶ 执行" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self _runScript:e];
    }]];
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
    edit.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:1];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete, edit]];
}

#pragma mark - Helpers

- (void)_editScript:(TSFileEntry *)e {
    // 简单文本编辑器
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