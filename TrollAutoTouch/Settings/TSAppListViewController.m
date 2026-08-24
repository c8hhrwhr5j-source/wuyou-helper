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
@property (nonatomic, strong) UIActivityIndicatorView *loadingView;

@property (nonatomic, copy)   NSArray<NSDictionary *> *allApps;      // {name, bundleID, bundlePath}
@property (nonatomic, copy)   NSArray<NSDictionary *> *filteredApps;
@property (nonatomic, strong) NSCache<NSString *, UIImage> *iconCache;
@property (nonatomic, assign) BOOL includeSystemApps;   // 是否包含 com.apple.* 系统应用

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

    _iconCache = [[NSCache alloc] init];
    _iconCache.countLimit = 100;
    _includeSystemApps = NO;   // 默认不显示系统应用 (com.apple.*), 加载更快

    // 导航栏右侧: 切换"显示系统应用"
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
                                                                style:UIBarButtonItemStylePlain
                                                               target:self
                                                               action:@selector(_toggleSystemApps)];
    item.tintColor = [TSColors tint];
    self.navigationItem.rightBarButtonItem = item;

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

    // Loading 占位: 立即显示, 避免点击后页面空白等待
    _loadingView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _loadingView.center = self.view.center;
    _loadingView.color = [TSColors tint];
    [self.view addSubview:_loadingView];
    [_loadingView startAnimating];

    // 异步加载应用列表, 避免阻塞 UI 跳转动画
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSDictionary *> *apps = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];

        // 只用 LSApplicationWorkspace.allInstalledApplications, 不再枚举文件系统
        // (文件系统枚举 /var/containers/Bundle/Application 是主要慢点)
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
                        NSString *bid = nil;
                        NSString *name = nil;
                        NSString *path = nil;
                        @try {
                            bid  = [proxy performSelector:@selector(applicationIdentifier)];
                            name = [proxy performSelector:@selector(localizedName)];
                            NSURL *url = [proxy performSelector:@selector(bundleURL)];
                            path = url.path ?: @"";
                        } @catch (NSException *e) { continue; }

                        if (!bid.length) continue;
                        if ([seen containsObject:bid]) continue;
                        // 跳过系统应用 (com.apple.* / com.apple.*.*): 大量系统应用拖慢渲染
                        // 用户通常只需要第三方应用包名. 想看系统应用可改 _includeSystemApps
                        if (!_includeSystemApps && [bid hasPrefix:@"com.apple."]) continue;
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

        // 按应用名排序 (大小写不敏感)
        [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];

        // 回主线程刷新 UI
        dispatch_async(dispatch_get_main_queue(), ^{
            _allApps = apps;
            _filteredApps = apps;
            [_loadingView stopAnimating];
            [_loadingView removeFromSuperview];
            _loadingView = nil;
            [_tableView reloadData];
        });
    });
}

#pragma mark - Toggle system apps

- (void)_toggleSystemApps {
    _includeSystemApps = !_includeSystemApps;

    // 重新显示 loading
    _loadingView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _loadingView.center = self.view.center;
    _loadingView.color = [TSColors tint];
    [self.view addSubview:_loadingView];
    [_loadingView startAnimating];
    _filteredApps = @[];
    [_tableView reloadData];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSDictionary *> *apps = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];

        Class cls = NSClassFromString(@"LSApplicationWorkspace");
        if (cls) {
            @try {
                id ws = [cls performSelector:@selector(defaultWorkspace)];
                if (ws) {
                    NSArray *proxies = nil;
                    @try {
                        proxies = [ws performSelector:@selector(allInstalledApplications)];
                    } @catch (NSException *e) { proxies = nil; }

                    for (id proxy in proxies) {
                        NSString *bid = nil, *name = nil, *path = @"";
                        @try {
                            bid  = [proxy performSelector:@selector(applicationIdentifier)];
                            name = [proxy performSelector:@selector(localizedName)];
                            NSURL *url = [proxy performSelector:@selector(bundleURL)];
                            path = url.path ?: @"";
                        } @catch (NSException *e) { continue; }
                        if (!bid.length) continue;
                        if ([seen containsObject:bid]) continue;
                        if (!_includeSystemApps && [bid hasPrefix:@"com.apple."]) continue;
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

        [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            _allApps = apps;
            _filteredApps = apps;
            [_loadingView stopAnimating];
            [_loadingView removeFromSuperview];
            _loadingView = nil;
            [_tableView reloadData];
        });
    });
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

    // 图标: 先查 NSCache, 命中立即显示; 未命中则占位 + 异步加载完回主线程刷新
    NSString *bundlePath = app[@"bundlePath"];
    UIImage *cached = [_iconCache objectForKey:bundlePath];
    if (cached) {
        c.imageView.image = cached;
    } else {
        c.imageView.image = [UIImage systemImageNamed:@"app"];
        c.imageView.tintColor = [TSColors tertiaryLabel];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            UIImage *img = [self _loadIconForBundlePath:bundlePath];
            if (!img) {
                [_iconCache setObject:[NSNull null] forKey:bundlePath];
                return;
            }
            [_iconCache setObject:img forKey:bundlePath];
            dispatch_async(dispatch_get_main_queue(), ^{
                // 仅当 cell 还可见且对应同一应用时刷新, 避免错位
                NSIndexPath *visible = [tv indexPathForCell:c];
                if (visible && [visible isEqual:ip]) {
                    [c.imageView setImage:img];
                    c.imageView.tintColor = nil;
                    [c setNeedsLayout];
                }
            });
        });
    }
    c.imageView.contentMode = UIViewContentModeScaleAspectFit;

    c.accessoryType = UITableViewCellAccessoryNone;
    return c;
}

// 同步从 .bundle 路径读 Info.plist + 加载图标文件 (圆角剪裁到 40×40)
// 命中 cache 时不会调用此方法, 仅首次加载时阻塞后台队列
- (UIImage *)_loadIconForBundlePath:(NSString *)bundlePath {
    if (!bundlePath.length) return nil;
    NSString *infoPlist = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:infoPlist];
    if (!d) return nil;
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
        img = [UIImage imageWithContentsOfFile:[path stringByAppendingString:@"@3x.png"]];
        if (!img) img = [UIImage imageWithContentsOfFile:[path stringByAppendingString:@"@2x.png"]];
        if (!img) img = [UIImage imageWithContentsOfFile:[path stringByAppendingString:@".png"]];
    }
    if (!img) return nil;
    // 圆角剪裁 (与系统应用列表一致)
    CGFloat r = 12;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(40, 40), NO, UIScreen.mainScreen.scale);
    UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 40, 40) cornerRadius:r];
    [p addClip];
    [img drawInRect:CGRectMake(0, 0, 40, 40)];
    UIImage *rounded = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return rounded;
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
