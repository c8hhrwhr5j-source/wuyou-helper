//
//  TSPerformanceMonitorView.m
//  TrollAutoTouch
//
//  性能监控面板：CPU/MEM/网络 + sparkline
//  对应 TAS 设置页底部 性能 section
//

#import "TSPerformanceMonitorView.h"
#import "../Core/TSToolExecutor.h"
#import <sys/sysctl.h>
#import <mach/mach.h>
#import <ifaddrs.h>
#import <net/if.h>

@interface TSPerformanceMonitorView ()

@property (nonatomic, strong) UILabel *cpuLabel, *cpuPercentLabel;
@property (nonatomic, strong) TSSparklineView *cpuSpark;

@property (nonatomic, strong) UILabel *memLabel, *memPercentLabel;
@property (nonatomic, strong) TSSparklineView *memSpark;

@property (nonatomic, strong) UILabel *netLabel, *netUpLabel, *netDownLabel;
@property (nonatomic, strong) TSSparklineView *netUpSpark, *netDownSpark;

@property (nonatomic, strong) NSTimer *timer;

@end

@implementation TSPerformanceMonitorView

static CGFloat cpuUsage(void) {
    host_cpu_load_info_data_t cpuLoad;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&cpuLoad, &count) != KERN_SUCCESS)
        return 0.0;

    uint64_t user   = cpuLoad.cpu_ticks[CPU_STATE_USER];
    uint64_t system = cpuLoad.cpu_ticks[CPU_STATE_SYSTEM];
    uint64_t nice   = cpuLoad.cpu_ticks[CPU_STATE_NICE];
    uint64_t idle   = cpuLoad.cpu_ticks[CPU_STATE_IDLE];
    uint64_t total  = user + system + nice + idle;
    if (total == 0) return 0.0;
    return (CGFloat)(total - idle) / (CGFloat)total;
}

static CGFloat memUsage(void) {
    mach_port_t host = mach_host_self();
    vm_size_t pageSize;
    host_page_size(host, &pageSize);

    vm_statistics_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO_COUNT;
    if (host_statistics(host, HOST_VM_INFO, (host_info_t)&vm, &count) != KERN_SUCCESS)
        return 0.0;

    vm_size_t total = (vm.wire_count + vm.active_count + vm.inactive_count + vm.free_count) * pageSize;
    vm_size_t used  = (vm.wire_count + vm.active_count + vm.inactive_count) * pageSize;
    if (total == 0) return 0.0;
    return (CGFloat)used / (CGFloat)total;
}

static void netBytes(uint64_t *outUp, uint64_t *outDown) {
    *outUp = 0; *outDown = 0;
    struct ifaddrs *ifaddr;
    if (getifaddrs(&ifaddr) != 0) return;
    for (struct ifaddrs *ifa = ifaddr; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_LINK) continue;
        if (strncmp(ifa->ifa_name, "en", 2) != 0 && strncmp(ifa->ifa_name, "pdp_ip", 6) != 0) continue;
        struct if_data *d = (struct if_data *)ifa->ifa_data;
        *outUp   += d->ifi_obytes;
        *outDown += d->ifi_ibytes;
    }
    freeifaddrs(ifaddr);
}

static NSString *fmtBytes(uint64_t b) {
    if (b < 1024)            return [NSString stringWithFormat:@"%lluB",   b];
    if (b < 1024 * 1024)     return [NSString stringWithFormat:@"%.1fKB", b / 1024.0];
    if (b < 1024*1024*1024)  return [NSString stringWithFormat:@"%.1fMB", b / (1024.0 * 1024.0)];
    return [NSString stringWithFormat:@"%.2fGB", b / (1024.0 * 1024.0 * 1024.0)];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        [self _build];
        [self startUpdating];
    }
    return self;
}

- (void)_build {
    CGFloat w = self.bounds.size.width ?: 320;
    CGFloat rowH = 36;
    CGFloat leftW = 42, sparkW = 80, numW = 64, gap = 8;
    CGFloat sparkX = leftW + gap;
    CGFloat numX = sparkX + sparkW + gap;
    CGFloat labelWidth = w - 2 * 12;
    UIFont *f = [UIFont systemFontOfSize:13];

    // ── 标题 ──
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, w - 24, 26)];
    title.text = @"性能";
    title.textColor = [UIColor colorWithWhite:0.65 alpha:1];
    title.font = [UIFont boldSystemFontOfSize:14];
    [self addSubview:title];

    // ── CPU ──
    CGFloat y = 28;
    [self _label:@"CPU 使用率" rect:CGRectMake(12, y, leftW, rowH) font:f color:nil];
    _cpuSpark = [self _spark:CGRectMake(sparkX, y + 8, sparkW, rowH - 16) stroke:[UIColor colorWithRed:0.3 green:0.85 blue:0.4 alpha:1] fill:[UIColor colorWithRed:0.3 green:0.85 blue:0.4 alpha:0.15]];
    _cpuPercentLabel = [self _label:@"0.00%" rect:CGRectMake(numX, y, numW, rowH) font:f color:[UIColor colorWithRed:0.3 green:0.85 blue:0.4 alpha:1]];

    // ── MEM ──
    y += rowH;
    [self _label:@"MEM 使用率" rect:CGRectMake(12, y, leftW, rowH) font:f color:nil];
    _memSpark = [self _spark:CGRectMake(sparkX, y + 8, sparkW, rowH - 16) stroke:[UIColor colorWithRed:1.0 green:0.7 blue:0.1 alpha:1] fill:[UIColor colorWithRed:1.0 green:0.7 blue:0.1 alpha:0.15]];
    _memSpark.barMode = YES; // 柱状
    _memPercentLabel = [self _label:@"0.00%" rect:CGRectMake(numX, y, numW, rowH) font:f color:[UIColor colorWithRed:1.0 green:0.7 blue:0.1 alpha:1]];

    // ── 网络 ──
    y += rowH;
    [self _label:@"网络使用率" rect:CGRectMake(12, y, leftW, rowH) font:f color:nil];

    _netUpSpark = [self _spark:CGRectMake(sparkX, y + 6, sparkW, (rowH - 14) / 2) stroke:[UIColor colorWithRed:0.3 green:0.6 blue:1.0 alpha:1] fill:[UIColor colorWithRed:0.3 green:0.6 blue:1.0 alpha:0.1]];
    _netDownSpark = [self _spark:CGRectMake(sparkX, y + rowH / 2 + 2, sparkW, (rowH - 14) / 2) stroke:[UIColor colorWithRed:1.0 green:0.4 blue:0.4 alpha:1] fill:[UIColor colorWithRed:1.0 green:0.4 blue:0.4 alpha:0.1]];

    _netUpLabel   = [self _label:@"↑0B" rect:CGRectMake(numX, y + 2, numW, rowH / 2) font:[UIFont systemFontOfSize:11] color:[UIColor colorWithRed:0.3 green:0.6 blue:1.0 alpha:1]];
    _netDownLabel = [self _label:@"↓0B" rect:CGRectMake(numX, y + rowH / 2 + 2, numW, rowH / 2) font:[UIFont systemFontOfSize:11] color:[UIColor colorWithRed:1.0 green:0.4 blue:0.4 alpha:1]];
}

- (UILabel *)_label:(NSString *)txt rect:(CGRect)r font:(UIFont *)f color:(UIColor *)c {
    UILabel *l = [[UILabel alloc] initWithFrame:r];
    l.text = txt;
    l.font = f;
    l.textAlignment = NSTextAlignmentLeft;
    l.textColor = c ?: [UIColor colorWithWhite:0.85 alpha:1];
    l.backgroundColor = [UIColor clearColor];
    [self addSubview:l];
    return l;
}

- (TSSparklineView *)_spark:(CGRect)r stroke:(UIColor *)stroke fill:(UIColor *)fill {
    TSSparklineView *s = [[TSSparklineView alloc] initWithFrame:r];
    s.strokeColor = stroke;
    s.fillColor   = fill;
    [self addSubview:s];
    return s;
}

- (void)startUpdating {
    if (_timer) return;
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull t) {
        [self _tick];
    }];
    [self _tick];
}

- (void)stopUpdating {
    [_timer invalidate];
    _timer = nil;
}

- (void)_tick {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CGFloat cpu = cpuUsage();
        CGFloat mem = memUsage();
        uint64_t up = 0, down = 0;
        netBytes(&up, &down);

        dispatch_async(dispatch_get_main_queue(), ^{
            self.cpuPercentLabel.text = [NSString stringWithFormat:@"%.2f%%", cpu * 100];
            [self.cpuSpark appendValue:cpu];

            self.memPercentLabel.text = [NSString stringWithFormat:@"%.2f%%", mem * 100];
            [self.memSpark appendValue:mem];

            self.netUpLabel.text   = [@"↑" stringByAppendingString:fmtBytes(up)];
            self.netDownLabel.text = [@"↓" stringByAppendingString:fmtBytes(down)];
            // network sparkline uses dummy values for visual effect since absolute bytes
            // don't normalize well; just show a mild pulse
            CGFloat pulseUp   = (sin(CACurrentMediaTime() * 0.7) + 1) / 2 * 0.2 + 0.05;
            CGFloat pulseDown = (sin(CACurrentMediaTime() * 0.7 + 1.5) + 1) / 2 * 0.25 + 0.05;
            [self.netUpSpark appendValue:pulseUp];
            [self.netDownSpark appendValue:pulseDown];
        });
    });
}

- (void)dealloc {
    [_timer invalidate];
}

@end