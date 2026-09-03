//
//  TSHTTPServer.h
//  TrollAutoTouch
//
//  内嵌轻量 HTTP/WebSocket 服务器 —— 远程控制核心
//
//  用法:
//    TSHTTPServer *server = [[TSHTTPServer alloc] initWithPort:8080];
//    [server start];
//    [server stop];
//
//  端点:
//    GET  /                    → 控制面板 HTML
//    GET  /www/*               → 原版 noVNC WebUI 静态资源
//    GET  /api/screenshot      → 返回 JPEG 截图
//    GET  /api/stream          → MJPEG 实时屏幕流
//    POST /api/tap             → {"x":100,"y":200}
//    POST /api/swipe           → {"x1":100,"y1":200,"x2":300,"y2":400,"ms":500}
//    POST /api/run             → {"script":"..."} 或 {"filename":"main.lua"}（按路径启动，原版 startScriptWithPath: 机制）
//    POST /api/stop            → 停止脚本
//    GET  /task?cmd=start|stop|pause|resume  → 冷启动控制接口 (启动 main.lua, 可加 &file=xxx.lua)
//    GET  /float?x=0|1&y=<物理像素>           → 移动悬浮球 (x=0 左/1 右, y<0 隐藏)
//    GET  /api/device          → 设备信息
//    GET  /api/log?file=debug.log&after=N → 增量读取设备日志
//    WS   /ws                  → WebSocket 双向控制通道
//

#import <Foundation/Foundation.h>

// 冷启动远程控制接口端口。
// 功能与原版(无忧/AutoGoRunner) 8989 的 /task 完全一致, 用独立端口避免与原版工具冲突:
//   GET /task?cmd=start|stop|pause|resume   (start 可加 &file=xxx.lua 指定脚本, 默认当前选中/main.lua)
//   GET /float?x=0|1&y=<物理像素>            (移动/隐藏悬浮球)
// 如需更换端口改这里即可(勿与主服务器 8080 重复, 改后重新打包生效)。
#define TS_COLD_CONTROL_PORT 8686

// 脚本网页设置 UI: 网页点"开始运行"后发出, userInfo: {"name":脚本名}
FOUNDATION_EXPORT NSNotificationName const TSScriptUIRunRequestNotification;

// 脚本网页设置 UI: 网页点"取消"后发出, userInfo: {"name":脚本名}
// UI 容器收到后停止当前脚本并关闭设置页
FOUNDATION_EXPORT NSNotificationName const TSScriptUICancelRequestNotification;

NS_ASSUME_NONNULL_BEGIN

/// 远程控制回调
@protocol TSWebControlDelegate <NSObject>
@optional
- (void)webDidReceiveTap:(CGPoint)point;
- (void)webDidReceiveSwipe:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)ms;
- (void)webDidReceiveScript:(NSString *)script;
/// 按文件路径启动脚本（原版 startScriptWithPath: 机制，path 为 /var/mobile/touch/lua/ 下完整路径）
- (void)webDidReceiveScriptPath:(NSString *)path;
- (void)webDidReceiveStop;
- (void)webDidReceiveKeyPress:(uint16_t)keyCode down:(BOOL)isDown;
- (void)webDidReceiveText:(NSString *)text;
@end

@interface TSHTTPServer : NSObject

/// 全局共享实例（默认端口 8080）
+ (instancetype)shared;

@property (nonatomic, weak, nullable) id<TSWebControlDelegate> delegate;
@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) uint16_t port;

/// 初始化并指定端口
- (instancetype)initWithPort:(uint16_t)port;

/// 启动服务器
- (BOOL)start;

/// 停止服务器
- (void)stop;

/// 向所有 WebSocket 客户端广播消息
- (void)broadcastJSON:(NSDictionary *)json;

/// 向所有 WebSocket 客户端发送二进制数据
- (void)broadcastData:(NSData *)data;

/// 有网页设置 UI 的脚本名列表
- (NSArray<NSString *> *)uiScriptNames;

@end

NS_ASSUME_NONNULL_END
