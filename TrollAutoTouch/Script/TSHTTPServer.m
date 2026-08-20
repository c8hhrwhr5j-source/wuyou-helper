//
//  TSHTTPServer.m
//  TrollAutoTouch
//
//  内嵌 HTTP/WebSocket 服务器实现。
//  基于 BSD sockets + dispatch_source 实现非阻塞 I/O。
//  零外部依赖，纯 Foundation + POSIX。
//

#import "TSHTTPServer.h"
#import "TSScreenCapture.h"
#import "TSDeviceInfo.h"
#import "TSHIDEventTouch.h"
#import "TSScriptEngine.h"
#import "TSPaths.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>

// 脚本网页设置 UI: 网页"开始运行"后由服务器发出, userInfo: {"name":脚本名}
NSNotificationName const TSScriptUIRunRequestNotification = @"TSScriptUIRunRequestNotification";

// 脚本网页设置 UI: 网页"取消"后由服务器发出, userInfo: {"name":脚本名}
NSNotificationName const TSScriptUICancelRequestNotification = @"TSScriptUICancelRequestNotification";

// htonll 在较新 iOS SDK 中已作为宏提供，仅在未定义时自行实现
#ifndef htonll
static inline uint64_t htonll(uint64_t host) {
    return ((uint64_t)htonl((uint32_t)(host >> 32))) | ((uint64_t)htonl((uint32_t)(host & 0xFFFFFFFF)) << 32);
}
#endif

#pragma mark - HTTP 响应工具

static NSData *HTTPResponse(int code, NSString *status, NSString *contentType, NSData *body,
                             NSDictionary<NSString *, NSString *> *_Nullable extraHeaders) {
    NSMutableString *hdr = [NSMutableString string];
    [hdr appendFormat:@"HTTP/1.1 %d %@\r\n", code, status];
    [hdr appendFormat:@"Server: TrollAutoTouch/2.0\r\n"];
    [hdr appendFormat:@"Content-Type: %@\r\n", contentType];
    [hdr appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    [hdr appendString:@"Connection: close\r\n"];
    [hdr appendString:@"Access-Control-Allow-Origin: *\r\n"];
    [hdr appendString:@"Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"];
    [hdr appendString:@"Access-Control-Allow-Headers: Content-Type\r\n"];
    for (NSString *key in extraHeaders) {
        [hdr appendFormat:@"%@: %@\r\n", key, extraHeaders[key]];
    }
    [hdr appendString:@"\r\n"];

    NSMutableData *resp = [NSMutableData dataWithData:[hdr dataUsingEncoding:NSUTF8StringEncoding]];
    [resp appendData:body];
    return resp;
}

#pragma mark - WebSocket 帧

typedef NS_ENUM(uint8_t, WSOpcode) {
    WSOpcodeText   = 0x1,
    WSOpcodeBinary = 0x2,
    WSOpcodeClose  = 0x8,
    WSOpcodePing   = 0x9,
    WSOpcodePong   = 0xA,
};

static NSData *WSFrame(WSOpcode opcode, NSData *payload) {
    NSMutableData *frame = [NSMutableData data];
    uint8_t b0 = 0x80 | opcode;  // FIN + opcode
    [frame appendBytes:&b0 length:1];

    NSUInteger len = payload.length;
    if (len <= 125) {
        uint8_t b1 = (uint8_t)len;
        [frame appendBytes:&b1 length:1];
    } else if (len <= 0xFFFF) {
        uint8_t b1 = 126;
        [frame appendBytes:&b1 length:1];
        uint16_t n = htons((uint16_t)len);
        [frame appendBytes:&n length:2];
    } else {
        uint8_t b1 = 127;
        [frame appendBytes:&b1 length:1];
        uint64_t n = htonll(len);
        [frame appendBytes:&n length:8];
    }
    [frame appendData:payload];
    return frame;
}

static NSData *WSTextFrame(NSString *text) {
    return WSFrame(WSOpcodeText, [text dataUsingEncoding:NSUTF8StringEncoding]);
}

#pragma mark - WebSocket 连接

@interface TSWSConnection : NSObject
@property (nonatomic, assign) int fd;
@property (nonatomic, strong) dispatch_source_t readSource;
@end

@implementation TSWSConnection
@end

#pragma mark - TSHTTPServer

@interface TSHTTPServer () {
    int _listenFd;
    dispatch_source_t _acceptSource;
    NSMutableArray<TSWSConnection *> *_wsClients;
    dispatch_queue_t _serverQueue;
}
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) uint16_t port;
@end

@implementation TSHTTPServer

+ (instancetype)shared {
    static TSHTTPServer *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TSHTTPServer alloc] initWithPort:8080];
    });
    return instance;
}

- (instancetype)initWithPort:(uint16_t)port {
    self = [super init];
    if (self) {
        _port = port;
        _wsClients = [NSMutableArray array];
        _serverQueue = dispatch_queue_create("com.trollautotouch.httpserver", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

#pragma mark - Start/Stop

- (BOOL)start {
    if (_isRunning) return YES;

    _listenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (_listenFd < 0) {
        NSLog(@"[HTTP] socket() 失败: %s", strerror(errno));
        return NO;
    }

    int opt = 1;
    setsockopt(_listenFd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    fcntl(_listenFd, F_SETFL, O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(_port);

    if (bind(_listenFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[HTTP] bind() 失败: %s", strerror(errno));
        close(_listenFd);
        return NO;
    }

    if (listen(_listenFd, 10) < 0) {
        NSLog(@"[HTTP] listen() 失败: %s", strerror(errno));
        close(_listenFd);
        return NO;
    }

    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_listenFd, 0, _serverQueue);
    dispatch_source_set_event_handler(_acceptSource, ^{
        struct sockaddr_in clientAddr;
        socklen_t len = sizeof(clientAddr);
        int clientFd = accept(self->_listenFd, (struct sockaddr *)&clientAddr, &len);
        if (clientFd < 0) return;
        [self handleClient:clientFd];
    });
    dispatch_resume(_acceptSource);

    _isRunning = YES;
    NSLog(@"[HTTP] 服务器已启动 → http://localhost:%d", _port);
    return YES;
}

- (void)stop {
    if (!_isRunning) return;

    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource);
        _acceptSource = nil;
    }
    if (_listenFd >= 0) {
        close(_listenFd);
        _listenFd = -1;
    }

    @synchronized (_wsClients) {
        for (TSWSConnection *ws in _wsClients) {
            if (ws.readSource) dispatch_source_cancel(ws.readSource);
            close(ws.fd);
        }
        [_wsClients removeAllObjects];
    }

    _isRunning = NO;
    NSLog(@"[HTTP] 服务器已停止");
}

#pragma mark - 广播

- (void)broadcastJSON:(NSDictionary *)json {
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    if (!data) return;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSData *frame = WSTextFrame(text);

    @synchronized (_wsClients) {
        for (TSWSConnection *ws in _wsClients) {
            send(ws.fd, frame.bytes, frame.length, 0);
        }
    }
}

- (void)broadcastData:(NSData *)data {
    @synchronized (_wsClients) {
        for (TSWSConnection *ws in _wsClients) {
            send(ws.fd, data.bytes, data.length, 0);
        }
    }
}

#pragma mark - 客户端处理

- (void)handleClient:(int)clientFd {
    int flags = fcntl(clientFd, F_GETFL, 0);
    fcntl(clientFd, F_SETFL, flags | O_NONBLOCK);

    __block NSMutableData *buffer = [NSMutableData data];

    dispatch_source_t readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)clientFd, 0, _serverQueue);
    dispatch_source_set_event_handler(readSource, ^{
        size_t estimated = dispatch_source_get_data(readSource);
        if (estimated == 0) {
            [self closeClient:clientFd source:readSource];
            return;
        }

        uint8_t buf[16384];
        ssize_t n = recv(clientFd, buf, sizeof(buf), 0);
        if (n <= 0) {
            [self closeClient:clientFd source:readSource];
            return;
        }

        [buffer appendBytes:buf length:n];

        // 检查是否 WebSocket 升级
        NSString *head = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding];
        if ([head containsString:@"Upgrade: websocket"]) {
            [self handleWSUpgrade:clientFd request:head source:readSource];
            return;
        }

        // 检查 HTTP 请求是否完整
        if ([head containsString:@"\r\n\r\n"]) {
            NSInteger contentLength = 0;
            NSRange clRange = [head rangeOfString:@"Content-Length: "];
            if (clRange.location != NSNotFound) {
                NSString *clStr = [head substringFromIndex:clRange.location + clRange.length];
                NSRange nl = [clStr rangeOfString:@"\r\n"];
                if (nl.location != NSNotFound) {
                    clStr = [clStr substringToIndex:nl.location];
                }
                contentLength = [clStr integerValue];
            }
            NSRange hEnd = [head rangeOfString:@"\r\n\r\n"];
            NSUInteger bodyStart = hEnd.location + hEnd.length;
            if (buffer.length >= bodyStart + contentLength) {
                [self handleHTTP:clientFd data:buffer source:readSource];
                buffer = [NSMutableData data];
            }
        }
    });
    dispatch_resume(readSource);
}

- (void)closeClient:(int)fd source:(dispatch_source_t)source {
    if (source) {
        dispatch_source_cancel(source);
    }
    close(fd);
    @synchronized (_wsClients) {
        [_wsClients filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(TSWSConnection *ws, id bindings) {
            if (ws.fd == fd) {
                if (ws.readSource) dispatch_source_cancel(ws.readSource);
                return NO;
            }
            return YES;
        }]];
    }
}

#pragma mark - HTTP 路由

- (void)handleHTTP:(int)clientFd data:(NSData *)data source:(dispatch_source_t)readSource {
    NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!raw) { [self sendAndClose:clientFd data:[self errorResponse:400 msg:@"Bad Request"]]; return; }

    NSArray *lines = [raw componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) return;

    // 解析请求行
    NSArray *reqParts = [lines[0] componentsSeparatedByString:@" "];
    if (reqParts.count < 2) { [self sendAndClose:clientFd data:[self errorResponse:400 msg:@"Bad Request"]]; return; }

    NSString *method = reqParts[0];
    NSString *path = reqParts[1];

    // 解析请求体
    NSRange hEnd = [raw rangeOfString:@"\r\n\r\n"];
    NSData *body = nil;
    if (hEnd.location != NSNotFound && hEnd.location + 4 < data.length) {
        body = [data subdataWithRange:NSMakeRange(hEnd.location + 4, data.length - hEnd.location - 4)];
    }

    // 路由分发
    if ([method isEqualToString:@"OPTIONS"]) {
        [self sendAndClose:clientFd data:[self corsResponse]];
    } else if ([path isEqualToString:@"/"] || [path isEqualToString:@"/panel"]) {
        [self serveControlPanel:clientFd];
    } else if ([path hasPrefix:@"/www/"]) {
        [self serveStaticFile:clientFd path:[path substringFromIndex:4]];
    } else if ([path hasPrefix:@"/api/ui/"]) {
        [self handleUIApi:clientFd path:path method:method body:body];
    } else if ([path hasPrefix:@"/ui/"]) {
        [self serveUIFile:clientFd path:[path substringFromIndex:4]];
    } else if ([path isEqualToString:@"/api/screenshot"]) {
        [self serveScreenshot:clientFd];
    } else if ([path isEqualToString:@"/api/stream"]) {
        [self serveMJPEG:clientFd];
    } else if ([path isEqualToString:@"/api/device"]) {
        [self serveDeviceInfo:clientFd];
    } else if ([path isEqualToString:@"/api/tap"] && [method isEqualToString:@"POST"]) {
        [self handleTap:clientFd body:body];
    } else if ([path isEqualToString:@"/api/swipe"] && [method isEqualToString:@"POST"]) {
        [self handleSwipe:clientFd body:body];
    } else if ([path isEqualToString:@"/api/run"] && [method isEqualToString:@"POST"]) {
        [self handleRun:clientFd body:body];
    } else if ([path isEqualToString:@"/api/stop"] && [method isEqualToString:@"POST"]) {
        [self handleStop:clientFd];
    } else if ([path isEqualToString:@"/api/key"] && [method isEqualToString:@"POST"]) {
        [self handleKey:clientFd body:body];
    } else if ([path isEqualToString:@"/api/text"] && [method isEqualToString:@"POST"]) {
        [self handleText:clientFd body:body];
    } else if ([path hasPrefix:@"/image/"]) {
        [self serveStaticFile:clientFd path:path];
    } else {
        [self sendAndClose:clientFd data:[self errorResponse:404 msg:@"Not Found"]];
    }
}

#pragma mark - 路由处理

- (void)serveControlPanel:(int)clientFd {
    NSString *html = [self controlPanelHTML];
    NSData *body = [html dataUsingEncoding:NSUTF8StringEncoding];
    NSData *resp = HTTPResponse(200, @"OK", @"text/html; charset=utf-8", body, @{@"Cache-Control": @"no-cache"});
    [self sendAndClose:clientFd data:resp];
}

- (void)serveStaticFile:(int)clientFd path:(NSString *)path {
    // 安全检查
    if ([path containsString:@".."]) {
        [self sendAndClose:clientFd data:[self errorResponse:403 msg:@"Forbidden"]];
        return;
    }

    NSString *wwwDir = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"www"];
    // 也检查 lua 资源目录
    NSString *filePath = [wwwDir stringByAppendingPathComponent:path];

    NSData *fileData = [NSData dataWithContentsOfFile:filePath];
    if (!fileData) {
        [self sendAndClose:clientFd data:[self errorResponse:404 msg:@"Not Found"]];
        return;
    }

    NSString *ext = path.pathExtension.lowercaseString;
    NSString *mime = @"application/octet-stream";
    if ([ext isEqualToString:@"html"] || [ext isEqualToString:@"htm"]) mime = @"text/html; charset=utf-8";
    else if ([ext isEqualToString:@"css"]) mime = @"text/css";
    else if ([ext isEqualToString:@"js"]) mime = @"application/javascript";
    else if ([ext isEqualToString:@"json"]) mime = @"application/json";
    else if ([ext isEqualToString:@"png"]) mime = @"image/png";
    else if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) mime = @"image/jpeg";
    else if ([ext isEqualToString:@"gif"]) mime = @"image/gif";
    else if ([ext isEqualToString:@"svg"]) mime = @"image/svg+xml";
    else if ([ext isEqualToString:@"ico"]) mime = @"image/x-icon";
    else if ([ext isEqualToString:@"ttf"]) mime = @"font/ttf";
    else if ([ext isEqualToString:@"woff"]) mime = @"font/woff";

    NSData *resp = HTTPResponse(200, @"OK", mime, fileData, @{@"Cache-Control": @"max-age=3600"});
    [self sendAndClose:clientFd data:resp];
}

#pragma mark - 脚本网页设置 UI

// 约定 (参照 AutoJS resources/ui 风格):
//   脚本:     /var/mobile/touch/lua/<name>.lua
//   设置页:   /var/mobile/touch/lua/ui/<name>/index.html (设备, 优先)
//             或 bundle www/ui/<name>/index.html (内置示例)
//   设置数据: /var/mobile/touch/lua/<name>.settings.json
//   运行:     网页 POST /api/ui/run → 保存 settings.json →
//             发出 TSScriptUIRunRequestNotification (name) → 原生运行脚本

- (NSArray<NSString *> *)uiScriptNames {
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    NSFileManager *fm = [NSFileManager defaultManager];
    // 设备设置页目录
    NSString *devUIRoot = [[TSPaths luaDir] stringByAppendingPathComponent:@"ui"];
    for (NSString *dir in [fm contentsOfDirectoryAtPath:devUIRoot error:nil]) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:[[devUIRoot stringByAppendingPathComponent:dir]
                                      stringByAppendingPathComponent:@"index.html"]
                     isDirectory:&isDir] && !isDir) {
            [names addObject:dir];
        }
    }
    // bundle 内置设置页
    NSString *bundleUIRoot = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"www/ui"];
    for (NSString *dir in [fm contentsOfDirectoryAtPath:bundleUIRoot error:nil]) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:[[bundleUIRoot stringByAppendingPathComponent:dir]
                                      stringByAppendingPathComponent:@"index.html"]
                     isDirectory:&isDir] && !isDir) {
            [names addObject:dir];
        }
    }
    return [[names allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (NSString *)uiSettingsPathForName:(NSString *)name {
    return [[TSPaths luaDir]
        stringByAppendingPathComponent:[name stringByAppendingString:@".settings.json"]];
}

// 静态资源: /ui/<name>/<rest> → 设备 ui/<name>/<rest>, 回退 bundle www/ui/<name>/<rest>
- (void)serveUIFile:(int)clientFd path:(NSString *)path {
    NSArray *comps = [path componentsSeparatedByString:@"/"];
    if (comps.count < 2) {
        [self sendAndClose:clientFd data:[self errorResponse:400 msg:@"Bad Request"]];
        return;
    }
    NSString *name = [comps[0] stringByRemovingPercentEncoding];
    NSString *rest = [[comps subarrayWithRange:NSMakeRange(1, comps.count - 1)]
                      componentsJoinedByString:@"/"];
    // 安全: 禁止路径穿越 / 脚本名含斜杠
    if (name.length == 0 || [name containsString:@".."] || [name containsString:@"/"]
        || [rest containsString:@".."]) {
        [self sendAndClose:clientFd data:[self errorResponse:403 msg:@"Forbidden"]];
        return;
    }
    NSString *filePath = [[[[TSPaths luaDir] stringByAppendingPathComponent:@"ui"]
                            stringByAppendingPathComponent:name]
                           stringByAppendingPathComponent:rest];
    NSData *fileData = [NSData dataWithContentsOfFile:filePath];
    if (!fileData) {
        filePath = [[[[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"www/ui"]
                      stringByAppendingPathComponent:name]
                     stringByAppendingPathComponent:rest];
        fileData = [NSData dataWithContentsOfFile:filePath];
    }
    if (!fileData) {
        [self sendAndClose:clientFd data:[self errorResponse:404 msg:@"Not Found"]];
        return;
    }
    NSString *ext = rest.pathExtension.lowercaseString;
    NSString *mime = @"application/octet-stream";
    if ([ext isEqualToString:@"html"] || [ext isEqualToString:@"htm"]) mime = @"text/html; charset=utf-8";
    else if ([ext isEqualToString:@"css"]) mime = @"text/css";
    else if ([ext isEqualToString:@"js"]) mime = @"application/javascript";
    else if ([ext isEqualToString:@"json"]) mime = @"application/json";
    else if ([ext isEqualToString:@"png"]) mime = @"image/png";
    else if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) mime = @"image/jpeg";
    else if ([ext isEqualToString:@"gif"]) mime = @"image/gif";
    else if ([ext isEqualToString:@"svg"]) mime = @"image/svg+xml";
    NSData *resp = HTTPResponse(200, @"OK", mime, fileData, @{@"Cache-Control": @"no-cache"});
    [self sendAndClose:clientFd data:resp];
}

// API: /api/ui/list | /api/ui/settings?name=xxx | /api/ui/run
- (void)handleUIApi:(int)clientFd path:(NSString *)path method:(NSString *)method body:(NSData *)body {
    if ([path isEqualToString:@"/api/ui/list"]) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *name in [self uiScriptNames]) {
            [items addObject:@{@"name": name, @"title": name}];
        }
        [self sendAndClose:clientFd data:[self jsonResponse:@{@"scripts": items}]];
        return;
    }
    if ([path isEqualToString:@"/api/ui/settings"]) {
        NSString *name = [self queryValueForPath:path key:@"name"];
        if (name.length == 0 || [name containsString:@"/"] || [name containsString:@".."]) {
            [self sendAndClose:clientFd data:[self errorResponse:400 msg:@"Bad Request"]];
            return;
        }
        NSString *settingsPath = [self uiSettingsPathForName:name];
        if ([method isEqualToString:@"GET"]) {
            NSDictionary *settings = @{};
            NSData *data = [NSData dataWithContentsOfFile:settingsPath];
            if (data) {
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([obj isKindOfClass:[NSDictionary class]]) settings = obj;
            }
            [self sendAndClose:clientFd data:[self jsonResponse:@{@"name": name, @"settings": settings}]];
            return;
        }
        if ([method isEqualToString:@"POST"]) {
            NSDictionary *json = [self parseJSON:body];
            id settings = json[@"settings"];
            if (![settings isKindOfClass:[NSDictionary class]]) {
                [self sendAndClose:clientFd data:[self errorResponse:400 msg:@"Bad Request"]];
                return;
            }
            NSData *outData = [NSJSONSerialization dataWithJSONObject:settings
                                                              options:NSJSONWritingPrettyPrinted
                                                                error:nil];
            [outData writeToFile:settingsPath atomically:YES];
            [self sendAndClose:clientFd data:[self jsonResponse:@{@"ok": @YES}]];
            return;
        }
    }
    if ([path isEqualToString:@"/api/ui/run"] && [method isEqualToString:@"POST"]) {
        NSDictionary *json = [self parseJSON:body];
        NSString *name = json[@"name"];
        id settings = json[@"settings"];
        if (name.length == 0 || [name containsString:@"/"] || [name containsString:@".."]) {
            [self sendAndClose:clientFd data:[self errorResponse:400 msg:@"Bad Request"]];
            return;
        }
        // 先保存设置
        if ([settings isKindOfClass:[NSDictionary class]]) {
            NSData *outData = [NSJSONSerialization dataWithJSONObject:settings
                                                              options:NSJSONWritingPrettyPrinted
                                                                error:nil];
            [outData writeToFile:[self uiSettingsPathForName:name] atomically:YES];
        }
        // 通知主线程运行脚本 (ViewController / TSScriptUIViewController 监听)
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:TSScriptUIRunRequestNotification
                              object:nil
                            userInfo:@{@"name": name}];
        });
        [self sendAndClose:clientFd data:[self jsonResponse:@{@"ok": @YES}]];
        return;
    }
    if ([path isEqualToString:@"/api/ui/cancel"] && [method isEqualToString:@"POST"]) {
        NSDictionary *json = [self parseJSON:body];
        NSString *name = json[@"name"];
        if (name.length == 0 || [name containsString:@"/"] || [name containsString:@".."]) {
            [self sendAndClose:clientFd data:[self errorResponse:400 msg:@"Bad Request"]];
            return;
        }
        // 通知 UI 容器: 停止当前脚本并关闭设置页
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:TSScriptUICancelRequestNotification
                              object:nil
                            userInfo:@{@"name": name}];
        });
        [self sendAndClose:clientFd data:[self jsonResponse:@{@"ok": @YES}]];
        return;
    }
    [self sendAndClose:clientFd data:[self errorResponse:404 msg:@"Not Found"]];
}

- (NSString *)queryValueForPath:(NSString *)path key:(NSString *)key {
    NSRange q = [path rangeOfString:@"?"];
    if (q.location == NSNotFound) return nil;
    NSString *query = [path substringFromIndex:q.location + 1];
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        NSArray *kv = [pair componentsSeparatedByString:@"="];
        if (kv.count == 2 && [kv[0] isEqualToString:key]) {
            return [kv[1] stringByRemovingPercentEncoding];
        }
    }
    return nil;
}

- (void)serveScreenshot:(int)clientFd {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImage *img = [[TSScreenCapture shared] captureImage];
        NSData *jpeg = UIImageJPEGRepresentation(img, 0.6);
        dispatch_async(self->_serverQueue, ^{
            NSData *resp = HTTPResponse(200, @"OK", @"image/jpeg", jpeg ?: [NSData data], nil);
            send(clientFd, resp.bytes, resp.length, 0);
            close(clientFd);
        });
    });
}

- (void)serveMJPEG:(int)clientFd {
    // MJPEG 流: multipart/x-mixed-replace
    NSString *header = @"HTTP/1.1 200 OK\r\n"
                        "Content-Type: multipart/x-mixed-replace; boundary=--frame\r\n"
                        "Connection: close\r\n"
                        "Cache-Control: no-cache\r\n"
                        "Access-Control-Allow-Origin: *\r\n\r\n";
    send(clientFd, header.UTF8String, strlen(header.UTF8String), 0);

    // 启动定时发送
    __block BOOL streaming = YES;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _serverQueue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC, 0.05 * NSEC_PER_SEC); // ~10fps
    dispatch_source_set_event_handler(timer, ^{
        if (!streaming) { dispatch_source_cancel(timer); return; }

        dispatch_sync(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                UIImage *img = [[TSScreenCapture shared] captureImage];
                NSData *jpeg = UIImageJPEGRepresentation(img, 0.4);
                NSString *part = [NSString stringWithFormat:@"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %lu\r\n\r\n",
                                  (unsigned long)jpeg.length];
                send(clientFd, part.UTF8String, part.length, 0);
                send(clientFd, jpeg.bytes, jpeg.length, 0);
                send(clientFd, "\r\n", 2, 0);
            }
        });
    });
    dispatch_resume(timer);

    // 监听客户端断开
    dispatch_source_t readSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)clientFd, 0, _serverQueue);
    dispatch_source_set_event_handler(readSrc, ^{
        streaming = NO;
        dispatch_source_cancel(readSrc);
    });
    dispatch_resume(readSrc);
}

- (void)serveDeviceInfo:(int)clientFd {
    NSDictionary *info = @{
        @"device": [[TSDeviceInfo shared] fullInfo] ?: @{},
        @"screenSize": @{
            @"width": @([TSDeviceInfo shared].screenSize.width),
            @"height": @([TSDeviceInfo shared].screenSize.height),
        },
        @"scale": @([TSDeviceInfo shared].screenScale),
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:info options:NSJSONWritingPrettyPrinted error:nil];
    NSData *resp = HTTPResponse(200, @"OK", @"application/json", json ?: [NSData data], nil);
    [self sendAndClose:clientFd data:resp];
}

- (void)handleTap:(int)clientFd body:(NSData *)body {
    NSDictionary *json = [self parseJSON:body];
    if (json) {
        CGFloat x = [json[@"x"] floatValue];
        CGFloat y = [json[@"y"] floatValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[TSHIDEventTouch shared] tapAtPoint:CGPointMake(x, y) duration:0.05];
            if ([self.delegate respondsToSelector:@selector(webDidReceiveTap:)]) {
                [self.delegate webDidReceiveTap:CGPointMake(x, y)];
            }
        });
    }
    [self sendAndClose:clientFd data:[self jsonResponse:@{@"ok": @YES}]];
}

- (void)handleSwipe:(int)clientFd body:(NSData *)body {
    NSDictionary *json = [self parseJSON:body];
    if (json) {
        CGFloat x1 = [json[@"x1"] floatValue], y1 = [json[@"y1"] floatValue];
        CGFloat x2 = [json[@"x2"] floatValue], y2 = [json[@"y2"] floatValue];
        NSTimeInterval ms = [json[@"ms"] doubleValue] ?: 300;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[TSHIDEventTouch shared] swipeFromPoint:CGPointMake(x1, y1)
                                            toPoint:CGPointMake(x2, y2)
                                           duration:ms / 1000.0
                                              steps:MAX(2, (NSInteger)(ms / 5))];
        });
    }
    [self sendAndClose:clientFd data:[self jsonResponse:@{@"ok": @YES}]];
}

- (void)handleRun:(int)clientFd body:(NSData *)body {
    NSDictionary *json = [self parseJSON:body];
    NSString *script = json[@"script"];
    if (script.length > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(webDidReceiveScript:)]) {
                [self.delegate webDidReceiveScript:script];
            }
        });
        [self sendAndClose:clientFd data:[self jsonResponse:@{@"ok": @YES, @"message": @"脚本已提交"}]];
    } else {
        [self sendAndClose:clientFd data:[self errorResponse:400 msg:@"缺少 script 参数"]];
    }
}

- (void)handleStop:(int)clientFd {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(webDidReceiveStop)]) {
            [self.delegate webDidReceiveStop];
        }
        [[TSScriptEngine shared] stop];
    });
    [self sendAndClose:clientFd data:[self jsonResponse:@{@"ok": @YES}]];
}

- (void)handleKey:(int)clientFd body:(NSData *)body {
    NSDictionary *json = [self parseJSON:body];
    if (json) {
        uint16_t code = (uint16_t)[json[@"code"] integerValue];
        BOOL down = [json[@"down"] boolValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(webDidReceiveKeyPress:down:)]) {
                [self.delegate webDidReceiveKeyPress:code down:down];
            }
        });
    }
    [self sendAndClose:clientFd data:[self jsonResponse:@{@"ok": @YES}]];
}

- (void)handleText:(int)clientFd body:(NSData *)body {
    NSDictionary *json = [self parseJSON:body];
    if (json && json[@"text"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIPasteboard generalPasteboard].string = json[@"text"];
            if ([self.delegate respondsToSelector:@selector(webDidReceiveText:)]) {
                [self.delegate webDidReceiveText:json[@"text"]];
            }
        });
    }
    [self sendAndClose:clientFd data:[self jsonResponse:@{@"ok": @YES}]];
}

#pragma mark - WebSocket 处理

- (void)handleWSUpgrade:(int)clientFd request:(NSString *)req source:(dispatch_source_t)readSource {
    // 用 readSource 的回调继续接收 WebSocket 帧
    dispatch_source_cancel(readSource); // 取消 HTTP 读取源

    // 解析 Sec-WebSocket-Key
    NSString *key = nil;
    for (NSString *line in [req componentsSeparatedByString:@"\r\n"]) {
        if ([line hasPrefix:@"Sec-WebSocket-Key:"]) {
            key = [[line substringFromIndex:18] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            break;
        }
    }

    if (!key) { close(clientFd); return; }

    // 计算 Accept
    NSString *magic = [key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];
    NSData *sha1 = [self sha1:[magic dataUsingEncoding:NSUTF8StringEncoding]];
    NSString *accept = [sha1 base64EncodedStringWithOptions:0];

    // 发送升级响应
    NSString *resp = [NSString stringWithFormat:
        @"HTTP/1.1 101 Switching Protocols\r\n"
         "Upgrade: websocket\r\n"
         "Connection: Upgrade\r\n"
         "Sec-WebSocket-Accept: %@\r\n"
         "Access-Control-Allow-Origin: *\r\n\r\n", accept];
    send(clientFd, resp.UTF8String, resp.length, 0);

    NSLog(@"[WS] 客户端已连接");

    // 保存连接
    TSWSConnection *ws = [[TSWSConnection alloc] init];
    ws.fd = clientFd;

    // 读取 WebSocket 帧
    dispatch_source_t wsSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)clientFd, 0, _serverQueue);
    __block NSMutableData *wsBuffer = [NSMutableData data];
    ws.readSource = wsSource;

    dispatch_source_set_event_handler(wsSource, ^{
        uint8_t buf[32768];
        ssize_t n = recv(clientFd, buf, sizeof(buf), 0);
        if (n <= 0) {
            [self closeClient:clientFd source:wsSource];
            return;
        }
        [wsBuffer appendBytes:buf length:n];
        [self processWSFrames:wsBuffer clientFd:clientFd];
    });
    dispatch_resume(wsSource);

    @synchronized (_wsClients) {
        [_wsClients addObject:ws];
    }

    // 发送设备信息
    [self broadcastJSON:@{
        @"type": @"device",
        @"screen": @{
            @"width": @([TSDeviceInfo shared].screenSize.width),
            @"height": @([TSDeviceInfo shared].screenSize.height),
        }
    }];
}

- (void)processWSFrames:(NSMutableData *)buffer clientFd:(int)clientFd {
    while (buffer.length >= 2) {
        const uint8_t *b = buffer.bytes;
        WSOpcode opcode = b[0] & 0x0F;
        BOOL masked = (b[1] & 0x80) != 0;
        uint64_t payloadLen = b[1] & 0x7F;

        NSUInteger headerLen = 2;
        if (payloadLen == 126) {
            if (buffer.length < 4) return;
            payloadLen = ntohs(*(uint16_t *)(b + 2));
            headerLen = 4;
        } else if (payloadLen == 127) {
            if (buffer.length < 10) return;
            payloadLen = ntohll(*(uint64_t *)(b + 2));
            headerLen = 10;
        }

        uint8_t maskKey[4] = {0};
        if (masked) {
            if (buffer.length < headerLen + 4) return;
            memcpy(maskKey, b + headerLen, 4);
            headerLen += 4;
        }

        if (buffer.length < headerLen + payloadLen) return;

        // 提取 payload
        NSMutableData *payload = [NSMutableData dataWithLength:(NSUInteger)payloadLen];
        memcpy(payload.mutableBytes, b + headerLen, (NSUInteger)payloadLen);

        if (masked) {
            uint8_t *p = payload.mutableBytes;
            for (NSUInteger i = 0; i < (NSUInteger)payloadLen; i++) {
                p[i] ^= maskKey[i % 4];
            }
        }

        // 处理帧
        switch (opcode) {
            case WSOpcodeText: {
                NSString *msg = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
                [self handleWSMessage:msg clientFd:clientFd];
                break;
            }
            case WSOpcodePing: {
                NSData *pong = WSFrame(WSOpcodePong, payload);
                send(clientFd, pong.bytes, pong.length, 0);
                break;
            }
            case WSOpcodeClose: {
                [self closeClient:clientFd source:nil];
                return;
            }
            default:
                break;
        }

        // 移除已处理的帧
        [buffer replaceBytesInRange:NSMakeRange(0, headerLen + (NSUInteger)payloadLen) withBytes:NULL length:0];
    }
}

- (void)handleWSMessage:(NSString *)msg clientFd:(int)clientFd {
    NSData *data = [msg dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!json) return;

    NSString *type = json[@"type"];
    if (!type) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([type isEqualToString:@"touch"]) {
            NSString *action = json[@"action"];
            CGFloat x = [json[@"x"] floatValue];
            CGFloat y = [json[@"y"] floatValue];

            if ([action isEqualToString:@"down"]) {
                [[TSHIDEventTouch shared] touchDownAtPoint:CGPointMake(x, y) index:0];
            } else if ([action isEqualToString:@"move"]) {
                [[TSHIDEventTouch shared] touchMoveAtPoint:CGPointMake(x, y) index:0];
            } else if ([action isEqualToString:@"up"]) {
                [[TSHIDEventTouch shared] touchUpAtPoint:CGPointMake(x, y) index:0];
            } else if ([action isEqualToString:@"tap"]) {
                [[TSHIDEventTouch shared] tapAtPoint:CGPointMake(x, y) duration:0.05];
            }

            if ([self.delegate respondsToSelector:@selector(webDidReceiveTap:)]) {
                if ([action isEqualToString:@"tap"]) [self.delegate webDidReceiveTap:CGPointMake(x, y)];
            }
        } else if ([type isEqualToString:@"swipe"]) {
            CGFloat x1 = [json[@"x1"] floatValue], y1 = [json[@"y1"] floatValue];
            CGFloat x2 = [json[@"x2"] floatValue], y2 = [json[@"y2"] floatValue];
            NSInteger ms = [json[@"ms"] integerValue] ?: 300;
            [[TSHIDEventTouch shared] swipeFromPoint:CGPointMake(x1, y1) toPoint:CGPointMake(x2, y2)
                                           duration:ms / 1000.0 steps:MAX(2, ms / 5)];
        } else if ([type isEqualToString:@"script"]) {
            if ([self.delegate respondsToSelector:@selector(webDidReceiveScript:)]) {
                [self.delegate webDidReceiveScript:json[@"code"] ?: @""];
            }
        } else if ([type isEqualToString:@"stop"]) {
            [[TSScriptEngine shared] stop];
            if ([self.delegate respondsToSelector:@selector(webDidReceiveStop)]) {
                [self.delegate webDidReceiveStop];
            }
        } else if ([type isEqualToString:@"key"]) {
            uint16_t code = (uint16_t)[json[@"code"] integerValue];
            BOOL down = [json[@"down"] boolValue];
            if ([self.delegate respondsToSelector:@selector(webDidReceiveKeyPress:down:)]) {
                [self.delegate webDidReceiveKeyPress:code down:down];
            }
        }
    });
}

#pragma mark - 工具方法

- (nullable NSDictionary *)parseJSON:(NSData *)data {
    if (!data) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

- (NSData *)jsonResponse:(NSDictionary *)dict {
    NSData *json = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    return HTTPResponse(200, @"OK", @"application/json; charset=utf-8", json ?: [NSData data], nil);
}

- (NSData *)errorResponse:(int)code msg:(NSString *)msg {
    NSDictionary *err = @{@"error": msg};
    NSData *json = [NSJSONSerialization dataWithJSONObject:err options:0 error:nil];
    return HTTPResponse(code, msg, @"application/json; charset=utf-8", json ?: [NSData data], nil);
}

- (NSData *)corsResponse {
    NSData *resp = [@"HTTP/1.1 204 No Content\r\n"
                     "Access-Control-Allow-Origin: *\r\n"
                     "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
                     "Access-Control-Allow-Headers: Content-Type\r\n"
                     "Content-Length: 0\r\n\r\n"
                     dataUsingEncoding:NSUTF8StringEncoding];
    return resp;
}

- (void)sendAndClose:(int)fd data:(NSData *)data {
    send(fd, data.bytes, data.length, 0);
    close(fd);
}

- (NSData *)sha1:(NSData *)input {
    uint8_t digest[20];
    // 使用 CommonCrypto
    CC_SHA1(input.bytes, (CC_LONG)input.length, digest);
    return [NSData dataWithBytes:digest length:20];
}

#pragma mark - 控制面板 HTML

- (NSString *)controlPanelHTML {
    return @"<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"UTF-8\">"
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no\">"
    "<meta name=\"apple-mobile-web-app-capable\" content=\"yes\">"
    "<meta name=\"apple-mobile-web-app-status-bar-style\" content=\"black-translucent\">"
    "<title>TrollAutoTouch 远程控制</title>"
    "<style>"
    "*{margin:0;padding:0;box-sizing:border-box}"
    "body{background:#1a1a2e;color:#e0e0e0;font-family:-apple-system,system-ui,sans-serif;overflow:hidden;height:100vh;display:flex;flex-direction:column}"
    "#toolbar{background:#16213e;padding:8px 12px;display:flex;gap:6px;flex-wrap:wrap;border-bottom:1px solid #0f3460}"
    "#toolbar button{background:#0f3460;color:#e0e0e0;border:none;padding:8px 14px;border-radius:6px;font-size:13px;cursor:pointer;white-space:nowrap}"
    "#toolbar button:active{background:#1a508b}"
    "#toolbar button.danger{background:#6b2020}"
    "#toolbar button.danger:active{background:#8b2e2e}"
    "#toolbar button.accent{background:#1a6b3a}"
    "#status{font-size:12px;color:#7ba3cc;padding:6px 12px;flex:1;text-align:right}"
    "#screenArea{flex:1;position:relative;overflow:hidden;background:#000;display:flex;align-items:center;justify-content:center;touch-action:none}"
    "#screen{max-width:100%;max-height:100%;object-fit:contain;image-rendering:auto}"
    "#overlay{position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none}"
    "#log{background:#0a0a15;color:#4a9;font-family:monospace;font-size:11px;padding:8px 12px;max-height:120px;overflow-y:auto;border-top:1px solid #0f3460;white-space:pre-wrap;word-break:break-all}"
    ".ripple{position:absolute;border-radius:50%;background:rgba(0,255,255,.4);transform:scale(0);animation:ripple .5s ease-out;pointer-events:none}"
    "@keyframes ripple{to{transform:scale(4);opacity:0}}"
    "#panel{z-index:100;position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);background:#16213e;border:2px solid #0f3460;border-radius:12px;padding:16px;display:none;min-width:280px}"
    "#panel textarea{width:100%;height:120px;background:#0a0a15;color:#e0e0e0;border:1px solid #0f3460;border-radius:6px;padding:8px;font-family:monospace;font-size:12px;resize:vertical}"
    "#panel h3{margin-bottom:12px;color:#7ba3cc}"
    "</style></head><body>"
    "<div id=\"toolbar\">"
    "<button onclick=\"toggleStream()\" id=\"streamBtn\">开始串流</button>"
    "<button onclick=\"captureScreenshot()\">截屏</button>"
    "<button onclick=\"openScript()\" class=\"accent\">运行脚本</button>"
    "<button onclick=\"stopAll()\" class=\"danger\">全部停止</button>"
    "<span id=\"status\">未连接</span>"
    "</div>"
    "<div id=\"screenArea\"><img id=\"screen\" src=\"\" alt=\"\"><div id=\"overlay\"></div></div>"
    "<div id=\"log\">🟢 TrollAutoTouch 远程面板已就绪</div>"
    "<div id=\"panel\"><h3>运行脚本</h3><textarea id=\"scriptCode\" placeholder=\"输入 DSL 脚本...\"></textarea><br>"
    "<button onclick=\"runScript()\" style=\"background:#1a6b3a;margin-top:8px\">执行</button>"
    "<button onclick=\"closePanel()\" style=\"float:right;margin-top:8px\">关闭</button></div>"
    "<script>"
    "var ws=null,streaming=false,streamTimer=null;"
    "function log(m){var l=document.getElementById('log');l.innerHTML+=m+'\\n';l.scrollTop=l.scrollHeight;}"
    "function setStatus(s){document.getElementById('status').textContent=s;}"
    "function connect(){"
    "var port=location.port||8080;"
    "ws=new WebSocket('ws://'+location.hostname+':'+port+'/ws');"
    "ws.onopen=function(){setStatus('已连接');log('🟢 WebSocket 已连接');"
    "document.getElementById('streamBtn').style.background='#1a6b3a';};"
    "ws.onclose=function(){setStatus('已断开');log('🔴 连接已断开');streaming=false;"
    "document.getElementById('streamBtn').textContent='开始串流';"
    "document.getElementById('streamBtn').style.background='#0f3460';};"
    "ws.onerror=function(){log('⚠ WebSocket 错误');};"
    "ws.onmessage=function(e){var d=JSON.parse(e.data);if(d.type==='device'){log('📱 设备: '+d.screen.width+'x'+d.screen.height);}};"
    "}"
    "function toggleStream(){"
    "if(streaming){streaming=false;document.getElementById('streamBtn').textContent='开始串流';"
    "document.getElementById('streamBtn').style.background='#0f3460';"
    "if(streamTimer){clearInterval(streamTimer);streamTimer=null;}return;}"
    "streaming=true;document.getElementById('streamBtn').textContent='停止串流';"
    "document.getElementById('streamBtn').style.background='#6b2020';"
    "streamTimer=setInterval(function(){"
    "var img=document.getElementById('screen');"
    "var port=location.port||8080;"
    "img.src='http://'+location.hostname+':'+port+'/api/screenshot?_='+Date.now();"
    "},300);"
    "}"
    "function captureScreenshot(){"
    "var port=location.port||8080;"
    "var img=document.getElementById('screen');"
    "img.src='http://'+location.hostname+':'+port+'/api/screenshot?_='+Date.now();"
    "log('📸 截屏已刷新');"
    "}"
    "function openScript(){document.getElementById('panel').style.display='block';}"
    "function closePanel(){document.getElementById('panel').style.display='none';}"
    "function runScript(){"
    "var code=document.getElementById('scriptCode').value;"
    "if(!code){log('⚠ 请输入脚本内容');return;}"
    "fetch('/api/run',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({script:code})})"
    ".then(function(r){return r.json();}).then(function(d){log('📜 '+d.message);closePanel();});"
    "}"
    "function stopAll(){"
    "fetch('/api/stop',{method:'POST'}).then(function(){log('🛑 脚本已停止');});"
    "}"
    "// 屏幕触摸事件"
    "var touching=false;"
    "document.getElementById('screenArea').addEventListener('pointerdown',function(e){"
    "var r=this.getBoundingClientRect();var x=e.clientX-r.left,y=e.clientY-r.top;"
    "touching=true;"
    "addRipple(x,y);"
    "if(ws&&ws.readyState===WebSocket.OPEN){ws.send(JSON.stringify({type:'touch',action:'down',x:x,y:y}));}"
    "});"
    "document.getElementById('screenArea').addEventListener('pointermove',function(e){"
    "if(!touching)return;var r=this.getBoundingClientRect();var x=e.clientX-r.left,y=e.clientY-r.top;"
    "if(ws&&ws.readyState===WebSocket.OPEN){ws.send(JSON.stringify({type:'touch',action:'move',x:x,y:y}));}"
    "});"
    "document.getElementById('screenArea').addEventListener('pointerup',function(e){"
    "if(!touching)return;touching=false;var r=this.getBoundingClientRect();var x=e.clientX-r.left,y=e.clientY-r.top;"
    "if(ws&&ws.readyState===WebSocket.OPEN){ws.send(JSON.stringify({type:'touch',action:'up',x:x,y:y}));}"
    "});"
    "function addRipple(x,y){"
    "var r=document.createElement('div');r.className='ripple';"
    "r.style.left=x+'px';r.style.top=y+'px';r.style.width='30px';r.style.height='30px';r.style.marginLeft='-15px';r.style.marginTop='-15px';"
    "document.getElementById('overlay').appendChild(r);"
    "setTimeout(function(){r.remove();},600);"
    "}"
    "connect();"
    "</script></body></html>";
}

@end
