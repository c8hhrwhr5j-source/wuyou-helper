//
//  TSAuthKeepAlive.m
//  TrollAutoTouch
//

#import "TSAuthKeepAlive.h"
#import "TSLogStore.h"
#import <UIKit/UIKit.h>

// 认证挑战端点列表(依次尝试):
//   1. httpbin 401 Basic Auth —— 触发 task 级 didReceiveChallenge
//   2. badssl 自签名证书 HTTPS —— 触发 session 级 TLS 信任挑战(备用, 国内可达性更好)
static NSArray<NSString *> *authURLs(void) {
    static NSArray<NSString *> *urls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        urls = @[
            @"https://httpbin.org/basic-auth/troll/autotouch",
            @"https://self-signed.badssl.com/",
        ];
    });
    return urls;
}
// 单次挑战挂起时长上限: 超过后任务被 request timeout 终止, 再发起下一轮
static const NSTimeInterval kChallengeTimeout = 40.0;

@interface TSAuthKeepAlive ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *activeTask;
@property (nonatomic, strong) dispatch_source_t retryTimer;   // 兜底: 定时确保始终有未决任务
@property (nonatomic, assign) NSUInteger urlIndex;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL challengePending;
@property (nonatomic, assign) NSTimeInterval lastChallengeTime;
@end

@implementation TSAuthKeepAlive

+ (instancetype)shared {
    static TSAuthKeepAlive *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[TSAuthKeepAlive alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = kChallengeTimeout;
        cfg.timeoutIntervalForResource = kChallengeTimeout;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.waitsForConnectivity = NO;
        // delegateQueue = nil → 主队列回调; 挑战状态与探针(主线程)天然串行
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    }
    return self;
}

- (void)start {
    if (_running) return;
    _running = YES;
    [[TSLogStore shared] append:@"[认证保活] 启动 network-authentication 认证挂起会话"];
    [self fireAuthRequest];
    [self startRetryTimer];
}

- (void)stop {
    _running = NO;
    _challengePending = NO;
    if (_retryTimer) {
        dispatch_source_cancel(_retryTimer);
        _retryTimer = nil;
    }
    [_activeTask cancel];
    _activeTask = nil;
}

- (void)fireAuthRequest {
    if (!_running) return;
    if (_activeTask && (_activeTask.state == NSURLSessionTaskStateRunning
                        || _activeTask.state == NSURLSessionTaskStateSuspended)) {
        return;
    }
    NSArray<NSString *> *urls = authURLs();
    if (_urlIndex >= urls.count) _urlIndex = 0;
    NSURL *url = [NSURL URLWithString:urls[_urlIndex]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = kChallengeTimeout;
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req];
    _activeTask = task;
    [task resume];
}

// 兜底 timer: 5s 检查一次, 任务意外结束后立即补发, 保证未决认证状态连续
- (void)startRetryTimer {
    [self stopRetryTimer];
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    _retryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(_retryTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                              5 * NSEC_PER_SEC,
                              1 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_retryTimer, ^{
        TSAuthKeepAlive *s = weakSelf;
        if (!s || !s->_running) return;
        NSURLSessionTask *t = s->_activeTask;
        BOOL needNew = (t == nil) || (t.state == NSURLSessionTaskStateCompleted)
                                || (t.state == NSURLSessionTaskStateCanceling);
        if (needNew) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [s fireAuthRequest];
            });
        }
    });
    dispatch_resume(_retryTimer);
}

- (void)stopRetryTimer {
    if (_retryTimer) {
        dispatch_source_cancel(_retryTimer);
        _retryTimer = nil;
    }
}

#pragma mark - NSURLSessionDelegate

// 服务器级挑战(TLS 信任等): 挂起不回复, 保持挑战未决
- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition,
                             NSURLCredential *credential))completionHandler {
    _challengePending = YES;
    _lastChallengeTime = [NSDate timeIntervalSinceReferenceDate];
    // 故意不调用 completionHandler —— 挑战保持挂起
}

// 任务级挑战(HTTP Basic/Digest 401): 挂起不回复
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition,
                             NSURLCredential *credential))completionHandler {
    _challengePending = YES;
    _lastChallengeTime = [NSDate timeIntervalSinceReferenceDate];
    // 故意不调用 completionHandler —— 挑战保持挂起
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    _challengePending = NO;
    // 挑战超时/网络失败 → 1s 后换下一端点补发, 维持未决认证状态连续
    NSUInteger count = authURLs().count;
    _urlIndex = (_urlIndex + 1) % (count ? count : 1);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf fireAuthRequest];
    });
}

@end
