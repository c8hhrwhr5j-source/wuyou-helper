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
#import "TSScriptCipher.h"
#import "../Common/TSZip.h"
#import "TSScriptEditorViewController.h"
#import "../HUD/TSHUDHost.h"

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

    // 下拉刷新: 下拉到顶回弹时刷新脚本列表
    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(_reload) forControlEvents:UIControlEventValueChanged];
    refreshControl.tintColor = [TSColors tint];
    _tableView.refreshControl = refreshControl;

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

    // 左上角: 新建脚本 "+"
    UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                          target:self
                                                                          action:@selector(_addScript)];
    self.navigationItem.leftBarButtonItem = add;

    // 右上角: 刷新脚本列表
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                             target:self
                                                                             action:@selector(_reload)];
    self.navigationItem.rightBarButtonItem = refresh;
}

- (void)_reload {
    [TSPaths ensureDirectoriesExist];

    NSArray *all = [[TSToolExecutor shared] listDirectory:[TSPaths luaDir]];
    NSPredicate *pred = [NSPredicate predicateWithBlock:^BOOL(TSFileEntry *e, NSDictionary *b) {
        // 显示 .lua/.tas 文件 以及 包含 .lua 文件的文件夹
        if (e.isDirectory) {
            // 检查文件夹中是否有 .lua 文件
            NSArray *subContents = [[TSToolExecutor shared] listDirectory:e.path];
            for (TSFileEntry *sub in subContents) {
                if (!sub.isDirectory &&
                    [sub.name.pathExtension.lowercaseString isEqualToString:@"lua"]) {
                    return YES;
                }
            }
            return NO; // 空文件夹不显示
        }
        NSString *ext = [e.name.pathExtension lowercaseString];
        return [ext isEqualToString:@"lua"] || [ext isEqualToString:@"tas"];
    }];
    _scripts = [[all filteredArrayUsingPredicate:pred]
                sortedArrayUsingComparator:^NSComparisonResult(TSFileEntry *a, TSFileEntry *b) {
        // 文件夹排在文件前面
        if (a.isDirectory && !b.isDirectory) return NSOrderedAscending;
        if (!a.isDirectory && b.isDirectory) return NSOrderedDescending;
        return [b.modificationDate compare:a.modificationDate];
    }];
    [_tableView reloadData];

    // 下拉刷新触发时，结束刷新动画
    if (_tableView.refreshControl.isRefreshing) {
        [_tableView.refreshControl endRefreshing];
    }
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
    // 文件夹 → 作为项目运行
    if (e.isDirectory) {
        [[TSLuaBridge shared] runProject:e.path];
        [TSScriptListViewController setSelectedScriptName:e.name];
        return;
    }

    NSString *content = [[TSToolExecutor shared] readTextFile:e.path];
    if (!content) {
        [self _alert:@"读取失败" msg:@"无法打开脚本文件"];
        return;
    }
    // .tas 加密脚本: 解密后交由 Lua 引擎运行
    if ([TSScriptCipher isEncryptedContent:content]) {
        content = [TSScriptCipher decryptScript:content];
        if (!content) {
            [self _alert:@"读取失败" msg:@"加密脚本解密失败"];
            return;
        }
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TSRunScript"
                                                        object:nil
                                                      userInfo:@{@"path": e.path, @"content": content}];
}

// 加密脚本: xxx.lua -> xxx.tas (同名, 仅后缀变化)
- (void)_encryptScript:(TSFileEntry *)e {
    NSString *plain = [[TSToolExecutor shared] readTextFile:e.path];
    if (!plain) {
        [self _alert:@"读取失败" msg:@"无法读取脚本内容"];
        return;
    }
    NSString *newName = [[e.name stringByDeletingPathExtension] stringByAppendingString:@".tas"];
    NSString *newPath = [TSPaths pathForLua:newName];
    if ([[NSFileManager defaultManager] fileExistsAtPath:newPath]) {
        [self _alert:@"加密失败" msg:@"同名 .tas 文件已存在"];
        return;
    }
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"加密脚本"
                                                                    message:[NSString stringWithFormat:@"将 %@ 加密为 %@？\n加密后脚本仍可运行，但无法以明文查看源码。\n原始 .lua 文件会保留。", e.name, newName]
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"加密" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        NSString *cipher = [TSScriptCipher encryptScript:plain];
        if (!cipher) {
            [self _alert:@"加密失败" msg:@"生成加密脚本失败"];
            return;
        }
        // 只新建 .tas, 保留原始 .lua (便于后续修改/重新加密); 选中状态不变
        if ([[TSToolExecutor shared] writeTextFile:newPath content:cipher]) {
            [self _reload];
            [[TSHUDHost shared] showToast:@"已加密，原 .lua 已保留" duration:1.2 hidden:NO];
        } else {
            [self _alert:@"加密失败" msg:@"写入文件失败"];
        }
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

// ─────────────────────── 项目整包加密 (.tas) ───────────────────────
// 加密项目 = 把整个项目目录(含图片/资源/子文件夹)打包 → 单个 "TAP1" 加密文件。
// 加密后原明文目录被移除; 运行时引擎会自动解密还原出目录结构,
// 图片/资源仍按脚本里的正常路径读取, 仅源码不可见。
- (void)_encryptProject:(TSFileEntry *)e {
    NSString *newName = [e.name stringByAppendingString:@".tas"];
    NSString *newPath = [TSPaths pathForLua:newName];
    if ([[NSFileManager defaultManager] fileExistsAtPath:newPath]) {
        [self _alert:@"加密失败" msg:@"同名 .tas 文件已存在"];
        return;
    }
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"加密项目"
        message:[NSString stringWithFormat:@"将「%@」整个项目目录打包加密为 %@？\n\n加密后原文件夹(含全部 .lua 源码)会被移除，图片/资源/子目录全部打进包内；\n运行该加密包时会自动还原目录结构，图片/资源仍按正常路径读取。",
                e.name, newName]
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"加密并删除原目录"
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *a) {
        // 1) 目录 → zip (保留子目录结构)
        NSString *zipErr = nil;
        NSData *zip = [TSZip zipDataFromDirectory:e.path error:&zipErr];
        if (!zip) {
            [self _alert:@"加密失败" msg:zipErr ?: @"项目打包失败"];
            return;
        }
        // 2) zip → 加密内容
        NSString *cipher = [TSScriptCipher encryptProjectData:zip];
        if (!cipher) {
            [self _alert:@"加密失败" msg:@"生成加密包失败"];
            return;
        }
        // 3) 先写 .tas, 成功后再删原目录 (避免写失败丢数据)
        if (![[TSToolExecutor shared] writeTextFile:newPath content:cipher]) {
            [self _alert:@"加密失败" msg:@"写入 .tas 文件失败"];
            return;
        }
        // 4) 删除原明文目录, 并同步清除选中状态
        if ([[TSScriptListViewController selectedScriptName] isEqualToString:e.name]) {
            [TSScriptListViewController setSelectedScriptName:@""];
        }
        [[TSToolExecutor shared] removeItem:e.path];
        [self _reload];
        [[TSHUDHost shared] showToast:[NSString stringWithFormat:@"已加密为 %@，原目录已移除", newName]
                             duration:1.6 hidden:NO];
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
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
        cell.detailTextLabel.text = @"点击左上角 + 创建新脚本";
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

    BOOL isDir = e.isDirectory;
    BOOL isTAS = !isDir && [e.path.pathExtension.lowercaseString isEqualToString:@"tas"];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm";
    NSString *dateStr = e.modificationDate ? [df stringFromDate:e.modificationDate] : @"";
    NSString *typeLabel = isDir ? @"📁 项目" : (isTAS ? @"已加密" : @"");
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@  |  %lld B",
                                 typeLabel.length ? [typeLabel stringByAppendingString:@" | "] : @"",
                                 dateStr, e.size];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    // 选中脚本显示打勾图标 + 淡色高亮背景 (音量键快速运行的对象); .tas 加密脚本用锁图标
    BOOL isSelected = [[TSScriptListViewController selectedScriptName] isEqualToString:e.name];
    if (@available(iOS 13.0, *)) {
        NSString *icon;
        if (isDir) {
            icon = isSelected ? @"folder.fill.badge.checkmark" : @"folder";
        } else if (isTAS) {
            icon = isSelected ? @"checkmark.circle.fill" : @"lock.doc";
        } else {
            icon = isSelected ? @"checkmark.circle.fill" : @"doc.text";
        }
        cell.imageView.image = [UIImage systemImageNamed:icon];
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

    BOOL isDir = e.isDirectory;
    NSString *title = isDir ? [NSString stringWithFormat:@"📁 %@", e.name] : e.name;
    NSString *typeLabel = isDir ? @"项目目录" : @"";
    NSString *msg = [NSString stringWithFormat:@"%@\n%@\n%lld B",
                     typeLabel.length ? typeLabel : @"",
                     e.modificationDate ?: @"", e.size];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    TSLuaBridge *lua = [TSLuaBridge shared];
    BOOL isThisRunning = NO;
    if (isDir) {
        isThisRunning = lua.isRunning && [lua.runningPath hasPrefix:e.path];
    } else {
        isThisRunning = lua.isRunning && [lua.runningPath.lastPathComponent isEqualToString:e.name];
    }

    if (isThisRunning) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"■ 停止" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [lua stop];
        }]];
    } else {
        [sheet addAction:[UIAlertAction actionWithTitle:@"▶ 执行" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self _runScript:e];
        }]];
    }

    // 项目目录: 整包加密 (运行中不可加密)
    if (isDir && !isThisRunning) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"🔒 加密项目" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self _encryptProject:e];
        }]];
    }

    if (!isDir) {
        BOOL isTAS = [e.path.pathExtension.lowercaseString isEqualToString:@"tas"];
        if (!isTAS) {
            [sheet addAction:[UIAlertAction actionWithTitle:@"✎ 编辑" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                [self _editScript:e];
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:@"🔒 加密" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                [self _encryptScript:e];
            }]];
        }
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"✏️ 重命名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self _renameScript:e];
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
    NSMutableArray<UIContextualAction *> *actions = [NSMutableArray arrayWithObject:delete];
    BOOL isTAS = [e.path.pathExtension.lowercaseString isEqualToString:@"tas"];
    if (!isTAS) {
        UIContextualAction *edit = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                           title:@"编辑"
                                                                         handler:^(UIContextualAction *a, UIView *v, void (^h)(BOOL)) {
            [self _editScript:e];
            h(YES);
        }];
        edit.backgroundColor = [TSColors tint];
        [actions addObject:edit];
    }
    return [UISwipeActionsConfiguration configurationWithActions:actions];
}

#pragma mark - Helpers

// 编辑: 打开全屏文本编辑器 (右上角"保存" / 左上角"取消")
- (void)_editScript:(TSFileEntry *)e {
    // .tas 加密脚本禁止以明文查看/编辑源码
    if ([e.path.pathExtension.lowercaseString isEqualToString:@"tas"]) {
        [self _alert:@"加密脚本" msg:@"该脚本已加密，无法查看源码。"];
        return;
    }
    TSScriptEditorViewController *editor = [[TSScriptEditorViewController alloc] init];
    editor.filePath = e.path;
    [self.navigationController pushViewController:editor animated:YES];
}

// 重命名: 仅修改主名, 保留原扩展名 (.lua/.tas)
- (void)_renameScript:(TSFileEntry *)e {
    NSString *ext = e.path.pathExtension; // lua / tas
    NSString *oldBase = [e.name stringByDeletingPathExtension];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"重命名脚本"
                                                                message:[NSString stringWithFormat:@"修改 %@ 的前缀名（扩展名 .%@ 保持不变）", e.name, ext]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = oldBase;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *base = ac.textFields[0].text ?: @"";
        base = [base stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (base.length == 0) return;
        NSString *newName = [base stringByAppendingPathExtension:ext];
        if ([newName isEqualToString:e.name]) return; // 未修改
        NSString *newPath = [TSPaths pathForLua:newName];
        if ([[NSFileManager defaultManager] fileExistsAtPath:newPath]) {
            [self _alert:@"重命名失败" msg:[NSString stringWithFormat:@"同名文件 %@ 已存在", newName]];
            return;
        }
        if (![[TSToolExecutor shared] moveItem:e.path to:newPath]) {
            [self _alert:@"重命名失败" msg:@"文件移动失败"];
            return;
        }
        // 重命名的是当前选中脚本 → 同步更新选中状态
        if ([[TSScriptListViewController selectedScriptName] isEqualToString:e.name]) {
            [TSScriptListViewController setSelectedScriptName:newName];
        }
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