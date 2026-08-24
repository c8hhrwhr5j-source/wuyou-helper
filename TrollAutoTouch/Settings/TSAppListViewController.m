//
//  TSAppListViewController.m
//  TrollAutoTouch
//
//  本机已安装应用列表: 显示应用名 + Bundle ID
//
//  实现:
//    - MobileCoreServices private API: LSApplicationWorkspace.allInstalledApplications
//    - 返回 LSApplicationProxy 数组, 每个代理包含 localizedName / applicationIdentifier / bundleURL
//    - TrollStore 安装的 app 有 com.apple.lsapplicationworkspace.rebuildappdatabases 权限,
//      间接允许列举全部应用
//    - 同时输出 system app (从 /Applications 枚举) 作为补充
//

#import "TSAppListViewController.h"
#import "../Common/TSPaths.h"
#import <MobileCoreServices/MobileCoreServices.h>

// 私有 API 声明 (LSApplicationWorkspace 位于 MobileCoreServices.framework)
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly) NSString *bundleVersion;
@property (nonatomic, readonly) NSNumber *installType;
@end

@interface TSAppListViewController () <UITableViewDelegate, UITableViewDataSource, UISearchResultsUpdating>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;

@property (nonatomic, copy)   NSArray<NSDictionary *> *allApps;      // {name, bundleID, bundlePath}
@property (nonatomic, copy)   NSArray<NSDictionary *> *filteredApps;

@end

@implementation TSAppListViewController

#pragma mark - Lifecycle

- (void)loadView {
    [super loadView];
    self.view.backgroundColor = [TSColors bg];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"本机应用包名";
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textColor = [TSColors label];
    [title sizeToFit];
    self.navigationItem.titleView = title;

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.backgroundColor = [TSColors bg];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 56;
    [_tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"app"];
    [self.view addSubview:_tableView];

    // 搜索栏: 支持按应用名或 Bundle ID 过滤
    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = self;
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchBar.placeholder = @"搜索应用名或 Bundle ID";
    _searchController.searchBar.tintColor = [TSColors tint];
    _tableView.tableHeaderView = _searchController.searchBar;
    self.definesPresentationContext = YES;

    [self _loadApps];
}

#pragma mark - 加载应用列表

- (void)_loadApps {
    NSMutableArray<NSDictionary *> *apps = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    // ① 优先 LSApplicationWorkspace.allInstalledApplications (覆盖全部用户应用)
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (cls) {
        @try {
            id ws = [cls performSelector:@selector(defaultWorkspace)];
            if (ws) {
                NSArray *proxies = nil;
                @try {
                    proxies = [ws performSelector:@selector(allInstalledApplications)];
                } @catch (NSException *e) {
                    proxies = nil;
                }
                for (id proxy in proxies) {
                    NSString *bid = [proxy performSelector:@selector(applicationIdentifier)];
                    NSString *name = [proxy performSelector:@selector(localizedName)];
                    NSURL *url = nil;
                    @try { url = [proxy performSelector:@selector(bundleURL)]; } @catch (NSException *e) {}
                    NSString *path = url.path ?: @"";
                    if (!bid.length) continue;
                    if ([seen containsObject:bid]) continue;
                    [seen addObject:bid];
                    [apps addObject:@{
                        @"name": name.length ? name : bid,
                        @"bundleID": bid,
                        @"bundlePath": path
                    }];
                }
            }
        } @catch (NSException *e) {}
    }

    // ② 兜底: 枚举 /Applications (系统 App), LSApplicationWorkspace 默认包含它们, 这里仅补漏
    NSArray<NSString *> *systemAppDirs = @[
        @"/Applications",
        @"/var/containers/Bundle/Application",
    ];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *dir in systemAppDirs) {
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
        NSString *file = nil;
        while ((file = en.nextObject)) {
            if (![file.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
            NSString *full = [dir stringByAppendingPathComponent:file];
            NSString *infoPlist = [full stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:infoPlist];
            if (!d) continue;
            NSString *bid = d[@"CFBundleIdentifier"];
            if (!bid.length || [seen containsObject:bid]) continue;
            [seen addObject:bid];
            [apps addObject:@{
                @"name": d[@"CFBundleDisplayName"] ?: d[@"CFBundleName"] ?: bid,
                @"bundleID": bid,
                @"bundlePath": full
            }];
        }
    }

    // 按应用名排序 (大小写不敏感)
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];

    _allApps = apps;
    _filteredApps = apps;
    [_tableView reloadData];
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *q = sc.searchBar.text;
    if (q.length == 0) {
        _filteredApps = _allApps;
    } else {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *app, NSDictionary *bindings) {
            return [app[@"name"] localizedCaseInsensitiveContainsString:q] ||
                   [app[@"bundleID"] localizedCaseInsensitiveContainsString:q];
        }];
        _filteredApps = [_allApps filteredArrayUsingPredicate:p];
    }
    [_tableView reloadData];
}

#pragma mark - TableView

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return _filteredApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"app" forIndexPath:ip];
    c.backgroundColor = [TSColors card];
    c.selectionStyle = UITableViewCellSelectionStyleNone;

    NSDictionary *app = _filteredApps[ip.row];
    NSString *name = app[@"name"];
    NSString *bid = app[@"bundleID"];

    // 两行布局: 上 = 应用名, 下 = Bundle ID (等宽字体便于复制)
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] init];
    [attr appendAttributedString:[[NSAttributedString alloc]
        initWithString:name
            attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:15],
                NSForegroundColorAttributeName: [TSColors label]
            }]];
    [attr appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"\n"]];
    [attr appendAttributedString:[[NSAttributedString alloc]
        initWithString:bid
            attributes:@{
                NSFontAttributeName: [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular],
                NSForegroundColorAttributeName: [TSColors secondaryLabel]
            }]];
    c.textLabel.attributedText = attr;
    c.textLabel.numberOfLines = 0;
    c.textLabel.lineBreakMode = NSLineBreakByCharWrapping;

    c.imageView.image = [self _appIcon:app[@"bundlePath"]];
    c.imageView.contentMode = UIViewContentModeScaleAspectFit;

    c.accessoryType = UITableViewCellAccessoryNone;
    return c;
}

- (UIImage *)_appIcon:(NSString *)bundlePath {
    if (!bundlePath.length) return nil;
    NSString *infoPlist = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:infoPlist];
    NSDictionary *icons = d[@"CFBundleIcons"];
    if (!icons) icons = d[@"CFBundleIconFiles"];
    NSString *iconName = nil;
    if ([icons isKindOfClass:[NSDictionary class]]) {
        NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
        if ([primary isKindOfClass:[NSDictionary class]]) {
            NSArray *files = primary[@"CFBundleIconFiles"];
            if ([files isKindOfClass:[NSArray class]] && files.count > 0) {
                iconName = files.lastObject;
            }
        }
    } else if ([icons isKindOfClass:[NSArray class]] && ((NSArray *)icons).count > 0) {
        iconName = [(NSArray *)icons lastObject];
    }
    if (!iconName.length) return nil;
    NSString *path = [bundlePath stringByAppendingPathComponent:iconName];
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (!img) {
        // 试 @2x / @3x 后缀
        img = [UIImage imageWithContentsOfFile:[path stringByAppendingString:@"@3x.png"]];
        if (!img) img = [UIImage imageWithContentsOfFile:[path stringByAppendingString:@"@2x.png"]];
        if (!img) img = [UIImage imageWithContentsOfFile:[path stringByAppendingString:@".png"]];
    }
    // 圆角剪裁 (与系统应用列表一致)
    if (img) {
        CGFloat r = 12;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(40, 40), NO, UIScreen.mainScreen.scale);
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 40, 40) cornerRadius:r];
        [p addClip];
        [img drawInRect:CGRectMake(0, 0, 40, 40)];
        img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }
    return img;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *app = _filteredApps[ip.row];
    NSString *text = app[@"bundleID"];
    UIPasteboard.generalPasteboard.string = text;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil
                                                                 message:@"已复制包名"
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:ac animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ac dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

@end
