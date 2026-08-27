//
//  TSLuaBridge.m
//  TrollAutoTouch
//
//  Lua 5.4 脚本引擎桥接 —— 对齐原版 TrollAutoScript 的 Lua 脚本 API。
//
//  原版 TrollAutoScript 用 Lua 5.x + 原生 .so 扩展作为脚本层，
//  本类嵌入 Lua 5.4 并注册了原版 TouchScript 风格的全局函数:
//    findColor / findColors / findImage / getColor
//    tap / touchDown / touchMove / touchUp / swipe / stroke
//    snapshot / keepScreen / getScreenSize
//    mSleep / logStr / toast
//  以及命名模块: touch / screen / sys / device / json / appNode / app
//    pasteboard / plist / file / key / str
//
//  线程模型:
//    - 所有 Lua 脚本在同一个后台串行队列(global_queue)执行，避免并发访问 lua_State。
//    - 停止标志用 volatile BOOL 无锁读写，不持有 self 锁，
//      保证主线程点"停止"时能立即生效，不会因脚本持有锁而卡死主线程。
//    - 日志回调在主线程调用 logHandler。

#import "TSLuaBridge.h"
#import "TSCrashReporter.h"
#import "../Common/TSLogStore.h"
#import "../HUD/TSHUDHost.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <MediaPlayer/MediaPlayer.h>
#import <mach/mach.h>

NSNotificationName const TSLuaRunningStateChangedNotification = @"TSLuaRunningStateChanged";
#import <CommonCrypto/CommonDigest.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#import <string.h>
#import "../vendor/lua/lua.h"
#import "../vendor/lua/lauxlib.h"
#import "../vendor/lua/lualib.h"
#import "TSScreenCapture.h"
#import "TSColorFinder.h"
#import "TSHIDEventTouch.h"
#import "TSAudioKeepAlive.h"
#import "TSAppManager.h"
#import "TSKeyboardInjector.h"
#import "TSTemplateMatcher.h"
#import "TSAppNodeInfo.h"
#import "TSDeviceInfo.h"
#import "TSOCREngine.h"
#import "../Common/TSPaths.h"
#import "../Core/TSVolumeKeyMonitor.h"
#import "../Core/TSHUDService.h"
#import "../HUD/TSHUDHost.h"
#import "../HUD/TSHUDWindow.h"
#import "../Views/TSScriptUIViewController.h"
#import "TSScriptListViewController.h"
#import "../Core/TSToolExecutor.h"
#import "TSScriptCipher.h"
#import "TSTrialManager.h"

// ────────────────────────── 前向声明 ──────────────────────────
static void _pushNSObjectToLua(lua_State *L, id obj);

// 跨线程标志: Lua 后台线程读、主线程(停止按钮)写。
// 必须用 volatile + 无锁赋值，绝不能放在 @synchronized(self) 里——
// 否则脚本运行期间 Lua 线程持有 self 锁, 主线程 stop 抢锁会永久阻塞, 应用卡死。
static volatile BOOL _stopRequested = NO;
// 暂停标志: 由音量键控制面板/主界面"暂停"按钮设置。
// 与 _stopRequested 一样跨线程, 必须 volatile + 无锁赋值。
static volatile BOOL _pauseRequested = NO;

@interface TSLuaBridge ()
- (void)_execute:(NSString *)code filePath:(nullable NSString *)path;
- (void)_handleVolumeKey;
- (void)_presentInAppVolumeMenu;
- (void)_presentBackgroundVolumeMenu;
- (void)_handleIdleVolumeKey;
- (void)_togglePauseBackground;
- (void)_injectSettingsTable:(lua_State *)L scriptPath:(NSString *)path;
// App 内音量键控制菜单(注入失败兜底), 脚本结束时需自动关闭
@property (nonatomic, weak) UIAlertController *volumeMenuAlert;
@end

@implementation TSLuaBridge {
    dispatch_queue_t _luaQueue;
}

+ (instancetype)shared {
    static TSLuaBridge *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [TSLuaBridge new];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _luaQueue = dispatch_queue_create("com.trollautotouch.lua", DISPATCH_QUEUE_SERIAL);
        self.isRunning = NO;
        // senderID 就绪时输出到脚本日志，方便确认注入链路是否打通
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_handleSenderIDDidChange:)
                                                     name:TSHIDSenderIDDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)_handleSenderIDDidChange:(NSNotification *)note {
    uint64_t sid = [note.userInfo[@"senderID"] unsignedLongLongValue];
    lua_log([NSString stringWithFormat:@"[touch] 已获取真实触摸 senderID: 0x%llX, 点击注入已就绪", sid]);
}

- (void)setIsRunning:(BOOL)isRunning {
    _isRunning = isRunning;
    [[NSNotificationCenter defaultCenter] postNotificationName:TSLuaRunningStateChangedNotification
                                                        object:self
                                                      userInfo:@{@"running": @(isRunning)}];
}

#pragma mark - 日志

// 程序自身产生的日志(引擎诊断/运行时/toast 记录等) → 写 touch.log + UI
static void lua_log(NSString *msg) {
    if (msg.length == 0) return;
    // 全局日志存储: 内部线程安全 + 批量异步写文件, 不碰主线程。
    [[TSLogStore shared] append:msg];
    // UI 日志: 直接回调 logHandler。ViewController 的 _log: 内部按 50ms
    // 聚合节流刷新(任意线程可调用), 不再逐条向主线程派发, 避免脚本高频
    // 日志时主线程队列堆积 → App 假死/脚本停摆。
    TSLuaBridge *bridge = [TSLuaBridge shared];
    if (bridge.logHandler) {
        bridge.logHandler(msg);
    }
}

// main.lua 主动写入的日志(log/logStr/print) → 写 debug.log + UI。
// 与程序自身日志(touch.log)严格分流, 两类日志不混在一个文件。
static void lua_script_log(NSString *msg) {
    if (msg.length == 0) return;
    [[TSLogStore shared] append:msg toFile:@"debug.log"];
    TSLuaBridge *bridge = [TSLuaBridge shared];
    if (bridge.logHandler) {
        bridge.logHandler(msg);
    }
}

/// 把 Lua 字符串(UTF-8 字节)安全转为 NSString。
/// 显式按 UTF-8 解码，避免 %s 依赖系统默认编码导致中文乱码；
/// 非 UTF-8 输入时回退 Latin-1，保证所有字节都能显示。
static NSString *luaToNSString(const char *s, size_t len) {
    if (!s || len == 0) return @"";
    NSString *str = [[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding];
    if (str) return str;
    return [[NSString alloc] initWithBytes:s length:len encoding:NSISOLatin1StringEncoding];
}

/// 屏幕物理像素尺寸(逻辑点 × scale)，Lua 脚本统一使用物理像素坐标
static CGSize screenPixelSize(void) {
    CGSize s = [UIScreen mainScreen].bounds.size;
    CGFloat scale = [UIScreen mainScreen].scale;
    return CGSizeMake(s.width * scale, s.height * scale);
}

/// 触摸注入用的缩放系数（TSHIDEventTouch 使用逻辑点坐标，Lua 层是物理像素）
static CGFloat touchScale(void) {
    return [UIScreen mainScreen].scale;
}

// ────────────────────────── 屏幕方向 (screen.init) ──────────────────────────
// 脚本坐标系方向, 由 screen.init(0/1/2) 设置, 默认 0 (home 在下)。
// 语义与文档一致: 0=home在下(竖屏) 1=home在右 2=home在左。
// 设置后, Lua 层触摸/取色/找色的坐标统一按脚本坐标系解释, 引擎在注入/取色前
// 自动旋转到屏幕物理方向(竖屏/fixedCoordinateSpace) —— 截屏缓冲与 HID 事件均基于该坐标系;
// findText/appNode 的返回值则是从 UIKit 坐标(设备实际方向)旋转回脚本坐标系。
static NSInteger s_scriptOrientation = 0;

// 设备当前实际方向: 0=home在下 1=home在右 2=home在左 (由当前窗口方向决定)
static NSInteger tsCurrentOrientation(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIInterfaceOrientation io = UIInterfaceOrientationPortrait;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if ([sc isKindOfClass:UIWindowScene.class]) {
            UIInterfaceOrientation o = ((UIWindowScene *)sc).interfaceOrientation;
            if (o != UIInterfaceOrientationUnknown) { io = o; break; }
        }
    }
#pragma clang diagnostic pop
    switch (io) {
        case UIInterfaceOrientationLandscapeLeft:  return 1; // home 在右
        case UIInterfaceOrientationLandscapeRight: return 2; // home 在左
        case UIInterfaceOrientationPortrait:
        case UIInterfaceOrientationPortraitUpsideDown:
        default: return 0;
    }
}

// 竖屏(物理方向)逻辑点尺寸: fixedCoordinateSpace 不受旋转影响, 始终返回物理方向 bounds。
static CGSize tsPortraitPointSize(void) {
    return [UIScreen mainScreen].fixedCoordinateSpace.bounds.size;
}

// 竖屏(物理方向)物理像素尺寸
static CGSize tsPortraitPixelSize(void) {
    CGSize s = tsPortraitPointSize();
    CGFloat scale = [UIScreen mainScreen].scale;
    return CGSizeMake(s.width * scale, s.height * scale);
}

// 坐标系变换核心: 把点 p 从 from 方向坐标旋转到 to 方向坐标。
// portraitSize 为竖屏(物理方向)尺寸, 单位须与 p 一致(逻辑点/物理像素均可)。
// 以竖屏为基准 (Wp=竖屏宽, Hp=竖屏高):
//   home右(x,y) -> portrait (Wp-y, x);  portrait -> home右 (Y, Wp-X)
//   home左(x,y) -> portrait (y, Hp-x);  portrait -> home左 (Hp-Y, X)
// 注意: 本函数是"连续坐标"版本(旋转不减 1), 用于 UIKit 逻辑点坐标(appNode/findText 返回值);
// 像素索引版本见 tsTransformPixelPoint, 用于脚本像素坐标 <-> 截屏缓冲像素。
static CGPoint tsTransformPoint(CGPoint p, NSInteger from, NSInteger to, CGSize portraitSize) {
    if (from == to) return p;   // 方向一致时恒等, 零开销
    CGFloat Wp = portraitSize.width;
    CGFloat Hp = portraitSize.height;
    CGFloat X, Y;
    switch (from) {
        case 1: X = Wp - p.y; Y = p.x; break;        // home 右 -> portrait
        case 2: X = p.y;      Y = Hp - p.x; break;   // home 左 -> portrait
        default: X = p.x; Y = p.y; break;            // portrait
    }
    switch (to) {
        case 1: return CGPointMake(Y, Wp - X);        // portrait -> home 右
        case 2: return CGPointMake(Hp - Y, X);        // portrait -> home 左
        default: return CGPointMake(X, Y);            // portrait
    }
}

// 像素索引坐标变换: 旋转分支按像素索引(W-1)处理。
// 截屏缓冲像素与第三方取色软件(横屏时左上角为(0,0))都采用像素索引模型:
//   竖屏像素 (585,959) == 横屏(home右)像素 (959, 750-1-585) = (959,164)
// 所以脚本像素坐标 <-> 截屏缓冲像素坐标的 90° 旋转必须减 1,
// 否则会差 1 像素, 导致 getColor/click 在横屏下取错像素(公告关闭按钮 (959,164) 实测偏出按钮颜色区)。
static CGPoint tsTransformPixelPoint(CGPoint p, NSInteger from, NSInteger to, CGSize portraitSize) {
    if (from == to) return p;   // 方向一致时恒等, 零开销
    CGFloat Wp = portraitSize.width;
    CGFloat Hp = portraitSize.height;
    CGFloat X, Y;
    switch (from) {
        case 1: X = Wp - 1 - p.y; Y = p.x; break;            // home 右 -> portrait
        case 2: X = p.y;          Y = Hp - 1 - p.x; break;   // home 左 -> portrait
        default: X = p.x; Y = p.y; break;                    // portrait
    }
    switch (to) {
        case 1: return CGPointMake(Y, Wp - 1 - X);            // portrait -> home 右
        case 2: return CGPointMake(Hp - 1 - Y, X);            // portrait -> home 左
        default: return CGPointMake(X, Y);                    // portrait
    }
}

// 像素索引坐标变换: 矩形 (旋转 90° 后仍是轴对齐矩形, 变换四角取外接即可)
static CGRect tsTransformPixelRect(CGRect r, NSInteger from, NSInteger to, CGSize portraitSize) {
    if (from == to) return r;
    CGPoint p1 = tsTransformPixelPoint(r.origin, from, to, portraitSize);
    CGPoint p2 = tsTransformPixelPoint(CGPointMake(CGRectGetMaxX(r), r.origin.y), from, to, portraitSize);
    CGPoint p3 = tsTransformPixelPoint(CGPointMake(r.origin.x, CGRectGetMaxY(r)), from, to, portraitSize);
    CGPoint p4 = tsTransformPixelPoint(CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r)), from, to, portraitSize);
    CGFloat minX = MIN(MIN(p1.x, p2.x), MIN(p3.x, p4.x));
    CGFloat minY = MIN(MIN(p1.y, p2.y), MIN(p3.y, p4.y));
    CGFloat maxX = MAX(MAX(p1.x, p2.x), MAX(p3.x, p4.x));
    CGFloat maxY = MAX(MAX(p1.y, p2.y), MAX(p3.y, p4.y));
    return CGRectMake(minX, minY, maxX - minX, maxY - minY);
}

// 脚本坐标系(物理像素) -> 屏幕物理方向(竖屏/fixedCoordinateSpace, 物理像素): 触摸/取色/找色入口用。
// 注意: 目标方向固定为 0(竖屏), 而不是设备当前实际方向 ——
//   * 截屏(TSScreenCapture createScreenIOSurface)像素缓冲固定为物理竖屏尺寸, 横屏时只是内容旋转;
//   * IOHID digitizer 事件坐标按屏幕固定坐标系(fixedCoordinateSpace)归一化解释。
// 因此脚本坐标必须统一旋转到竖屏物理方向, 与缓冲/事件坐标系对齐; 用 cur 会导致 init(1) 后坐标错位。
// 像素旋转统一走 tsTransformPixelPoint(旋转分支减 1): 与取色软件横屏坐标(左上角 0,0)严格一致,
// 这样取色软件直接给出的横屏坐标可原样用于 getColor/click, 无需手动 ±1。
static CGPoint tsScriptToActualPoint(CGPoint p) {
    return tsTransformPixelPoint(p, s_scriptOrientation, 0, tsPortraitPixelSize());
}
static CGRect tsScriptToActualRect(CGRect r) {
    return tsTransformPixelRect(r, s_scriptOrientation, 0, tsPortraitPixelSize());
}
// 偏移点向量旋转: 脚本坐标系(横屏方向) -> 竖屏buffer坐标系。
// rect 由 tsScriptToActualRect 旋转到竖屏buffer, 偏移向量必须同步旋转,
// 否则横屏(init 1/2)下偏移点方向错位 90°, 导致多点找色"主色命中但偏移点不匹配"。
//   home右(1): 向量(dx,dy) -> (-dy, dx);  home左(2): 向量(dx,dy) -> (dy, -dx);  竖屏(0): 恒等
static void tsRotateOffsets(NSMutableArray<NSDictionary *> *offsets, NSInteger from) {
    if (from == 0 || offsets.count == 0) return;
    for (NSUInteger i = 0; i < offsets.count; i++) {
        NSDictionary *o = offsets[i];
        CGFloat dx = [o[@"x"] doubleValue];
        CGFloat dy = [o[@"y"] doubleValue];
        CGFloat nx, ny;
        if (from == 1) { nx = -dy; ny = dx; }   // home 右
        else           { nx = dy;  ny = -dx; }  // home 左
        offsets[i] = @{@"x": @(nx), @"y": @(ny), @"color": o[@"color"]};
    }
}
// buffer(竖屏物理方向, 像素) -> 脚本坐标系(像素): findColor/findColors/findImage/OCR 返回值用,
// 否则 init(1) 下拿到的是截屏缓冲坐标, 直接 click 会二次错位。
static CGPoint tsBufferToScriptPoint(CGPoint p) {
    return tsTransformPixelPoint(p, 0, s_scriptOrientation, tsPortraitPixelSize());
}
// 设备实际方向(逻辑点) -> 脚本坐标系(逻辑点): findText/appNode 返回值用
static CGPoint tsActualToScriptPoint(CGPoint p) {
    return tsTransformPoint(p, tsCurrentOrientation(), s_scriptOrientation, tsPortraitPointSize());
}

// 竖屏 buffer 图像 -> 脚本方向图像(OCR 专用)。
// 截屏缓冲固定为竖屏物理方向(750x1334), 横屏时 buffer 里文字是旋转 90° 的竖排,
// Vision(VNRecognizeTextRequest)只识别水平文字, 直接识别必然返回空。
// 这里把整图旋回脚本方向(旋转后尺寸 = 横屏像素), 之后 region 直接用脚本坐标, 返回坐标也是脚本坐标。
//   home右(1): buffer 逆时针 90°;  home左(2): buffer 顺时针 90°;  竖屏(0): 恒等。
static UIImage *tsRotateToScriptOrientation(UIImage *img) {
    if (s_scriptOrientation == 0 || !img) return img;
    CGFloat w = img.size.width, h = img.size.height;
    CGSize newSize = CGSizeMake(h, w);
    UIGraphicsBeginImageContextWithOptions(newSize, NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (s_scriptOrientation == 1) {            // home 右: 逆时针 90°
        CGContextTranslateCTM(ctx, 0, newSize.height);
        CGContextRotateCTM(ctx, -M_PI_2);
    } else {                                   // home 左: 顺时针 90°
        CGContextTranslateCTM(ctx, newSize.width, 0);
        CGContextRotateCTM(ctx, M_PI_2);
    }
    [img drawInRect:CGRectMake(0, 0, w, h)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out;
}

#pragma mark - Lua 工具

static int l_global_print(lua_State *L) {
    int n = lua_gettop(L);
    NSMutableString *s = [NSMutableString string];
    for (int i = 1; i <= n; i++) {
        if (i > 1) [s appendString:@"\t"];
        size_t len = 0;
        const char *str = luaL_tolstring(L, i, &len);
        [s appendString:luaToNSString(str, len)];
        lua_pop(L, 1);
    }
    // 脚本主动 print → debug.log
    lua_script_log([NSString stringWithFormat:@"[Lua] %@", s]);
    return 0;
}

static int l_global_logStr(lua_State *L) {
    size_t len = 0;
    const char *s = luaL_checklstring(L, 1, &len);
    // 脚本主动 log/logStr → debug.log
    lua_script_log([NSString stringWithFormat:@"[Lua] %@", luaToNSString(s, len)]);
    return 0;
}

// sys.toast(提示消息, [显示时间毫秒], [是否隐藏])
//   非阻塞: 通过 HUD 宿主 (TSHUDHost + SBS 系统级托管) 在任意前台 App 之上
//   短暂显示提示, 自动消失, 不影响脚本继续执行。
//   显示时间默认 1000 毫秒; 是否隐藏=true 时用屏幕顶部小字弱化样式,
//   尽量不占用屏幕中部找色区域 (对应原版 sys.toast 的"是否隐藏"语义)。
static int l_sys_toast(lua_State *L) {
    size_t mlen = 0;
    const char *msg = luaL_checklstring(L, 1, &mlen);
    NSString *message = luaToNSString(msg, mlen);

    NSTimeInterval duration = 1.0;
    if (lua_type(L, 2) == LUA_TNUMBER) {
        duration = lua_tonumber(L, 2) / 1000.0; // 毫秒 -> 秒
    }

    BOOL hidden = NO;
    if (lua_type(L, 3) == LUA_TBOOLEAN) hidden = lua_toboolean(L, 3);

    lua_log([NSString stringWithFormat:@"[toast] %@ (%gms, hidden=%d)",
             message, duration * 1000, hidden]);

    // showToast 内部异步派发到主线程, 这里立即返回 (非阻塞)。
    [[TSHUDHost shared] showToast:message duration:duration hidden:hidden];
    return 0;
}

static int l_global_toast(lua_State *L) {
    // 全局 toast(消息) 与 sys.toast 等效, 保持历史兼容
    return l_sys_toast(L);
}

static int l_global_mSleep(lua_State *L) {
    double ms = luaL_checknumber(L, 1);
    if (ms > 0) {
        // 分段睡眠，最多 50ms 检查一次停止标志，保证停止响应迅速
        double remaining = ms / 1000.0;
        while (remaining > 0) {
            double chunk = MIN(remaining, 0.05);
            usleep((useconds_t)(chunk * 1000000));
            remaining -= chunk;
            if (_pauseRequested && !_stopRequested) {
                while (_pauseRequested && !_stopRequested) {
                    usleep(50 * 1000);
                }
            }
            if (_stopRequested) {
                return luaL_error(L, "脚本已被停止");
            }
        }
    } else if (_stopRequested) {
        return luaL_error(L, "脚本已被停止");
    }
    return 0;
}

// sleep 是全局延时，供 findColor 等待画面出现用
static int l_global_sleep(lua_State *L) {
    double sec = luaL_checknumber(L, 1);
    if (sec > 0) {
        double remaining = sec;
        while (remaining > 0) {
            double chunk = MIN(remaining, 0.05);
            usleep((useconds_t)(chunk * 1000000));
            remaining -= chunk;
            if (_pauseRequested && !_stopRequested) {
                while (_pauseRequested && !_stopRequested) {
                    usleep(50 * 1000);
                }
            }
            if (_stopRequested) {
                return luaL_error(L, "脚本已被停止");
            }
        }
    } else if (_stopRequested) {
        return luaL_error(L, "脚本已被停止");
    }
    return 0;
}

#pragma mark - 屏幕尺寸

static int l_screen_getSize(lua_State *L) {
    // 返回脚本坐标系下的屏幕物理像素尺寸: 竖屏坐标(0) -> (Wp,Hp); 横屏坐标(1/2) -> (Hp,Wp)。
    // 只与脚本坐标系方向有关, 与设备实际方向无关。
    CGSize s = screenPixelSize();
    if (s_scriptOrientation != 0) {
        s = CGSizeMake(s.height, s.width);
    }
    lua_pushnumber(L, s.width);
    lua_pushnumber(L, s.height);
    return 2;
}

/// 初始化坐标系方向: screen.init(0|1|2)  (0=home在下 1=home在右 2=home在左)
/// 设置后, 触摸/取色/找色的坐标都按该方向解释, 引擎自动旋转适配设备当前实际方向。
static int l_screen_init(lua_State *L) {
    NSInteger dir = (NSInteger)luaL_checkinteger(L, 1);
    if (dir < 0 || dir > 2) {
        lua_log(@"screen.init 方向参数必须为 0/1/2 (0=home在下, 1=home在右, 2=home在左)");
        return 0;
    }
    s_scriptOrientation = dir;
    static const char *names[] = {"home在下(竖屏)", "home在右", "home在左"};
    lua_log([NSString stringWithFormat:@"screen.init: 坐标系方向已设为 %s (当前设备: %s)",
             names[dir], names[tsCurrentOrientation()]]);
    // 联动 HUD: toast/弹窗内容层旋转到与脚本坐标系一致 (横屏游戏时横屏显示)
    [[TSHUDHost shared] setScriptOrientation:dir];
    return 0;
}

#pragma mark - 截屏/找色

/// Lua 指令计数钩子: 每执行 N 条指令检查一次停止标志。
/// 这样即使脚本是死循环(如 while true do end，不调用 mSleep/sleep)，
/// 点击"停止"后也能被 lua_pcall 的 longjmp 中断，而不是无限跑下去。
static void luaStopHook(lua_State *L, lua_Debug *ar) {
    if (_pauseRequested && !_stopRequested) {
        // 暂停: 阻塞 Lua 线程直到 resume 或 stop。
        // Lua 线程阻塞不影响触摸注入(触摸走独立 TCP 链路到 SpringBoard),
        // 也不影响主线程(停止按钮/音量键面板事件在主线程处理)。
        while (_pauseRequested && !_stopRequested) {
            usleep(50 * 1000);
        }
    }
    if (_stopRequested) {
        // 先移除钩子再抛错，避免 longjmp 后重复进入钩子导致二次错误
        lua_sethook(L, NULL, 0, 0);
        luaL_error(L, "脚本已被停止");
    }
}

/// 取整屏 RGBA 像素，返回给调用方(需 free)
/// 若已 screen.keep()/keepScreen(true) 缓存，则直接返回缓存副本(不再重复截屏，找色找图性能极大提升)；
/// 无缓存则新截屏(截屏偶尔会失败，重试最多 3 次)。
/// 限频: 距上次成功截屏 < 60ms 时直接复用上次像素副本 —— 防止无 mSleep 的死循环脚本
/// 以最大频率反复截屏，把设备 CPU(全屏像素转储)打满导致整体卡顿"假死"。60ms≈16fps，
/// 对找色脚本足够；脚本带 mSleep(≥100ms) 时不受影响。
static BOOL grabScreen(uint8_t **pxOut, int *wOut, int *hOut) {
    // 优先复用 keep 缓存: screen.keep() 后多次 findColor/findColors/getColor 读取同一帧像素
    if ([[TSScreenCapture shared] getCachedPixels:pxOut width:wOut height:hOut]) {
        return YES;
    }
    // 限频复用上次像素(本函数只在 Lua 后台队列线程调用, static 无并发问题)
    static NSTimeInterval lastGrabAt = 0;
    static uint8_t *lastPx = NULL;
    static int lastW = 0, lastH = 0;
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if (lastPx && lastW > 0 && lastH > 0 && (now - lastGrabAt) < 0.06) {
        uint8_t *copy = malloc((size_t)lastW * (size_t)lastH * 4);
        if (copy) {
            memcpy(copy, lastPx, (size_t)lastW * (size_t)lastH * 4);
            *pxOut = copy; *wOut = lastW; *hOut = lastH;
            return YES;
        }
    }
    // 截屏偶尔会失败(帧缓冲 surface 未就绪/主线程忙/动画中)，重试最多 3 次
    for (int attempt = 0; attempt < 3; attempt++) {
        if ([[TSScreenCapture shared] captureScreenToRGBA:pxOut width:wOut height:hOut] && *pxOut) {
            if (lastPx) { free(lastPx); }
            lastPx = *pxOut; lastW = *wOut; lastH = *hOut;
            lastGrabAt = now;
            return YES;
        }
        if (attempt < 2) {
            usleep(50 * 1000);
        }
    }
    return NO;
}

/// 解析可选区域参数: (x, y, w, h) 或 table {x=,y=,width=,height=} 或空(全屏)
/// 返回 rect，并返回剩余参数起始索引
static CGRect l_optRect(lua_State *L, int idx, int *nextIdx) {
    CGSize ss = [UIScreen mainScreen].bounds.size;
    if (lua_istable(L, idx)) {
        lua_getfield(L, idx, "x");          CGFloat x = luaL_optnumber(L, -1, 0); lua_pop(L, 1);
        lua_getfield(L, idx, "y");          CGFloat y = luaL_optnumber(L, -1, 0); lua_pop(L, 1);
        lua_getfield(L, idx, "width");      CGFloat w = luaL_optnumber(L, -1, 0); lua_pop(L, 1);
        lua_getfield(L, idx, "height");     CGFloat h = luaL_optnumber(L, -1, 0); lua_pop(L, 1);
        if (w == 0 && h == 0) { return CGRectZero; }
        if (nextIdx) *nextIdx = idx + 1;
        return CGRectMake(x, y, w, h);
    }
    if (lua_isnumber(L, idx) && lua_isnumber(L, idx + 3)) {
        CGFloat x = luaL_checknumber(L, idx);
        CGFloat y = luaL_checknumber(L, idx + 1);
        CGFloat w = luaL_checknumber(L, idx + 2);
        CGFloat h = luaL_checknumber(L, idx + 3);
        if (nextIdx) *nextIdx = idx + 4;
        return CGRectMake(x, y, w, h);
    }
    if (nextIdx) *nextIdx = idx;
    return CGRectZero;
}

/// 解析偏移点表: {{dx=,dy=,color=,tolR=,tolG=,tolB=} 或 {dx,dy,color}, ...}
///   tolR/tolG/tolB 为逐通道容差(可选), tolerance 为统一三通道容差(可选)
static NSArray<NSDictionary *> *l_parseOffsets(lua_State *L, int idx) {
    NSMutableArray *offsets = [NSMutableArray array];
    if (!lua_istable(L, idx)) return offsets;
    lua_len(L, idx);
    int n = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);
    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, idx, i);
        if (lua_istable(L, -1)) {
            // 支持 {dx=,dy=,color=} 或 {dx,dy,color}
            lua_getfield(L, -1, "dx"); BOOL hasDx = !lua_isnil(L, -1); lua_pop(L, 1);
            lua_getfield(L, -1, "dy"); BOOL hasDy = !lua_isnil(L, -1); lua_pop(L, 1);
            lua_getfield(L, -1, "color"); BOOL hasColor = !lua_isnil(L, -1); lua_pop(L, 1);
            // 可选逐通道容差
            lua_getfield(L, -1, "tolR"); BOOL hasTolR = !lua_isnil(L, -1); lua_pop(L, 1);
            lua_getfield(L, -1, "tolG"); BOOL hasTolG = !lua_isnil(L, -1); lua_pop(L, 1);
            lua_getfield(L, -1, "tolB"); BOOL hasTolB = !lua_isnil(L, -1); lua_pop(L, 1);
            lua_getfield(L, -1, "tolerance"); BOOL hasTol = !lua_isnil(L, -1); lua_pop(L, 1);
            NSMutableDictionary *md = [NSMutableDictionary dictionary];
            if (hasTolR) { lua_getfield(L, -1, "tolR"); md[@"tolR"] = @((int)lua_tointeger(L, -1)); lua_pop(L, 1); }
            if (hasTolG) { lua_getfield(L, -1, "tolG"); md[@"tolG"] = @((int)lua_tointeger(L, -1)); lua_pop(L, 1); }
            if (hasTolB) { lua_getfield(L, -1, "tolB"); md[@"tolB"] = @((int)lua_tointeger(L, -1)); lua_pop(L, 1); }
            if (hasTol)  { lua_getfield(L, -1, "tolerance");
                           int t = (int)lua_tointeger(L, -1); lua_pop(L, 1);
                           md[@"tolR"] = md[@"tolG"] = md[@"tolB"] = @(t); }
            if (hasDx || hasDy || hasColor) {
                lua_getfield(L, -1, "dx");  double dx = luaL_optnumber(L, -1, 0); lua_pop(L, 1);
                lua_getfield(L, -1, "dy");  double dy = luaL_optnumber(L, -1, 0); lua_pop(L, 1);
                lua_getfield(L, -1, "color"); int color = (int)luaL_optinteger(L, -1, 0); lua_pop(L, 1);
                md[@"x"] = @(dx); md[@"y"] = @(dy); md[@"color"] = @(color);
                [offsets addObject:md];
            } else {
                lua_rawgeti(L, -1, 1); double dx = luaL_optnumber(L, -1, 0); lua_pop(L, 1);
                lua_rawgeti(L, -1, 2); double dy = luaL_optnumber(L, -1, 0); lua_pop(L, 1);
                lua_rawgeti(L, -1, 3); int color = (int)luaL_optinteger(L, -1, 0); lua_pop(L, 1);
                md[@"x"] = @(dx); md[@"y"] = @(dy); md[@"color"] = @(color);
                [offsets addObject:md];
            }
        }
        lua_pop(L, 1);
    }
    return offsets;
}

/// 判断是否为合法颜色规格: "RRGGBB" / "#RRGGBB" / "0xRRGGBB" / "RRGGBB-偏色"(6位hex)
static BOOL tsIsHexColor(NSString *spec) {
    spec = [spec stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!spec.length) return NO;
    NSRange dash = [spec rangeOfString:@"-"];
    if (dash.location != NSNotFound) {
        NSString *dashPart = [spec substringFromIndex:dash.location + 1];
        if (dashPart.length != 6) return NO;
        spec = [spec substringToIndex:dash.location];
    }
    if ([spec hasPrefix:@"#"]) spec = [spec substringFromIndex:1];
    if ([spec hasPrefix:@"0x"] || [spec hasPrefix:@"0X"]) spec = [spec substringFromIndex:2];
    if (spec.length != 6) return NO;
    for (NSUInteger k = 0; k < spec.length; k++) {
        unichar ch = [spec characterAtIndex:k];
        if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F'))) return NO;
    }
    return YES;
}

/// AutoGo str2color: 解析颜色规格 "RRGGBB" / "#RRGGBB" / "0xRRGGBB" / "RRGGBB-偏色"(6位hex)
///   每通道容差 = 偏色通道值 + (1-sim)*255; 无偏色后缀时仅 (1-sim)*255(每通道)
static void tsParseColorSpec(NSString *spec, CGFloat sim,
                             int *colorOut,
                             uint8_t *tolROut, uint8_t *tolGOut, uint8_t *tolBOut) {
    spec = [spec stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    uint8_t baseTol = sim > 0 ? (uint8_t)((1.0 - sim) * 255.0) : 0;
    uint8_t tolR = baseTol, tolG = baseTol, tolB = baseTol;
    int color = 0;
    NSRange dash = [spec rangeOfString:@"-"];
    if (dash.location != NSNotFound) {
        NSString *dashPart = [spec substringFromIndex:dash.location + 1];
        if (dashPart.length == 6) {
            unsigned int v = 0;
            [[NSScanner scannerWithString:dashPart] scanHexInt:&v];
            tolR = (uint8_t)MIN(255, ((v >> 16) & 0xFF) + baseTol);
            tolG = (uint8_t)MIN(255, ((v >> 8) & 0xFF) + baseTol);
            tolB = (uint8_t)MIN(255, (v & 0xFF) + baseTol);
        }
        spec = [spec substringToIndex:dash.location];
    }
    if ([spec hasPrefix:@"#"]) spec = [spec substringFromIndex:1];
    if ([spec hasPrefix:@"0x"] || [spec hasPrefix:@"0X"]) spec = [spec substringFromIndex:2];
    unsigned int c = 0;
    [[NSScanner scannerWithString:spec] scanHexInt:&c];
    color = (int)(c & 0xFFFFFF);
    if (colorOut) *colorOut = color;
    if (tolROut) *tolROut = tolR;
    if (tolGOut) *tolGOut = tolG;
    if (tolBOut) *tolBOut = tolB;
}

/// 解析颜色模板字符串(AutoGo images.FindMultiColors 风格):
///   格式: "主色,dx,dy,颜色,dx,dy,颜色,..."
///   第一个元素为主色, 之后每 3 个元素一组 {dx, dy, color} 为一个偏移点(偏移在前, 颜色在后)
///   颜色支持 "RRGGBB-偏色" 后缀(每通道独立容差, 无偏色时用 (1-sim)*255)
static void tsParseMultiColorString(NSString *str, CGFloat sim,
                                    int *mainColorOut,
                                    uint8_t *mainTolROut, uint8_t *mainTolGOut, uint8_t *mainTolBOut,
                                    NSMutableArray<NSDictionary *> *offsetsOut) {
    if (!str.length) return;
    NSArray<NSString *> *parts = [str componentsSeparatedByString:@","];
    NSInteger n = (NSInteger)parts.count;
    if (n < 1) return;
    int mainColor = 0; uint8_t mTR = 0, mTG = 0, mTB = 0;
    tsParseColorSpec(parts[0], sim, &mainColor, &mTR, &mTG, &mTB);
    if (mainColorOut) *mainColorOut = mainColor;
    if (mainTolROut) *mainTolROut = mTR;
    if (mainTolGOut) *mainTolGOut = mTG;
    if (mainTolBOut) *mainTolBOut = mTB;
    for (NSInteger i = 1; i + 2 < n; i += 3) {
        if (!tsIsHexColor(parts[i + 2])) continue;   // 非法偏移点跳过
        double dx = [parts[i] doubleValue];
        double dy = [parts[i + 1] doubleValue];
        int c = 0; uint8_t tr = 0, tg = 0, tb = 0;
        tsParseColorSpec(parts[i + 2], sim, &c, &tr, &tg, &tb);
        [offsetsOut addObject:@{@"x": @(dx), @"y": @(dy), @"color": @(c),
                                @"tolR": @(tr), @"tolG": @(tg), @"tolB": @(tb)}];
    }
}

/// 单点找色: findColor(color[, x, y, w, h][, sim])
/// 调用形式:
///   findColor(color)             全屏, sim=0.9
///   findColor(color, sim)        全屏, 指定相似度
///   findColor(color, x,y,w,h)    区域, sim=0.9
///   findColor(color, x,y,w,h,sim) 区域, 指定相似度
///   findColor(color, rect, sim)  区域(table), 指定相似度
static int l_screen_findColor(lua_State *L) {
    int color = (int)luaL_checkinteger(L, 1);
    int top = lua_gettop(L);
    int next = 2;
    CGRect rect = l_optRect(L, 2, &next);

    CGFloat sim = 0.9;
    if (lua_istable(L, 2)) {
        // table 区域: findColor(color, rect, sim)
        if (lua_isnumber(L, 3)) sim = (CGFloat)lua_tonumber(L, 3);
    } else if (lua_isnumber(L, 2)) {
        if (top >= 6 && lua_isnumber(L, 6)) {
            // 4 数字区域 + sim: findColor(color, x,y,w,h,sim)
            sim = (CGFloat)lua_tonumber(L, 6);
        } else if (top == 2) {
            // 全屏 + sim: findColor(color, sim)
            sim = (CGFloat)lua_tonumber(L, 2);
        }
    }

    rect = tsScriptToActualRect(rect);   // 脚本坐标系 -> 屏幕物理方向(竖屏buffer)
    uint8_t *px = NULL; int w = 0, h = 0;
    if (!grabScreen(&px, &w, &h)) { lua_pushnil(L); return 1; }
    CGSize ss = screenPixelSize();
    TSColorResult *res = [TSColorFinder findColor:color rect:rect sim:sim
                                          pixels:px width:w height:h screenSize:ss];
    free(px);
    if (!res) { lua_pushnil(L); return 1; }
    CGPoint pt = tsBufferToScriptPoint(res.point);   // buffer坐标 -> 脚本坐标系
    lua_pushnumber(L, pt.x);
    lua_pushnumber(L, pt.y);
    return 2;
}

/// 多点找色:
///   风格1(偏移点table): findColors(mainColor, offsets[, x, y, w, h][, sim][, offSim][, dir])
///     偏移点项可带 tolR/tolG/tolB(逐通道容差)或 tolerance(统一容差)字段, 缺省时由 offSim 生成
///   风格2(AutoGo images.FindMultiColors): findColors(x1, y1, x2, y2, colorsStr[, sim][, dir])
///     colorsStr 颜色模板字符串: "主色,dx,dy,颜色,dx,dy,颜色,..." 主色在前,
///     之后每 3 项一组 {dx, dy, color} 为偏移点; 颜色支持 "RRGGBB-偏色" 后缀(逐通道容差)
///     匹配为 AutoGo 逐通道偏色判定: |R1-R2|<=tolR && |G1-G2|<=tolG && |B1-B2|<=tolB
///     x2/y2 为 0 表示使用屏幕最大宽高; dir 为扫描方向(0~3)
static int l_screen_findColors(lua_State *L) {
    int mainColor = 0;
    NSMutableArray<NSDictionary *> *offsets = [NSMutableArray array];
    CGRect rect;
    CGFloat sim = 0.9, offSim = 0.9;
    int dir = 0;
    uint8_t mTR = 0, mTG = 0, mTB = 0;

    if (lua_gettop(L) >= 5 && lua_isnumber(L, 1) && lua_isnumber(L, 2)
        && lua_isnumber(L, 3) && lua_isnumber(L, 4) && lua_isstring(L, 5)) {
        // ---- 风格2: findColors(x1, y1, x2, y2, colorsStr[, sim][, dir]) ----
        CGFloat x1 = luaL_checknumber(L, 1);
        CGFloat y1 = luaL_checknumber(L, 2);
        CGFloat x2 = luaL_checknumber(L, 3);
        CGFloat y2 = luaL_checknumber(L, 4);
        NSString *colorsStr = [NSString stringWithUTF8String:luaL_checkstring(L, 5)];
        if (lua_gettop(L) >= 6 && lua_isnumber(L, 6)) sim = (CGFloat)lua_tonumber(L, 6);
        if (sim <= 0 || sim > 1) sim = 0.9;
        offSim = sim;
        if (lua_gettop(L) >= 7 && lua_isnumber(L, 7)) dir = (int)lua_tointeger(L, 7);

        tsParseMultiColorString(colorsStr, sim, &mainColor, &mTR, &mTG, &mTB, offsets);
        if (offsets.count == 0) {
            lua_log(@"findColors: 颜色模板字符串解析失败(无偏移点)");
            lua_pushnil(L); return 1;
        }
        // x2/y2 为 0 时使用屏幕最大宽高(脚本坐标系=竖屏物理像素)
        CGSize ss = screenPixelSize();
        if (x2 <= 0) x2 = ss.width;
        if (y2 <= 0) y2 = ss.height;
        if (x2 < x1) { CGFloat t = x1; x1 = x2; x2 = t; }
        if (y2 < y1) { CGFloat t = y1; y1 = y2; y2 = t; }
        rect = CGRectMake(x1, y1, x2 - x1, y2 - y1);
    } else {
        // ---- 风格1: findColors(mainColor, offsets[, x, y, w, h][, sim][, offSim][, dir]) ----
        mainColor = (int)luaL_checkinteger(L, 1);
        if (lua_istable(L, 2)) {
            // 标准顺序: (mainColor, offsets, x,y,w,h, sim, offSim, dir)
            [offsets addObjectsFromArray:l_parseOffsets(L, 2)];
            int next = 3;
            rect = l_optRect(L, 3, &next);
            sim = (CGFloat)luaL_optnumber(L, next, 0.9);
            offSim = (CGFloat)luaL_optnumber(L, next + 1, sim);
            dir = (int)luaL_optinteger(L, next + 2, 0);
        } else {
            // 文档顺序: (mainColor, x,y,w,h, offsets, sim, offSim, dir)
            int next = 2;
            rect = l_optRect(L, 2, &next);
            [offsets addObjectsFromArray:l_parseOffsets(L, next)];
            sim = (CGFloat)luaL_optnumber(L, next + 1, 0.9);
            offSim = (CGFloat)luaL_optnumber(L, next + 2, sim);
            dir = (int)luaL_optinteger(L, next + 3, 0);
        }
    }

    rect = tsScriptToActualRect(rect);   // 脚本坐标系 -> 屏幕物理方向(竖屏buffer)
    tsRotateOffsets(offsets, s_scriptOrientation);  // 偏移点同步旋转, 否则横屏下方向错位
    uint8_t *px = NULL; int w = 0, h = 0;
    if (!grabScreen(&px, &w, &h)) {
        NSString *err = [TSScreenCapture shared].lastError;
        if (err.length) {
            lua_log([NSString stringWithFormat:@"findColors 截屏失败: %@", err]);
        } else {
            lua_log(@"findColors 截屏失败(全部路径均失败, 无详细错误)");
        }
        lua_pushnil(L); return 1;
    }
    CGSize ss = screenPixelSize();
    TSColorResult *res = [TSColorFinder findMultiColor:mainColor rect:rect mainColorSim:sim
                                             mainTolR:mTR mainTolG:mTG mainTolB:mTB
                                              offsets:offsets offsetSim:offSim
                                             direction:dir
                                               pixels:px width:w height:h screenSize:ss];
    free(px);
    if (!res) { lua_pushnil(L); return 1; }
    CGPoint pt = tsBufferToScriptPoint(res.point);   // buffer坐标 -> 脚本坐标系
    lua_pushnumber(L, pt.x);
    lua_pushnumber(L, pt.y);
    return 2;
}

/// 取色: getColor(x, y) -> 0xRRGGBB
static int l_screen_getColor(lua_State *L) {
    CGFloat x = (CGFloat)luaL_checknumber(L, 1);
    CGFloat y = (CGFloat)luaL_checknumber(L, 2);
    uint8_t *px = NULL; int w = 0, h = 0;
    if (!grabScreen(&px, &w, &h)) {
        // 截屏失败时不返回 nil，否则脚本里 string.format("0x%06X", c) 会因 nil 崩溃。
        // 返回 0(黑色) 并记录日志，让脚本能继续跑、用户能看到取色异常。
        // 失败原因从 TSScreenCapture.lastError 读取(NSLog 用户看不到, 需经这里转发)。
        NSString *err = [TSScreenCapture shared].lastError;
        if (err.length) {
            lua_log([NSString stringWithFormat:@"getColor 截屏失败(全部路径均失败): %@", err]);
        } else {
            lua_log(@"getColor 截屏失败(全部路径均失败, 无详细错误)");
        }
        lua_pushinteger(L, 0);
        return 1;
    }
    CGPoint sp = tsScriptToActualPoint(CGPointMake(x, y));   // 脚本坐标系 -> 屏幕物理方向(竖屏buffer)
    CGSize ss = screenPixelSize();
    int color = [TSColorFinder getColorAtPoint:sp pixels:px width:w height:h screenSize:ss];
    free(px);
    lua_pushinteger(L, color);
    return 1;
}

/// 获取屏幕某点的 RGB 分量: screen.getColorRGB(x, y) → r, g, b
/// 与 getColor(x, y) 等价, 但直接返回三个 0~255 的分量, 省去脚本里位运算。
static int l_screen_getColorRGB(lua_State *L) {
    CGFloat x = (CGFloat)luaL_checknumber(L, 1);
    CGFloat y = (CGFloat)luaL_checknumber(L, 2);
    uint8_t *px = NULL; int w = 0, h = 0;
    if (!grabScreen(&px, &w, &h)) {
        NSString *err = [TSScreenCapture shared].lastError;
        if (err.length) {
            lua_log([NSString stringWithFormat:@"getColorRGB 截屏失败: %@", err]);
        }
        lua_pushinteger(L, 0);
        lua_pushinteger(L, 0);
        lua_pushinteger(L, 0);
        return 3;
    }
    CGPoint sp = tsScriptToActualPoint(CGPointMake(x, y));
    CGSize ss = screenPixelSize();
    int color = [TSColorFinder getColorAtPoint:sp pixels:px width:w height:h screenSize:ss];
    free(px);
    // 0xRRGGBB → R, G, B
    lua_pushinteger(L, (lua_Integer)((color >> 16) & 0xFF));   // R
    lua_pushinteger(L, (lua_Integer)((color >> 8) & 0xFF));    // G
    lua_pushinteger(L, (lua_Integer)(color & 0xFF));            // B
    return 3;
}

/// 模板找图: findImage(path[, accuracy][, x, y, w, h])
/// 调用形式:
///   findImage(path)               全屏, accuracy=0.8
///   findImage(path, accuracy)     全屏, 指定 accuracy
///   findImage(path, x, y, w, h)   区域, accuracy=0.8
///   findImage(path, accuracy, x, y, w, h)  区域+accuracy
static int l_screen_findImage(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    int top = lua_gettop(L);
    int next = 2;
    CGFloat accuracy = 0.8;
    CGRect rect;
    if (top >= 6 && lua_isnumber(L, 2) && lua_isnumber(L, 3) &&
        lua_isnumber(L, 4) && lua_isnumber(L, 5) && lua_isnumber(L, 6)) {
        // 省略 accuracy 的区域形式: findImage(path, x, y, w, h)
        rect = l_optRect(L, 2, &next);
    } else {
        accuracy = (CGFloat)luaL_optnumber(L, 2, 0.8);
        rect = l_optRect(L, 3, &next);
    }
    if (accuracy <= 0 || accuracy > 1) accuracy = 0.8;

    rect = tsScriptToActualRect(rect);   // 脚本坐标系 -> 屏幕物理方向(竖屏buffer)
    TSTemplateMatchResult *res = [[TSTemplateMatcher shared] findImageAtPath:@(path)
                                                                    accuracy:accuracy
                                                                        rect:rect];
    if (!res) { lua_pushnil(L); return 1; }
    CGPoint pt = tsBufferToScriptPoint(res.center);   // buffer坐标 -> 脚本坐标系
    lua_pushnumber(L, pt.x);
    lua_pushnumber(L, pt.y);
    return 2;
}

/// 截屏保存: snapshot([path]) -> 完整路径 或 nil
static int l_screen_snapshot(lua_State *L) {
    UIImage *img = [[TSScreenCapture shared] captureImage];
    if (!img) { lua_pushnil(L); return 1; }
    NSString *path;
    if (lua_isstring(L, 1)) {
        path = @(luaL_checkstring(L, 1));
    } else {
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"yyyyMMdd_HHmmss";
        // 默认保存到 /var/mobile/touch/log (本地日志/调试产物目录)
        path = [[TSPaths logDir] stringByAppendingFormat:@"/snapshot_%@.png", [f stringFromDate:[NSDate date]]];
    }
    BOOL ok = [UIImagePNGRepresentation(img) writeToFile:path atomically:YES];
    if (!ok) { lua_pushnil(L); return 1; }
    lua_pushstring(L, path.UTF8String);
    return 1;
}

/// keepScreen(flag): true 缓存截屏, false 释放缓存 (与 screen.keep()/screen.unkeep() 等价)
static int l_screen_keepScreen(lua_State *L) {
    if (lua_toboolean(L, 1)) {
        [[TSScreenCapture shared] keepPixels];
    } else {
        [[TSScreenCapture shared] unkeepPixels];
    }
    return 0;
}

/// screen.keep(): 缓存当前屏幕像素。之后 findColor/findColors/getColor/findImage 直接复用缓存
/// 不再重复截屏，找色找图性能极大提升。
/// 注意: 缓存期间屏幕内容被"冻结"(读取的是缓存帧)，画面变化后须调用 screen.unkeep() 释放
/// 或重新 screen.keep() 刷新缓存。
static int l_screen_keep(lua_State *L) {
    [[TSScreenCapture shared] keepPixels];
    return 0;
}

/// screen.unkeep(): 释放 screen.keep() 缓存的屏幕像素，恢复每次实时截屏。
static int l_screen_unkeep(lua_State *L) {
    [[TSScreenCapture shared] unkeepPixels];
    return 0;
}

#pragma mark - 触摸

static int l_touch_tap(lua_State *L) {
    TSHIDEventTouch *touch = [TSHIDEventTouch shared];
    if (touch.senderID == 0) {
        lua_log(@"[touch] 警告: senderID 未就绪(0), 注入事件可能被系统丢弃! 请先在设备上手动触摸一次屏幕后重跑脚本");
    }
    CGFloat x = (CGFloat)luaL_checknumber(L, 1);
    CGFloat y = (CGFloat)luaL_checknumber(L, 2);
    // 第 3 参: 抬起时间(毫秒), 与文档 touch.tap(x,y,抬起ms) 一致; 默认 50ms
    NSTimeInterval dur = (NSTimeInterval)luaL_optnumber(L, 3, 50) / 1000.0;
    // 第 4 参: 压力 (默认 1); 第 5 参: 触摸半径等级/毫米 (默认 0=自动 4.5)
    CGFloat pressure = (CGFloat)luaL_optnumber(L, 4, 1.0);
    CGFloat radius   = (CGFloat)luaL_optnumber(L, 5, 0);
    CGFloat sc = touchScale();
    CGPoint sp = tsScriptToActualPoint(CGPointMake(x, y));   // 脚本坐标系 -> 屏幕物理方向(竖屏buffer)
    [touch tapAtPoint:CGPointMake(sp.x / sc, sp.y / sc)
             duration:dur
             pressure:pressure radius:radius];
    return 0;
}

static int l_touch_status(lua_State *L) {
    lua_pushstring(L, [[TSHIDEventTouch shared] statusDescription].UTF8String);
    return 1;
}

static int l_touch_down(lua_State *L) {
    NSInteger index = (NSInteger)luaL_checkinteger(L, 1);
    CGFloat x = (CGFloat)luaL_checknumber(L, 2);
    CGFloat y = (CGFloat)luaL_checknumber(L, 3);
    CGFloat pressure = (CGFloat)luaL_optnumber(L, 4, 1.0);
    CGFloat radius   = (CGFloat)luaL_optnumber(L, 5, 0);
    CGFloat sc = touchScale();
    CGPoint sp = tsScriptToActualPoint(CGPointMake(x, y));   // 脚本坐标系 -> 屏幕物理方向(竖屏buffer)
    [[TSHIDEventTouch shared] touchDownAtPoint:CGPointMake(sp.x / sc, sp.y / sc) index:index
                                      pressure:pressure radius:radius];
    return 0;
}

static int l_touch_move(lua_State *L) {
    NSInteger index = (NSInteger)luaL_checkinteger(L, 1);
    CGFloat x = (CGFloat)luaL_checknumber(L, 2);
    CGFloat y = (CGFloat)luaL_checknumber(L, 3);
    CGFloat pressure = (CGFloat)luaL_optnumber(L, 4, 1.0);
    CGFloat radius   = (CGFloat)luaL_optnumber(L, 5, 0);
    CGFloat sc = touchScale();
    CGPoint sp = tsScriptToActualPoint(CGPointMake(x, y));   // 脚本坐标系 -> 屏幕物理方向(竖屏buffer)
    [[TSHIDEventTouch shared] touchMoveAtPoint:CGPointMake(sp.x / sc, sp.y / sc) index:index
                                      pressure:pressure radius:radius];
    return 0;
}

static int l_touch_up(lua_State *L) {
    NSInteger index = (NSInteger)luaL_checkinteger(L, 1);
    CGFloat x = (CGFloat)luaL_checknumber(L, 2);
    CGFloat y = (CGFloat)luaL_checknumber(L, 3);
    CGFloat sc = touchScale();
    CGPoint sp = tsScriptToActualPoint(CGPointMake(x, y));   // 脚本坐标系 -> 屏幕物理方向(竖屏buffer)
    [[TSHIDEventTouch shared] touchUpAtPoint:CGPointMake(sp.x / sc, sp.y / sc) index:index];
    return 0;
}

static int l_touch_swipe(lua_State *L) {
    CGFloat x1 = (CGFloat)luaL_checknumber(L, 1);
    CGFloat y1 = (CGFloat)luaL_checknumber(L, 2);
    CGFloat x2 = (CGFloat)luaL_checknumber(L, 3);
    CGFloat y2 = (CGFloat)luaL_checknumber(L, 4);
    NSTimeInterval dur = (NSTimeInterval)luaL_optnumber(L, 5, 0.3);
    NSInteger steps = (NSInteger)luaL_optinteger(L, 6, 20);
    CGFloat pressure = (CGFloat)luaL_optnumber(L, 7, 1.0);
    CGFloat radius   = (CGFloat)luaL_optnumber(L, 8, 0);
    CGFloat sc = touchScale();
    CGPoint sp1 = tsScriptToActualPoint(CGPointMake(x1, y1));   // 脚本坐标系 -> 屏幕物理方向(竖屏buffer)
    CGPoint sp2 = tsScriptToActualPoint(CGPointMake(x2, y2));
    [[TSHIDEventTouch shared] swipeFromPoint:CGPointMake(sp1.x / sc, sp1.y / sc)
                                     toPoint:CGPointMake(sp2.x / sc, sp2.y / sc)
                                    duration:dur steps:steps
                                    pressure:pressure radius:radius];
    return 0;
}

/// 多点轨迹: stroke({x1,y1, x2,y2, ...}, duration_ms)
static int l_touch_stroke(lua_State *L) {
    if (!lua_istable(L, 1)) { luaL_error(L, "stroke 第一个参数必须是点表"); return 0; }
    NSTimeInterval total = (NSTimeInterval)luaL_optnumber(L, 2, 0.3);
    lua_len(L, 1);
    int n = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);
    if (n < 2 || (n % 2) != 0) { luaL_error(L, "stroke 点表长度必须是偶数 (x1,y1,x2,y2,...)"); return 0; }

    int count = n / 2;
    // 读取所有点（Lua 层为物理像素，先转屏幕物理方向，再统一除以 scale 转逻辑点）
    CGFloat sc = touchScale();
    CGFloat pts[256 * 2];
    if (count > 256) count = 256;
    for (int i = 0; i < count; i++) {
        lua_rawgeti(L, 1, i * 2 + 1); CGFloat px = (CGFloat)luaL_checknumber(L, -1); lua_pop(L, 1);
        lua_rawgeti(L, 1, i * 2 + 2); CGFloat py = (CGFloat)luaL_checknumber(L, -1); lua_pop(L, 1);
        CGPoint sp = tsScriptToActualPoint(CGPointMake(px, py));
        pts[i * 2]     = sp.x / sc;
        pts[i * 2 + 1] = sp.y / sc;
    }

    TSHIDEventTouch *t = [TSHIDEventTouch shared];
    CGFloat pressure = (CGFloat)luaL_optnumber(L, 3, 1.0);
    CGFloat radius   = (CGFloat)luaL_optnumber(L, 4, 0);
    [t touchDownAtPoint:CGPointMake(pts[0], pts[1]) index:0 pressure:pressure radius:radius];
    int stepsPerSeg = 10;
    for (int i = 1; i < count; i++) {
        CGPoint from = CGPointMake(pts[(i - 1) * 2], pts[(i - 1) * 2 + 1]);
        CGPoint to   = CGPointMake(pts[i * 2],     pts[i * 2 + 1]);
        for (int s = 1; s <= stepsPerSeg; s++) {
            CGFloat tRatio = (CGFloat)s / stepsPerSeg;
            CGPoint p = CGPointMake(from.x + (to.x - from.x) * tRatio,
                                    from.y + (to.y - from.y) * tRatio);
            [t touchMoveAtPoint:p index:0 pressure:pressure radius:radius];
            usleep((useconds_t)((total / count / stepsPerSeg) * 1000000));
            if (_stopRequested) {
                // 先抬手再中断，避免留下按住的触摸导致屏幕无响应
                [t touchUpAtPoint:p index:0];
                luaL_error(L, "脚本已被停止");
            }
        }
    }
    [t touchUpAtPoint:CGPointMake(pts[(count - 1) * 2], pts[(count - 1) * 2 + 1]) index:0];
    return 0;
}

#pragma mark - 设备/系统

// ────────────────────────── 弹窗 (sys.alert / sys.alertButtons) ──────────────────────────
// 阻塞式弹窗: 在 Lua 后台线程调用, 主线程弹 UIAlertController 并等待用户点击。
//   title/message  弹窗标题与内容
//   buttons        按钮文本数组; 为空时仅显示"确定"(供永久显示场景手动关闭)
//   timeout        显示时间(秒): >0 超时自动关闭; 0 永久显示直到点击
// 返回: 用户点击的按钮文本; 超时或被脚本停止时返回 nil。
// 线程模型: Lua 脚本在 _luaQueue 后台串行队列执行, 因此这里可以安全阻塞等待;
//   主线程负责 present/dismiss 与收集点击结果, 不会互相死锁。
static NSString *TSShowBlockingAlert(NSString *title, NSString *message,
                                     NSArray<NSString *> *buttons, NSTimeInterval timeout) {
    if (!title.length) title = @"提示";

    // App 不在前台时 UIAlertController 无法显示(会静默失败)。
    // 此时走进程内 HUD 宿主: TSHUDHost 自建全屏透明窗口并经 SBS 系统级托管,
    // 在任意 app 之上弹自绘全局窗口; 托管未就绪且 App 不在前台时立即返回 nil,
    // 避免脚本永久卡死。
    // 注意: 必须把原始 buttons 传给 HUD, HUD 侧根据"空按钮+timeout"区分自动消失/确定按钮;
    //       这里不能提前替换为空按钮兜底, 否则会破坏该语义。
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        NSLog(@"[QQ音乐] App 不在前台, 使用进程内 HUD 宿主弹全局窗口");
        return [[TSHUDService sharedInstance] showAlertWithTitle:title
                                                         message:message
                                                         buttons:buttons
                                                         timeout:timeout];
    }

    // App 内弹窗: 至少需要一个按钮(永久显示时供手动关闭)
    if (!buttons.count) buttons = @[@"确定"];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSString *picked = nil;
    __block BOOL finished = NO;
    __block UIAlertController *alert = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        // 找到当前可 present 的顶层控制器(主窗口), 与 _presentInAppVolumeMenu 一致
        NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
        UIWindow *keyWindow = nil;
        for (UIWindow *w in windows) {
            if (w.isKeyWindow) { keyWindow = w; break; }
        }
        if (!keyWindow) keyWindow = windows.firstObject;
        UIViewController *top = keyWindow.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        if (!top) {
            // 无可用窗口(如 App 后台), 直接结束等待, 避免 Lua 永久卡死
            finished = YES;
            dispatch_semaphore_signal(sem);
            return;
        }

        alert = [UIAlertController alertControllerWithTitle:title
                                                    message:message
                                             preferredStyle:UIAlertControllerStyleAlert];
        for (NSString *btn in buttons) {
            UIAlertActionStyle style = UIAlertActionStyleDefault;
            if ([btn isEqualToString:@"取消"]) style = UIAlertActionStyleCancel;
            [alert addAction:[UIAlertAction actionWithTitle:btn style:style handler:^(UIAlertAction *action) {
                picked = btn;
                finished = YES;
                dispatch_semaphore_signal(sem);
            }]];
        }
        [top presentViewController:alert animated:YES completion:nil];

        // 超时自动关闭
        if (timeout > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!finished) {
                    finished = YES;
                    [alert dismissViewControllerAnimated:YES completion:nil];
                    dispatch_semaphore_signal(sem);
                }
            });
        }
    });

    // Lua 线程等待: 分段等待并检查停止标志, 保证点"停止"后弹窗立即关闭、脚本可中断
    while (!finished && !_stopRequested) {
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) == 0) {
            break;  // 用户点击或超时, 已收到信号
        }
    }
    if (!finished && _stopRequested) {
        // 脚本被停止: 强制关闭弹窗
        dispatch_async(dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:NO completion:nil];
        });
    }
    return picked;
}

// sys.alert(提示内容, [显示时间], [标题])
//   显示时间 >0: 自动消失(无按钮); 显示时间 =0: 永久显示, 带"确定"按钮。
//   兼容原版 TrollAutoScript 的 sys.alert 语义。
static int l_sys_alert(lua_State *L) {
    size_t mlen = 0;
    const char *msg = luaL_checklstring(L, 1, &mlen);
    NSString *message = luaToNSString(msg, mlen);

    double timeout = 0;
    if (lua_type(L, 2) == LUA_TNUMBER) timeout = lua_tonumber(L, 2);

    NSString *title = @"提示";
    if (lua_type(L, 3) == LUA_TSTRING) {
        size_t tlen = 0;
        const char *t = lua_tolstring(L, 3, &tlen);
        title = luaToNSString(t, tlen);
    }

    // 超时>0 时纯展示自动消失; timeout=0 永久显示, 提供"确定"按钮供用户关闭
    NSArray<NSString *> *buttons = (timeout > 0) ? @[] : @[@"确定"];
    TSShowBlockingAlert(title, message, buttons, timeout);
    return 0;
}

// sys.alertButtons(提示内容, {按钮1, 按钮2, ...}, [标题], [显示时间])
//   带按钮的提示框: 阻塞脚本直到用户点击某个按钮, 返回该按钮的文本。
//   显示时间 >0: 超时未点击自动关闭并返回 nil; 显示时间 =0: 永久等待用户点击。
static int l_sys_alertButtons(lua_State *L) {
    size_t mlen = 0;
    const char *msg = luaL_checklstring(L, 1, &mlen);
    NSString *message = luaToNSString(msg, mlen);

    // 参数2: 按钮表
    luaL_checktype(L, 2, LUA_TTABLE);
    NSMutableArray<NSString *> *buttons = [NSMutableArray array];
    lua_pushnil(L);
    while (lua_next(L, 2) != 0) {
        if (lua_type(L, -1) == LUA_TSTRING) {
            size_t blen = 0;
            const char *b = lua_tolstring(L, -1, &blen);
            [buttons addObject:luaToNSString(b, blen)];
        }
        lua_pop(L, 1);
    }
    if (!buttons.count) {
        lua_pushnil(L);
        return 1;
    }

    NSString *title = @"提示";
    if (lua_type(L, 3) == LUA_TSTRING) {
        size_t tlen = 0;
        const char *t = lua_tolstring(L, 3, &tlen);
        title = luaToNSString(t, tlen);
    }

    double timeout = 0;
    if (lua_type(L, 4) == LUA_TNUMBER) timeout = lua_tonumber(L, 4);

    NSString *picked = TSShowBlockingAlert(title, message, buttons, timeout);
    if (picked) {
        lua_pushstring(L, picked.UTF8String);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

static int l_sys_info(lua_State *L) {
    NSDictionary *info = [[TSDeviceInfo shared] fullInfo];
    _pushNSObjectToLua(L, info);
    return 1;
}

static int l_sys_osVersion(lua_State *L) {
    lua_pushstring(L, [[TSDeviceInfo shared] osVersion].UTF8String);
    return 1;
}

static int l_sys_model(lua_State *L) {
    lua_pushstring(L, [[TSDeviceInfo shared] modelIdentifier].UTF8String);
    return 1;
}

static int l_sys_screenSize(lua_State *L) {
    CGSize s = [[TSDeviceInfo shared] screenSize];
    lua_pushnumber(L, s.width);
    lua_pushnumber(L, s.height);
    return 2;
}

static int l_sys_getIP(lua_State *L) {
    NSString *ip = [[TSDeviceInfo shared] wifiIPAddress];
    if (!ip) { lua_pushnil(L); return 1; }
    lua_pushstring(L, ip.UTF8String);
    return 1;
}

static int l_sys_battery(lua_State *L) {
    lua_pushnumber(L, [[TSDeviceInfo shared] batteryLevel]);
    return 1;
}

/// sys.setFloatBallPoint(x, y)
/// 把悬浮球本体中心移动到指定坐标。坐标使用脚本坐标系 (与 screen.init 设置的方向一致,
/// 与 tap/findColor 等同源), 内部自动旋转到设备当前方向的屏幕显示坐标后定位。
/// 若悬浮球未显示, 自动 show 后再移动。线程安全 (内部派发主线程)。
static int l_sys_setFloatBallPoint(lua_State *L) {
    CGFloat sx = (CGFloat)luaL_checknumber(L, 1);
    CGFloat sy = (CGFloat)luaL_checknumber(L, 2);
    lua_log([NSString stringWithFormat:@"[setFloatBallPoint] script(%.0f, %.0f)", sx, sy]);
    dispatch_async(dispatch_get_main_queue(), ^{
        // 悬浮球移动固定按竖屏原始坐标系 (0 旋转): 不做脚本方向/设备方向旋转换算。
        // 脚本传入的物理像素直接除以 scale 作为竖屏窗口逻辑点坐标,
        // 横屏时位置随窗口显示旋转(严格竖屏语义), 由脚本自己调坐标。
        // 显示布局(展开/收起/按钮朝向)走 setBallPointPortrait 内部, 与旧逻辑一致。
        CGFloat scale = [UIScreen mainScreen].scale;
        CGPoint displayPt = CGPointMake(sx / scale, sy / scale);

        TSHUDWindow *win = [TSHUDWindow shared];
        if (win.hidden) [win show];
        [win setBallPointPortrait:displayPt];
    });
    return 0;
}

/// sys.mtime() → number
/// 毫秒级时间戳 (UTC, 自 1970-01-01 起的毫秒数)
static int l_sys_mtime(lua_State *L) {
    NSTimeInterval t = [[NSDate date] timeIntervalSince1970];
    lua_pushnumber(L, t * 1000.0);
    return 1;
}

/// sys.availableMemory() → number
/// 系统可用内存 (字节)
static int l_sys_availableMemory(lua_State *L) {
    // 进程可用物理内存 (系统级)
    vm_statistics_data_t vmStats;
    mach_msg_type_number_t count = HOST_VM_INFO_COUNT;
    kern_return_t kr = host_statistics(mach_host_self(), HOST_VM_INFO, (host_info_t)&vmStats, &count);
    if (kr != KERN_SUCCESS) { lua_pushnumber(L, 0); return 1; }
    vm_size_t pageSize = 0;
    host_page_size(mach_host_self(), &pageSize);
    // free + inactive + speculative 都算可用
    uint64_t avail = (uint64_t)(vmStats.free_count + vmStats.inactive_count + vmStats.speculative_count) * pageSize;
    lua_pushnumber(L, (lua_Number)avail);
    return 1;
}

/// sys.processUsedMemory() → number
/// 当前进程使用的物理内存 (字节, resident_size)
static int l_sys_processUsedMemory(lua_State *L) {
    task_basic_info_data_t info;
    mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) { lua_pushnumber(L, 0); return 1; }
    lua_pushnumber(L, (lua_Number)info.resident_size);
    return 1;
}

/// sys.usedMemory() → number
/// 系统已用物理内存 (字节)
static int l_sys_usedMemory(lua_State *L) {
    vm_statistics_data_t vmStats;
    mach_msg_type_number_t count = HOST_VM_INFO_COUNT;
    kern_return_t kr = host_statistics(mach_host_self(), HOST_VM_INFO, (host_info_t)&vmStats, &count);
    if (kr != KERN_SUCCESS) { lua_pushnumber(L, 0); return 1; }
    vm_size_t pageSize = 0;
    host_page_size(mach_host_self(), &pageSize);
    uint64_t used = (uint64_t)(vmStats.active_count + vmStats.wire_count) * pageSize;
    lua_pushnumber(L, (lua_Number)used);
    return 1;
}

/// sys.version() → string
/// App 版本号 (CFBundleShortVersionString)
static int l_sys_version(lua_State *L) {
    NSString *v = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"];
    lua_pushstring(L, v.UTF8String ?: "");
    return 1;
}

/// sys.palyAudio(path)  (保留原版拼写)
/// 播放音频文件 (本地路径, 异步播放, 不阻塞)
static int l_sys_palyAudio(lua_State *L) {
    size_t len = 0;
    const char *p = luaL_checklstring(L, 1, &len);
    NSString *path = [[NSString alloc] initWithBytes:p length:len encoding:NSUTF8StringEncoding];
    if (!path) { lua_pushboolean(L, NO); return 1; }

    NSURL *url = [NSURL fileURLWithPath:path];
    if (!url) { lua_pushboolean(L, NO); return 1; }

    // 用静态 player 保持引用, 避免被释放导致播放中断
    static AVAudioPlayer *sPlayer = nil;
    NSError *err = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&err];
    if (err || !player) {
        lua_log([NSString stringWithFormat:@"[palyAudio] init failed: %@", err.localizedDescription]);
        lua_pushboolean(L, NO);
        return 1;
    }
    [player prepareToPlay];
    sPlayer = player;
    [player play];
    lua_pushboolean(L, YES);
    return 1;
}

/// device.udid() → string / nil
/// 获取设备 UDID (TrollStore 环境通过 MobileGestalt 私有 API, 沙盒返回 nil)
static int l_device_udid(lua_State *L) {
    NSString *udid = [[TSDeviceInfo shared] udid];
    if (udid.length > 0) {
        lua_pushstring(L, udid.UTF8String);
    } else {
        lua_pushnil(L);
        lua_log(@"[device.udid] failed: MobileGestalt unavailable or sandboxed");
    }
    return 1;
}

/// device.serialNumber() → string / nil
static int l_device_serialNumber(lua_State *L) {
    NSString *sn = [[TSDeviceInfo shared] serialNumber];
    if (sn.length > 0) {
        lua_pushstring(L, sn.UTF8String);
    } else {
        lua_pushnil(L);
        lua_log(@"[device.serialNumber] failed: MobileGestalt unavailable or sandboxed");
    }
    return 1;
}

/// device.turnOnAssistiveTouch() → boolean
/// 启用辅助触控 (小白点)。修改 Accessibility.plist + 广播 Darwin 通知让 SpringBoard 重载。
static int l_device_turnOnAssistiveTouch(lua_State *L) {
    BOOL ok = [[TSDeviceInfo shared] enableAssistiveTouch];
    lua_pushboolean(L, ok);
    lua_log([NSString stringWithFormat:@"[device.turnOnAssistiveTouch] result=%d", ok]);
    return 1;
}

/// device.turnOffAssistiveTouch() → boolean
/// 停用辅助触控 (小白点)
static int l_device_turnOffAssistiveTouch(lua_State *L) {
    BOOL ok = [[TSDeviceInfo shared] disableAssistiveTouch];
    lua_pushboolean(L, ok);
    lua_log([NSString stringWithFormat:@"[device.turnOffAssistiveTouch] result=%d", ok]);
    return 1;
}

/// device.isScreenLocked() → boolean
/// 查询屏幕是否锁定。无密码设备可配合 unlockScreen 唤醒。
static int l_device_isScreenLocked(lua_State *L) {
    BOOL locked = [[TSDeviceInfo shared] isScreenLocked];
    lua_pushboolean(L, locked);
    return 1;
}

/// device.unlockScreen() → boolean
/// 唤醒屏幕 + 发 Home 键取消锁屏 (无密码设备会进桌面)。
/// 有密码的设备此函数无法完全解锁到桌面, 由调用方自行处理。
static int l_device_unlockScreen(lua_State *L) {
    BOOL ok = [[TSDeviceInfo shared] unlockScreen];
    lua_pushboolean(L, ok);
    lua_log([NSString stringWithFormat:@"[device.unlockScreen] result=%d", ok]);
    return 1;
}

/// device.name() → string
/// 设备名 (UIDevice.name)
static int l_device_name(lua_State *L) {
    NSString *n = [[TSDeviceInfo shared] deviceName];
    lua_pushstring(L, n.UTF8String ?: "");
    return 1;
}

/// device.type() → string
/// 设备类型: iPhone / iPad / TV / CarPlay / Mac / Unspecified
static int l_device_type(lua_State *L) {
    NSString *t = [[TSDeviceInfo shared] deviceType];
    lua_pushstring(L, t.UTF8String);
    return 1;
}

/// device.backlightLevel() → number
/// 当前屏幕亮度 [0, 1]
static int l_device_backlightLevel(lua_State *L) {
    lua_pushnumber(L, [[TSDeviceInfo shared] backlightLevel]);
    return 1;
}

/// device.setBacklightLevel(n)
/// 设置屏幕亮度 [0, 1]
static int l_device_setBacklightLevel(lua_State *L) {
    CGFloat n = (CGFloat)luaL_checknumber(L, 1);
    [[TSDeviceInfo shared] setBacklightLevel:n];
    return 0;
}

/// device.lockScreen()
/// 锁定屏幕 (电源键, 复用 GSEventLockDevice)
static int l_device_lockScreen(lua_State *L) {
    [[TSDeviceInfo shared] lockScreen];
    return 0;
}

/// device.vibrator()
/// 系统震动反馈
static int l_device_vibrator(lua_State *L) {
    [[TSDeviceInfo shared] vibrate];
    return 0;
}

/// device.setVolume(n)
/// 设置系统音量 [0, 1]
static int l_device_setVolume(lua_State *L) {
    float n = (float)luaL_checknumber(L, 1);
    [[TSDeviceInfo shared] setSystemVolume:n];
    return 0;
}

#pragma mark - 应用管理

static int l_app_frontBid(lua_State *L) {
    NSString *bid = [[TSAppManager shared] frontBid];
    if (!bid) { lua_pushnil(L); return 1; }
    lua_pushstring(L, bid.UTF8String);
    return 1;
}

static int l_app_isInstalled(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    lua_pushboolean(L, [[TSAppManager shared] isInstalled:@(bid)]);
    return 1;
}

static int l_app_open(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    lua_pushboolean(L, [[TSAppManager shared] openApp:@(bid)]);
    return 1;
}

static int l_app_close(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    lua_pushboolean(L, [[TSAppManager shared] closeApp:@(bid)]);
    return 1;
}

static int l_app_inputText(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    lua_pushboolean(L, [[TSAppManager shared] inputText:@(text)]);
    return 1;
}

#pragma mark - UI 树

static int l_appNode_info(lua_State *L) {
    NSString *json = [[TSAppNodeInfo shared] fullTreeJSON];
    lua_pushstring(L, json.UTF8String);
    return 1;
}

static int l_appNode_findByText(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    NSArray<TSAppNode *> *nodes = [[TSAppNodeInfo shared] findByText:@(text)];
    CGFloat sc = touchScale();
    // 节点坐标是设备实际方向(逻辑点), 旋转回脚本坐标系再乘 scale 转物理像素 (与 screen.init 一致)
    BOOL swapWH = (s_scriptOrientation == 0) != (tsCurrentOrientation() == 0);
    lua_newtable(L);
    for (NSUInteger i = 0; i < nodes.count; i++) {
        TSAppNode *node = nodes[i];
        CGPoint origin = tsActualToScriptPoint(node.frame.origin);
        CGPoint center = tsActualToScriptPoint(node.centerPoint);
        CGSize size = node.frame.size;
        if (swapWH) size = CGSizeMake(size.height, size.width);
        lua_pushinteger(L, (lua_Integer)(i + 1));
        lua_newtable(L);
        lua_pushstring(L, "class");       lua_pushstring(L, node.className.UTF8String);      lua_settable(L, -3);
        lua_pushstring(L, "text");        lua_pushstring(L, (node.text ?: @"").UTF8String);  lua_settable(L, -3);
        lua_pushstring(L, "x");           lua_pushnumber(L, origin.x * sc);                  lua_settable(L, -3);
        lua_pushstring(L, "y");           lua_pushnumber(L, origin.y * sc);                  lua_settable(L, -3);
        lua_pushstring(L, "width");       lua_pushnumber(L, size.width * sc);                lua_settable(L, -3);
        lua_pushstring(L, "height");      lua_pushnumber(L, size.height * sc);               lua_settable(L, -3);
        lua_pushstring(L, "centerX");     lua_pushnumber(L, center.x * sc);                  lua_settable(L, -3);
        lua_pushstring(L, "centerY");     lua_pushnumber(L, center.y * sc);                  lua_settable(L, -3);
        lua_settable(L, -3);
    }
    return 1;
}

static int l_appNode_tapByText(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    NSArray<TSAppNode *> *nodes = [[TSAppNodeInfo shared] findByText:@(text)];
    if (nodes.count == 0) { lua_pushboolean(L, 0); return 1; }
    BOOL ok = [[TSAppNodeInfo shared] tapNode:nodes[0]];
    lua_pushboolean(L, ok);
    return 1;
}

static int l_appNode_keep(lua_State *L) { [[TSAppNodeInfo shared] keepTree]; return 0; }
static int l_appNode_unKeep(lua_State *L) { [[TSAppNodeInfo shared] unkeepTree]; return 0; }

#pragma mark - OCR

static int l_screen_findText(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    UIImage *img = [[TSScreenCapture shared] captureImage];
    if (!img) { lua_pushnil(L); return 1; }
    BOOL scriptSpace = NO;
    if (s_scriptOrientation != 0) {
        // 横屏: 竖屏 buffer 里文字是旋转 90° 的竖排, Vision 只识别水平文字, 先旋回脚本方向。
        img = tsRotateToScriptOrientation(img);
        scriptSpace = YES;
    }
    TSOCRResult *res = [[TSOCREngine shared] findText:@(text) inImage:img];
    if (!res) { lua_pushnil(L); return 1; }
    // scriptSpace=YES 时 res.center 已是脚本坐标; 否则是竖屏 buffer 像素, 旋转回脚本坐标系
    CGPoint c = scriptSpace ? res.center : tsBufferToScriptPoint(res.center);
    lua_pushnumber(L, c.x);
    lua_pushnumber(L, c.y);
    return 2;
}

// 把 OCR 结果数组压入 Lua 表
// 表结构: {{string=, x=, y=, w=, h=, confidence=}, ...}
// 坐标已转换为脚本坐标系。
// scriptSpace=YES: 识别图已是脚本方向(tsRotateToScriptOrientation), rect 直接是脚本坐标, 不再旋转;
// scriptSpace=NO: 识别图是竖屏 buffer, rect 是 buffer 像素, 需 tsBufferToScriptPoint 转回脚本坐标。
static void pushOCRResults(lua_State *L, NSArray<TSOCRResult *> *results, BOOL scriptSpace) {
    lua_newtable(L);
    for (NSUInteger i = 0; i < results.count; i++) {
        TSOCRResult *r = results[i];
        CGPoint tl, br;
        if (scriptSpace) {
            tl = CGPointMake(r.rect.origin.x, r.rect.origin.y);
            br = CGPointMake(CGRectGetMaxX(r.rect), CGRectGetMaxY(r.rect));
        } else {
            tl = tsBufferToScriptPoint(CGPointMake(r.rect.origin.x, r.rect.origin.y));
            br = tsBufferToScriptPoint(CGPointMake(CGRectGetMaxX(r.rect), CGRectGetMaxY(r.rect)));
        }
        lua_newtable(L);
        lua_pushstring(L, r.text.UTF8String);
        lua_setfield(L, -2, "string");
        lua_pushnumber(L, tl.x);
        lua_setfield(L, -2, "x");
        lua_pushnumber(L, tl.y);
        lua_setfield(L, -2, "y");
        lua_pushnumber(L, br.x - tl.x);
        lua_setfield(L, -2, "w");
        lua_pushnumber(L, br.y - tl.y);
        lua_setfield(L, -2, "h");
        lua_pushnumber(L, r.confidence);
        lua_setfield(L, -2, "confidence");
        lua_rawseti(L, -2, (int)(i + 1));
    }
}

/// screen.paddleOcr([x1, y1, x2, y2]) → 文本数组
/// 全屏/区域 OCR, 默认中英文, 返回 {string, x, y, w, h, confidence} 列表
static int l_screen_paddleOcr(lua_State *L) {
    CGRect region = CGRectZero;
    if (lua_gettop(L) >= 4) {
        CGFloat x1 = (CGFloat)luaL_checknumber(L, 1);
        CGFloat y1 = (CGFloat)luaL_checknumber(L, 2);
        CGFloat x2 = (CGFloat)luaL_checknumber(L, 3);
        CGFloat y2 = (CGFloat)luaL_checknumber(L, 4);
        region = CGRectMake(x1, y1, x2 - x1, y2 - y1);
    }

    UIImage *img = [[TSScreenCapture shared] captureImage];
    if (!img) { lua_pushnil(L); return 1; }

    BOOL scriptSpace = NO;
    if (s_scriptOrientation != 0) {
        // 横屏: 竖屏 buffer 里文字是旋转 90° 的竖排, Vision 只识别水平文字;
        // 先把整图旋回脚本方向, 之后 region 直接用脚本坐标(不再旋转), 返回坐标也是脚本坐标。
        img = tsRotateToScriptOrientation(img);
        scriptSpace = YES;
    } else if (!CGRectIsEmpty(region)) {
        // 竖屏: 脚本坐标 == buffer 坐标, 恒等变换。
        region = tsScriptToActualRect(region);
    }

    NSArray<TSOCRResult *> *results = [[TSOCREngine shared] recognize:img inRegion:region];
    pushOCRResults(L, results, scriptSpace);
    return 1;
}

/// screen.visionOcr([lang], [x1, y1, x2, y2]) → 文本数组
/// 支持自定义识别语言, 返回 {string, x, y, w, h, confidence} 列表
static int l_screen_visionOcr(lua_State *L) {
    NSString *lang = nil;
    CGRect region = CGRectZero;
    int idx = 1;

    // 第一个参数是字符串 → 识别语言
    if (lua_gettop(L) >= 1 && lua_type(L, 1) == LUA_TSTRING) {
        size_t len = 0;
        const char *s = luaL_checklstring(L, 1, &len);
        lang = [[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding];
        idx = 2;
    }

    // 后续 4 个参数是区域坐标
    if (lua_gettop(L) >= idx + 3) {
        CGFloat x1 = (CGFloat)luaL_checknumber(L, idx);
        CGFloat y1 = (CGFloat)luaL_checknumber(L, idx + 1);
        CGFloat x2 = (CGFloat)luaL_checknumber(L, idx + 2);
        CGFloat y2 = (CGFloat)luaL_checknumber(L, idx + 3);
        region = CGRectMake(x1, y1, x2 - x1, y2 - y1);
    }

    UIImage *img = [[TSScreenCapture shared] captureImage];
    if (!img) { lua_pushnil(L); return 1; }

    BOOL scriptSpace = NO;
    if (s_scriptOrientation != 0) {
        // 横屏: 竖屏 buffer 里文字是旋转 90° 的竖排, Vision 只识别水平文字;
        // 先把整图旋回脚本方向, 之后 region 直接用脚本坐标, 返回坐标也是脚本坐标。
        img = tsRotateToScriptOrientation(img);
        scriptSpace = YES;
    } else if (!CGRectIsEmpty(region)) {
        // 竖屏: 脚本坐标 == buffer 坐标, 恒等变换。
        region = tsScriptToActualRect(region);
    }

    NSArray<NSString *> *languages = lang ? @[lang] : nil;
    NSArray<TSOCRResult *> *results = [[TSOCREngine shared] recognize:img
                                                              inRegion:region
                                                              languages:languages];
    pushOCRResults(L, results, scriptSpace);
    return 1;
}

#pragma mark - JSON

/// 把 Lua 值转为 NSObject (nil→NSNull, table→NSArray/NSDictionary)
static id luaToNSObject(lua_State *L, int idx) {
    switch (lua_type(L, idx)) {
        case LUA_TNIL: return [NSNull null];
        case LUA_TBOOLEAN: return @(lua_toboolean(L, idx));
        case LUA_TNUMBER: return @(lua_tonumber(L, idx));
        case LUA_TSTRING: {
            size_t len = 0;
            const char *s = lua_tolstring(L, idx, &len);
            return [[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding];
        }
        case LUA_TTABLE: {
            // 判断数组/字典: 遍历 key，若含非数字键 → 字典
            BOOL isArray = YES;
            lua_pushnil(L);
            while (lua_next(L, idx) != 0) {
                if (lua_type(L, -2) != LUA_TNUMBER) { isArray = NO; lua_pop(L, 1); break; }
                lua_pop(L, 1);
            }
            if (isArray) {
                lua_len(L, idx);
                lua_Integer n = lua_tointeger(L, -1);
                lua_pop(L, 1);
                NSMutableArray *arr = [NSMutableArray array];
                for (lua_Integer i = 1; i <= n; i++) {
                    lua_rawgeti(L, idx, (lua_Integer)i);
                    id v = luaToNSObject(L, -1);
                    lua_pop(L, 1);
                    [arr addObject:v ?: [NSNull null]];
                }
                return arr;
            } else {
                NSMutableDictionary *dict = [NSMutableDictionary dictionary];
                lua_pushnil(L);
                while (lua_next(L, idx) != 0) {
                    const char *key = lua_tostring(L, -2);
                    id v = luaToNSObject(L, -1);
                    if (key) dict[@(key)] = v ?: [NSNull null];
                    lua_pop(L, 1);
                }
                return dict;
            }
        }
        default: return [NSNull null];
    }
}

static int l_json_encode(lua_State *L) {
    if (lua_gettop(L) < 1) { lua_pushstring(L, "null"); return 1; }
    id obj = luaToNSObject(L, 1);
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj ?: [NSNull null]
                                                  options:0 error:&err];
    if (err || !data) { lua_pushnil(L); return 1; }
    lua_pushlstring(L, data.bytes, data.length);
    return 1;
}

static int l_json_decode(lua_State *L) {
    size_t len = 0;
    const char *s = luaL_checklstring(L, 1, &len);
    NSData *data = [NSData dataWithBytes:s length:len];
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || !obj) { lua_pushnil(L); return 1; }
    _pushNSObjectToLua(L, obj);
    return 1;
}

/// 把 NSObject 推入 Lua（数组→表, 字典→表, 字符串/数字/布尔→对应类型）
static void _pushNSObjectToLua(lua_State *L, id obj) {
    if (obj == nil || [obj isKindOfClass:[NSNull class]]) { lua_pushnil(L); return; }
    if ([obj isKindOfClass:[NSNumber class]]) {
        NSNumber *num = (NSNumber *)obj;
        const char *type = num.objCType;
        if (strcmp(type, @encode(BOOL)) == 0 || strcmp(type, @encode(char)) == 0) {
            lua_pushboolean(L, num.boolValue);
        } else {
            lua_pushnumber(L, num.doubleValue);
        }
        return;
    }
    if ([obj isKindOfClass:[NSString class]]) {
        lua_pushstring(L, ((NSString *)obj).UTF8String);
        return;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        lua_newtable(L);
        NSArray *arr = (NSArray *)obj;
        for (NSUInteger i = 0; i < arr.count; i++) {
            lua_pushinteger(L, (lua_Integer)(i + 1));
            _pushNSObjectToLua(L, arr[i]);
            lua_settable(L, -3);
        }
        return;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        lua_newtable(L);
        NSDictionary *dict = (NSDictionary *)obj;
        for (NSString *key in dict) {
            lua_pushstring(L, key.UTF8String);
            _pushNSObjectToLua(L, dict[key]);
            lua_settable(L, -3);
        }
        return;
    }
    lua_pushstring(L, [[obj description] UTF8String]);
}

#pragma mark - 字符串

static int l_str_md5(lua_State *L) {
    const char *s = luaL_checkstring(L, 1);
    NSData *data = [NSData dataWithBytes:s length:strlen(s)];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *out = [NSMutableString string];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [out appendFormat:@"%02x", digest[i]];
    lua_pushstring(L, out.UTF8String);
    return 1;
}

static int l_str_sha1(lua_State *L) {
    const char *s = luaL_checkstring(L, 1);
    NSData *data = [NSData dataWithBytes:s length:strlen(s)];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *out = [NSMutableString string];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [out appendFormat:@"%02x", digest[i]];
    lua_pushstring(L, out.UTF8String);
    return 1;
}

static int l_str_split(lua_State *L) {
    const char *s = luaL_checkstring(L, 1);
    const char *sep = luaL_optstring(L, 2, ",");
    NSArray *parts = [[NSString stringWithUTF8String:s] componentsSeparatedByString:@(sep)];
    lua_newtable(L);
    for (NSUInteger i = 0; i < parts.count; i++) {
        lua_pushinteger(L, (lua_Integer)(i + 1));
        lua_pushstring(L, ((NSString *)parts[i]).UTF8String);
        lua_settable(L, -3);
    }
    return 1;
}

static int l_str_trim(lua_State *L) {
    const char *s = luaL_checkstring(L, 1);
    NSString *trimmed = [[NSString stringWithUTF8String:s]
                         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    lua_pushstring(L, trimmed.UTF8String);
    return 1;
}

static int l_str_random(lua_State *L) {
    int len = (int)luaL_checkinteger(L, 1);
    static const char alnum[] = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    NSMutableString *out = [NSMutableString string];
    for (int i = 0; i < len; i++) {
        [out appendFormat:@"%c", alnum[arc4random_uniform((uint32_t)(sizeof(alnum) - 1))]];
    }
    lua_pushstring(L, out.UTF8String);
    return 1;
}

static int l_str_urlEncode(lua_State *L) {
    const char *s = luaL_checkstring(L, 1);
    NSString *enc = [[NSString stringWithUTF8String:s]
                     stringByAddingPercentEncodingWithAllowedCharacters:
                     [NSCharacterSet URLQueryAllowedCharacterSet]];
    lua_pushstring(L, enc.UTF8String);
    return 1;
}

static int l_str_urlDecode(lua_State *L) {
    const char *s = luaL_checkstring(L, 1);
    NSString *dec = [[NSString stringWithUTF8String:s] stringByRemovingPercentEncoding];
    lua_pushstring(L, (dec ?: @"").UTF8String);
    return 1;
}

#pragma mark - 文件

static int l_file_read(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    NSError *err = nil;
    NSString *content = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:&err];
    if (err || !content) { lua_pushnil(L); return 1; }
    lua_pushstring(L, content.UTF8String);
    return 1;
}

static int l_file_write(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    const char *content = luaL_checkstring(L, 2);
    NSError *err = nil;
    BOOL ok = [[NSString stringWithUTF8String:content]
               writeToFile:@(path) atomically:YES encoding:NSUTF8StringEncoding error:&err];
    lua_pushboolean(L, ok);
    return 1;
}

static int l_file_exists(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_pushboolean(L, [[NSFileManager defaultManager] fileExistsAtPath:@(path)]);
    return 1;
}

static int l_file_delete(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    NSError *err = nil;
    BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:@(path) error:&err];
    lua_pushboolean(L, ok);
    return 1;
}

static int l_file_documentsDir(lua_State *L) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    lua_pushstring(L, dir.UTF8String);
    return 1;
}

// ── 简化路径: /var/mobile/touch/{lua,log,res} ──
static int l_file_touchDir(lua_State *L) {
    lua_pushstring(L, [TSPaths rootDir].UTF8String);
    return 1;
}

static int l_file_luaDir(lua_State *L) {
    lua_pushstring(L, [TSPaths luaDir].UTF8String);
    return 1;
}

static int l_file_logDir(lua_State *L) {
    lua_pushstring(L, [TSPaths logDir].UTF8String);
    return 1;
}

static int l_file_resDir(lua_State *L) {
    lua_pushstring(L, [TSPaths resDir].UTF8String);
    return 1;
}

static int l_file_readImage(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    UIImage *img = [UIImage imageWithContentsOfFile:@(path)];
    if (!img) { lua_pushnil(L); return 1; }
    lua_pushinteger(L, (lua_Integer)(img.size.width * img.scale));
    lua_pushinteger(L, (lua_Integer)(img.size.height * img.scale));
    return 2;
}

// 返回当前脚本/项目所在目录 (通过读取 _SCRIPT_DIR_ 全局变量)
static int l_file_scriptDir(lua_State *L) {
    lua_getglobal(L, "_SCRIPT_DIR_");
    if (lua_isstring(L, -1)) {
        return 1;
    }
    lua_pop(L, 1);
    lua_pushstring(L, [TSPaths luaDir].UTF8String);
    return 1;
}

/// file.addText(path, text)
/// 追加文本到文件末尾 (文件不存在则创建)
static int l_file_addText(lua_State *L) {
    const char *p = luaL_checkstring(L, 1);
    size_t tlen = 0;
    const char *t = luaL_checklstring(L, 2, &tlen);
    NSString *path = @(p);
    NSString *text = [[NSString alloc] initWithBytes:t length:tlen encoding:NSUTF8StringEncoding];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        // 不存在则直接写入
        NSError *err = nil;
        BOOL ok = [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
        lua_pushboolean(L, ok);
        return 1;
    }
    // 读取已有内容并追加 (大文件场景不优, 但 Lua API 用途如此)
    NSError *err = nil;
    NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
    if (err) { lua_pushboolean(L, NO); return 1; }
    NSString *combined = [existing stringByAppendingString:text];
    BOOL ok = [combined writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
    lua_pushboolean(L, ok);
    return 1;
}

/// file.size(path) → number
/// 文件大小 (字节), 不存在返回 -1
static int l_file_size(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    NSError *err = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:@(path) error:&err];
    if (err || !attrs) { lua_pushinteger(L, -1); return 1; }
    unsigned long long sz = [attrs fileSize];
    lua_pushnumber(L, (lua_Number)sz);
    return 1;
}

/// file.list(path) → table
/// 列出目录下文件名 (不含路径, 不递归)
static int l_file_list(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    NSError *err = nil;
    NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@(path) error:&err];
    if (err) { lua_pushnil(L); return 1; }
    lua_newtable(L);
    for (NSUInteger i = 0; i < items.count; i++) {
        lua_pushstring(L, items[i].UTF8String);
        lua_rawseti(L, -2, (int)(i + 1));
    }
    return 1;
}

/// file.md5(path) → string / nil
/// 计算文件 MD5 (十六进制小写)
static int l_file_md5(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    NSData *data = [NSData dataWithContentsOfFile:@(path)];
    if (!data) { lua_pushnil(L); return 1; }

    uint8_t digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    lua_pushstring(L, hex.UTF8String);
    return 1;
}

/// file.getLines(path) → table / nil
/// 读取所有行 (按 \n 分割, 不含换行符)
static int l_file_getLines(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    NSError *err = nil;
    NSString *content = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:&err];
    if (err || !content) { lua_pushnil(L); return 1; }
    NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
    lua_newtable(L);
    for (NSUInteger i = 0; i < lines.count; i++) {
        lua_pushstring(L, lines[i].UTF8String);
        lua_rawseti(L, -2, (int)(i + 1));
    }
    return 1;
}

/// file.lineCount(path) → number
/// 总行数 (不存在或读取失败返回 -1)
static int l_file_lineCount(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    NSError *err = nil;
    NSString *content = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:&err];
    if (err || !content) { lua_pushinteger(L, -1); return 1; }
    NSUInteger count = [content componentsSeparatedByString:@"\n"].count;
    lua_pushinteger(L, (lua_Integer)count);
    return 1;
}

/// file.getLineText(path, n) → string / nil
/// 获取第 n 行 (1-based)
static int l_file_getLineText(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    int n = (int)luaL_checkinteger(L, 2);
    if (n < 1) { lua_pushnil(L); return 1; }
    NSError *err = nil;
    NSString *content = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:&err];
    if (err || !content) { lua_pushnil(L); return 1; }
    NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
    if ((NSUInteger)n > lines.count) { lua_pushnil(L); return 1; }
    lua_pushstring(L, lines[(NSUInteger)(n - 1)].UTF8String);
    return 1;
}

/// file.resetLineText(path, n, text)
/// 替换第 n 行 (1-based), 行不存在则不操作
static int l_file_resetLineText(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    int n = (int)luaL_checkinteger(L, 2);
    size_t tlen = 0;
    const char *t = luaL_checklstring(L, 3, &tlen);
    if (n < 1) { lua_pushboolean(L, NO); return 1; }

    NSError *err = nil;
    NSString *content = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:&err];
    if (err || !content) { lua_pushboolean(L, NO); return 1; }
    NSMutableArray<NSString *> *lines = [[content componentsSeparatedByString:@"\n"] mutableCopy];
    if ((NSUInteger)n > lines.count) { lua_pushboolean(L, NO); return 1; }
    lines[(NSUInteger)(n - 1)] = [[NSString alloc] initWithBytes:t length:tlen encoding:NSUTF8StringEncoding];
    NSString *result = [lines componentsJoinedByString:@"\n"];
    BOOL ok = [result writeToFile:@(path) atomically:YES encoding:NSUTF8StringEncoding error:&err];
    lua_pushboolean(L, ok);
    return 1;
}

/// file.insertLineText(path, n, text)
/// 在第 n 行前插入一行 (1-based), n 超过总行数则追加到末尾
static int l_file_insertLineText(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    int n = (int)luaL_checkinteger(L, 2);
    size_t tlen = 0;
    const char *t = luaL_checklstring(L, 3, &tlen);
    if (n < 1) { lua_pushboolean(L, NO); return 1; }

    NSError *err = nil;
    NSString *content = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:&err];
    if (err || !content) { lua_pushboolean(L, NO); return 1; }
    NSMutableArray<NSString *> *lines = [[content componentsSeparatedByString:@"\n"] mutableCopy];
    NSString *newLine = [[NSString alloc] initWithBytes:t length:tlen encoding:NSUTF8StringEncoding];
    NSUInteger insertIdx = (NSUInteger)(n - 1);
    if (insertIdx >= lines.count) {
        [lines addObject:newLine];
    } else {
        [lines insertObject:newLine atIndex:insertIdx];
    }
    NSString *result = [lines componentsJoinedByString:@"\n"];
    BOOL ok = [result writeToFile:@(path) atomically:YES encoding:NSUTF8StringEncoding error:&err];
    lua_pushboolean(L, ok);
    return 1;
}

#pragma mark - 剪贴板

static int l_pasteboard_get(lua_State *L) {
    NSString *s = [UIPasteboard generalPasteboard].string;
    lua_pushstring(L, (s ?: @"").UTF8String);
    return 1;
}

static int l_pasteboard_set(lua_State *L) {
    const char *s = luaL_checkstring(L, 1);
    [UIPasteboard generalPasteboard].string = @(s);
    return 0;
}

#pragma mark - 键盘

static int l_key_home(lua_State *L) { [[TSKeyboardInjector shared] pressHome]; return 0; }
static int l_key_lock(lua_State *L) { [[TSKeyboardInjector shared] pressLock]; return 0; }
static int l_key_volumeUp(lua_State *L) { [[TSKeyboardInjector shared] pressVolumeUp]; return 0; }
static int l_key_volumeDown(lua_State *L) { [[TSKeyboardInjector shared] pressVolumeDown]; return 0; }
static int l_key_inputText(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    [[TSKeyboardInjector shared] inputText:@(text)];
    return 0;
}

#pragma mark - 脚本网页设置 UI

// 检测脚本网页设置 UI 是否存在:
//   设备: /var/mobile/touch/lua/ui/<name>/index.html (优先)
//   内置: bundle www/ui/<name>/index.html
// 供 ui.open() 在弹出前判断, 也供脚本内检测 UI 是否可用。
static BOOL TS_ScriptUIExists(NSString *name) {
    if (name.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *devPath = [[[TSPaths luaDir] stringByAppendingPathComponent:@"ui"]
                         stringByAppendingPathComponent:name];
    devPath = [devPath stringByAppendingPathComponent:@"index.html"];
    if ([fm fileExistsAtPath:devPath]) return YES;
    NSString *bundlePath = [[[[NSBundle mainBundle] resourcePath]
                             stringByAppendingPathComponent:@"www"]
                            stringByAppendingPathComponent:@"ui"];
    bundlePath = [[bundlePath stringByAppendingPathComponent:name]
                  stringByAppendingPathComponent:@"index.html"];
    return [fm fileExistsAtPath:bundlePath];
}

// ui.open(脚本名) -> boolean
//   检测脚本网页设置 UI (内置 www/ui/<name> 或设备 lua/ui/<name>):
//     - 不存在 → 直接返回 false, 不阻塞, 脚本按默认配置继续
//     - 存在   → 全屏弹出网页设置页, 阻塞等待用户操作:
//                 点"开始运行" → 返回 true (已注入全局 settings 表)
//                 点"‹ 返回"   → 返回 false (按默认配置继续)
//   阻塞期间可点主界面"停止"取消: 返回 false 并强制关闭设置页。
//   用法: 在 main.lua 开头写死 if ui.open("main") then ... end
//
//   非前台场景: App 在后台 (游戏等 app 在前台) 时, iOS 会暂停 App 的渲染,
//   即使 HUD 远程上下文托管成功, WKWebView 网页内容也无法提交 → 设置页空白。
//   因此 ui.open 触发时若 App 不在前台, 先把本 App 切回前台恢复渲染, 等约
//   1 秒后再显示设置页; 设置页关闭后自动切回原前台 App, 脚本流程不被中断。
//   若 1 秒后仍未切回前台 (切前台失败), 回退到 TSHUDHost 系统级层承载。
static int l_ui_open(lua_State *L) {
    const char *nameC = luaL_checkstring(L, 1);
    NSString *name = [NSString stringWithUTF8String:nameC];
    if (name.length == 0 || !TS_ScriptUIExists(name)) {
        lua_pushboolean(L, 0);
        return 1;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL ran = NO;
    __block BOOL finished = NO;
    __block TSScriptUIViewController *vc = nil;
    // 打开设置页前的前台 App (仅"强制切回本 App"路径使用):
    // 设置页关闭后切回该 App, 保证脚本流程连续 (游戏自动化不被中断)。
    __block NSString *prevFrontBid = nil;

    // 显示设置页 (主线程)。强制切到前台后延迟调用, 确保 App 渲染已恢复。
    void (^showScriptUI)(void) = ^{
        BOOL appActive = ([UIApplication sharedApplication].applicationState == UIApplicationStateActive);
        vc = [[TSScriptUIViewController alloc] initWithScriptName:name title:name];
        vc.onFinish = ^(BOOL didRun) {
            if (!finished) {
                ran = didRun;
                finished = YES;
                dispatch_semaphore_signal(sem);
            }
            // 若 ui.open 之前把本 App 强制切到前台 (原本在游戏等 app),
            // 设置页关闭后切回原前台 App, 脚本继续在原 App 上执行。
            if (prevFrontBid.length > 0) {
                NSString *bid = prevFrontBid;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [[TSAppManager shared] openApp:bid];
                });
            }
        };
        if (!appActive) {
            // 延迟 1 秒后仍不在前台 (切前台失败): 回退到 TSHUDHost 系统级层
            // 承载 (原逻辑), 挂上去能看到就看, 看不到也不阻塞脚本。
            vc.hostedInHUD = YES;
            BOOL shown = [[TSHUDHost shared] presentViewControllerInHUD:vc];
            if (!shown) {
                // HUD 不可用 (SBS 未托管成功 且 app 不在前台): 挂上去也看不到,
                // 直接结束等待, 避免 Lua 永久卡死 (脚本按默认配置继续)。
                vc = nil;
                finished = YES;
                dispatch_semaphore_signal(sem);
            }
            return;
        }
        // App 前台: 在主窗口 present (原逻辑)
        NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
        UIWindow *keyWindow = nil;
        for (UIWindow *w in windows) {
            if (w.isKeyWindow) { keyWindow = w; break; }
        }
        if (!keyWindow) keyWindow = windows.firstObject;
        UIViewController *top = keyWindow.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        if (!top) {
            // 无可用窗口, 直接结束等待, 避免 Lua 永久卡死
            finished = YES;
            dispatch_semaphore_signal(sem);
            return;
        }
        [top presentViewController:vc animated:YES completion:nil];
    };

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            // App 不在前台 (游戏等 app 在前台): 后台时 iOS 暂停 App 渲染,
            // 即使 HUD 远程上下文托管成功, WKWebView 网页内容也无法提交到
            // 系统层 → 设置页空白。先把本 App 切回前台恢复渲染, 等约 1 秒
            // (页面加载 + 渲染稳定) 后再显示设置页。
            NSLog(@"[QQ音乐] ui.open(%@): App 不在前台, 先切回前台(1s)再显示", name);
            prevFrontBid = [[TSAppManager shared] frontBid];
            if (prevFrontBid.length == 0 ||
                [prevFrontBid isEqualToString:[NSBundle mainBundle].bundleIdentifier]) {
                prevFrontBid = nil; // 本就在本 App / 获取失败, 无需切回
            }
            [[TSAppManager shared] openApp:[NSBundle mainBundle].bundleIdentifier];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                showScriptUI();
            });
            return;
        }
        showScriptUI();
    });

    // Lua 线程阻塞等待: 分段等待并检查停止标志, 保证点"停止"后设置页立即关闭
    while (!finished && !_stopRequested) {
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) == 0) {
            break;  // 用户点"开始运行"或"返回", 已收到信号
        }
    }
    if (!finished && _stopRequested) {
        // 脚本被停止: 强制关闭设置页。
        // 若已由网页"取消"按钮触发 (TSScriptUIViewController 已自行 stop + dismiss),
        // 不再重复 dismiss。
        if (vc && !vc.cancelRequested) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (vc.hostedInHUD) {
                    // HUD 承载模式: 直接移除 view (未被 present, dismiss 无效)
                    [[TSHUDHost shared] dismissViewControllerFromHUD:vc];
                } else {
                    [vc dismissViewControllerAnimated:NO completion:nil];
                }
            });
        }
        lua_pushboolean(L, 0);
        return 1;
    }
    if (ran) {
        // 用户点"开始运行": 网页已把配置写入 /var/mobile/touch/lua/<name>.settings.json,
        // 注入全局 settings 表, 让脚本后续读取逻辑与主界面打开 UI 时一致。
        NSString *luaPath = [[TSPaths luaDir] stringByAppendingPathComponent:
                             [name stringByAppendingString:@".lua"]];
        [[TSLuaBridge shared] _injectSettingsTable:L scriptPath:luaPath];
    }
    lua_pushboolean(L, ran ? 1 : 0);
    return 1;
}

#pragma mark - 注册

static void lua_register_all(lua_State *L) {
    // ── 全局函数 ──
    // luaL_setfuncs 需要把函数写进栈顶的表；这里先压入全局表 _G，写完再弹出。
    lua_pushglobaltable(L);
    static const luaL_Reg globals[] = {
        {"print",       l_global_print},
        {"logStr",      l_global_logStr},
        {"toast",       l_global_toast},
        {"mSleep",      l_global_mSleep},
        {"sleep",       l_global_sleep},
        {"findColor",   l_screen_findColor},
        {"findColors",  l_screen_findColors},
        {"findImage",   l_screen_findImage},
        {"getColor",    l_screen_getColor},
        {"snapshot",    l_screen_snapshot},
        {"keepScreen",  l_screen_keepScreen},
        {"keep",        l_screen_keep},
        {"unkeep",      l_screen_unkeep},
        {"getScreenSize", l_screen_getSize},
        {"tap",         l_touch_tap},
        {"touchDown",   l_touch_down},
        {"touchMove",   l_touch_move},
        {"touchUp",     l_touch_up},
        {"swipe",       l_touch_swipe},
        {"stroke",      l_touch_stroke},
        {"touchStatus", l_touch_status},
        {"findText",    l_screen_findText},
        {NULL, NULL}
    };
    luaL_setfuncs(L, globals, 0);
    lua_pop(L, 1);  // 弹出 _G

    // ── touch 模块 ──
    static const luaL_Reg touchLib[] = {
        {"tap",      l_touch_tap},
        {"down",     l_touch_down},
        {"move",     l_touch_move},
        {"up",       l_touch_up},
        {"swipe",    l_touch_swipe},
        {"stroke",   l_touch_stroke},
        {"status",   l_touch_status},
        {NULL, NULL}
    };
    luaL_newlib(L, touchLib);
    lua_setglobal(L, "touch");

    // ── screen 模块 ──
    static const luaL_Reg screenLib[] = {
        {"init",       l_screen_init},
        {"findColor",  l_screen_findColor},
        {"findColors", l_screen_findColors},
        {"findImage",  l_screen_findImage},
        {"getColor",   l_screen_getColor},
        {"getColorRGB", l_screen_getColorRGB},
        {"snapshot",   l_screen_snapshot},
        {"keepScreen", l_screen_keepScreen},
        {"keep",       l_screen_keep},
        {"unkeep",     l_screen_unkeep},
        {"getSize",    l_screen_getSize},
        {"findText",   l_screen_findText},
        {"paddleOcr",  l_screen_paddleOcr},
        {"visionOcr",  l_screen_visionOcr},
        {NULL, NULL}
    };
    luaL_newlib(L, screenLib);
    lua_setglobal(L, "screen");

    // ── sys 模块 ──
    static const luaL_Reg sysLib[] = {
        {"info",        l_sys_info},
        {"osVersion",   l_sys_osVersion},
        {"model",       l_sys_model},
        {"screenSize",  l_sys_screenSize},
        {"getIP",       l_sys_getIP},
        {"battery",     l_sys_battery},
        {"alert",       l_sys_alert},
        {"alertButtons",l_sys_alertButtons},
        {"toast",       l_sys_toast},
        {"setFloatBallPoint", l_sys_setFloatBallPoint},
        {"mtime",              l_sys_mtime},
        {"availableMemory",    l_sys_availableMemory},
        {"processUsedMemory",  l_sys_processUsedMemory},
        {"usedMemory",          l_sys_usedMemory},
        {"version",             l_sys_version},
        {"palyAudio",           l_sys_palyAudio},
        {NULL, NULL}
    };
    luaL_newlib(L, sysLib);
    lua_setglobal(L, "sys");

    // ── device 模块 ──
    static const luaL_Reg deviceLib[] = {
        {"udid",                  l_device_udid},
        {"serialNumber",          l_device_serialNumber},
        {"turnOnAssistiveTouch",  l_device_turnOnAssistiveTouch},
        {"turnOffAssistiveTouch", l_device_turnOffAssistiveTouch},
        {"isScreenLocked",        l_device_isScreenLocked},
        {"unlockScreen",          l_device_unlockScreen},
        {"name",                  l_device_name},
        {"type",                  l_device_type},
        {"backlightLevel",        l_device_backlightLevel},
        {"setBacklightLevel",     l_device_setBacklightLevel},
        {"lockScreen",            l_device_lockScreen},
        {"vibrator",              l_device_vibrator},
        {"setVolume",             l_device_setVolume},
        {NULL, NULL}
    };
    luaL_newlib(L, deviceLib);
    lua_setglobal(L, "device");

    // ── app 模块 ──
    static const luaL_Reg appLib[] = {
        {"frontBid",   l_app_frontBid},
        {"isInstalled",l_app_isInstalled},
        {"open",       l_app_open},
        {"close",      l_app_close},
        {"inputText",  l_app_inputText},
        {NULL, NULL}
    };
    luaL_newlib(L, appLib);
    lua_setglobal(L, "app");

    // ── appNode 模块 ──
    static const luaL_Reg appNodeLib[] = {
        {"info",       l_appNode_info},
        {"findByText", l_appNode_findByText},
        {"tapByText",  l_appNode_tapByText},
        {"keep",       l_appNode_keep},
        {"unKeep",     l_appNode_unKeep},
        {NULL, NULL}
    };
    luaL_newlib(L, appNodeLib);
    lua_setglobal(L, "appNode");

    // ── json 模块 ──
    static const luaL_Reg jsonLib[] = {
        {"encode", l_json_encode},
        {"decode", l_json_decode},
        {NULL, NULL}
    };
    luaL_newlib(L, jsonLib);
    lua_setglobal(L, "json");

    // ── str 模块 ──
    static const luaL_Reg strLib[] = {
        {"md5",       l_str_md5},
        {"sha1",      l_str_sha1},
        {"split",     l_str_split},
        {"trim",      l_str_trim},
        {"random",    l_str_random},
        {"urlEncode", l_str_urlEncode},
        {"urlDecode", l_str_urlDecode},
        {NULL, NULL}
    };
    luaL_newlib(L, strLib);
    lua_setglobal(L, "str");

    // ── file 模块 ──
    static const luaL_Reg fileLib[] = {
        {"read",    l_file_read},
        {"write",   l_file_write},
        {"exists",  l_file_exists},
        {"delete",  l_file_delete},
        {"documentsDir", l_file_documentsDir},
        {"touchDir", l_file_touchDir},  // /var/mobile/touch
        {"luaDir",   l_file_luaDir},    // /var/mobile/touch/lua  (脚本)
        {"logDir",   l_file_logDir},    // /var/mobile/touch/log  (日志)
        {"resDir",   l_file_resDir},    // /var/mobile/touch/res  (资源)
        {"scriptDir", l_file_scriptDir}, // 当前脚本/项目所在目录
        {"readImage",    l_file_readImage},
        {"addText",      l_file_addText},
        {"size",         l_file_size},
        {"list",         l_file_list},
        {"md5",          l_file_md5},
        {"getLines",     l_file_getLines},
        {"lineCount",    l_file_lineCount},
        {"getLineText",  l_file_getLineText},
        {"resetLineText",l_file_resetLineText},
        {"insertLineText", l_file_insertLineText},
        {NULL, NULL}
    };
    luaL_newlib(L, fileLib);
    lua_setglobal(L, "file");

    // ── pasteboard 模块 ──
    static const luaL_Reg pasteboardLib[] = {
        {"get", l_pasteboard_get},
        {"set", l_pasteboard_set},
        {NULL, NULL}
    };
    luaL_newlib(L, pasteboardLib);
    lua_setglobal(L, "pasteboard");

    // ── key 模块 ──
    static const luaL_Reg keyLib[] = {
        {"pressHome",     l_key_home},
        {"pressLock",     l_key_lock},
        {"pressVolumeUp", l_key_volumeUp},
        {"pressVolumeDown", l_key_volumeDown},
        {"inputText",     l_key_inputText},
        {NULL, NULL}
    };
    luaL_newlib(L, keyLib);
    lua_setglobal(L, "key");

    // ── ui 模块 (脚本网页设置 UI) ──
    static const luaL_Reg uiLib[] = {
        {"open",   l_ui_open},
        {NULL, NULL}
    };
    luaL_newlib(L, uiLib);
    lua_setglobal(L, "ui");
}

#pragma mark - 执行

- (void)runString:(NSString *)code {
    // 注意: 绝不能用 @synchronized(self) 包住 _execute ——
    // 脚本运行期间会一直持有 self 锁, 主线程 stop() 抢锁会永久阻塞导致应用卡死。
    // _luaQueue 本身就是串行队列, 已保证同一时间只有一个脚本在跑。
    dispatch_async(_luaQueue, ^{
        // 未激活设备 15 分钟试用到期后禁止再启动脚本
        if ([[TSTrialManager shared] isExpired]) {
            lua_log(@"[Lua] 15 分钟试用已结束，请到 设置-卡密 激活后继续使用");
            return;
        }
        [self _execute:code filePath:nil];
    });
}

- (void)runFile:(NSString *)path {
    dispatch_async(_luaQueue, ^{
        // 未激活设备 15 分钟试用到期后禁止再启动脚本
        if ([[TSTrialManager shared] isExpired]) {
            lua_log(@"[Lua] 15 分钟试用已结束，请到 设置-卡密 激活后继续使用");
            return;
        }
        NSError *err = nil;
        NSString *code = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
        if (err || !code) {
            lua_log([NSString stringWithFormat:@"[Lua] 读取脚本失败: %@", path]);
            return;
        }
        // .tas 加密脚本: 先解密再交给 Lua 引擎
        if ([TSScriptCipher isEncryptedContent:code]) {
            NSString *plain = [TSScriptCipher decryptScript:code];
            if (!plain) {
                lua_log([NSString stringWithFormat:@"[Lua] 脚本解密失败(.tas): %@", path]);
                return;
            }
            code = plain;
            lua_log([NSString stringWithFormat:@"[Lua] 运行加密脚本(.tas): %@", path.lastPathComponent]);
        }
        [self _execute:code filePath:path];
    });
}

- (void)runProject:(NSString *)dirPath {
    dispatch_async(_luaQueue, ^{
        if ([[TSTrialManager shared] isExpired]) {
            lua_log(@"[Lua] 15 分钟试用已结束，请到 设置-卡密 激活后继续使用");
            return;
        }

        // 查找入口文件
        NSString *entryFile = [self _findEntryPointInDirectory:dirPath];
        if (!entryFile) {
            lua_log([NSString stringWithFormat:@"[Lua] 项目目录 %@ 中未找到 .lua 文件", dirPath]);
            return;
        }

        // 读取入口文件
        NSError *err = nil;
        NSString *code = [NSString stringWithContentsOfFile:entryFile encoding:NSUTF8StringEncoding error:&err];
        if (err || !code) {
            lua_log([NSString stringWithFormat:@"[Lua] 读取项目入口文件失败: %@", entryFile]);
            return;
        }

        lua_log([NSString stringWithFormat:@"[Lua] 运行项目: %@ (入口: %@)",
                 dirPath.lastPathComponent, entryFile.lastPathComponent]);

        // 执行, 传入项目目录作为第二个参数
        [self _executeProject:code entryFile:entryFile projectDir:dirPath];
    });
}

// 在目录中查找 Lua 入口文件
- (NSString *)_findEntryPointInDirectory:(NSString *)dirPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dirPath isDirectory:&isDir] || !isDir) return nil;

    NSArray *contents = [fm contentsOfDirectoryAtPath:dirPath error:nil];
    if (!contents) return nil;

    // 按优先级查找入口文件
    NSArray *preferred = @[@"main.lua", @"init.lua", @"index.lua", @"app.lua"];
    for (NSString *name in preferred) {
        NSString *fullPath = [dirPath stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:fullPath]) return fullPath;
    }

    // 没有首选入口 → 找第一个 .lua 文件
    NSPredicate *luaPred = [NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *b) {
        return [name.pathExtension.lowercaseString isEqualToString:@"lua"];
    }];
    NSArray *luaFiles = [[contents filteredArrayUsingPredicate:luaPred] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    if (luaFiles.count > 0) {
        return [dirPath stringByAppendingPathComponent:luaFiles[0]];
    }

    return nil;
}

- (void)stop {
    // 直接写 volatile 标志, 不抢 self 锁: 脚本正在 _luaQueue 上跑, 主线程这里必须能立即返回,
    // 否则若脚本是死循环(不检查 _stopRequested), 主线程会永远卡在锁上, 整个 App 无响应。
    _stopRequested = YES;
    self.isPaused = NO;
    // 立即补发所有未抬起的触摸，避免脚本被中断后留下"幽灵手指"导致屏幕点击无响应
    [[TSHIDEventTouch shared] releaseAllTouches];
    dispatch_async(_luaQueue, ^{
        // 等待当前脚本循环退出后重置标志
        dispatch_async(dispatch_get_main_queue(), ^{
            self.runningPath = nil;
            self.isRunning = NO;
        });
    });
}

// 暂停当前脚本: 设置标志, Lua 线程在指令钩子/mSleep 处阻塞等待。
- (void)pause {
    if (!self.isRunning) return;
    _pauseRequested = YES;
    self.isPaused = YES;
    // 补发未抬起的触摸, 避免脚本停在拖动/按下中途留下"幽灵手指"
    [[TSHIDEventTouch shared] releaseAllTouches];
    lua_log(@"[Lua] 脚本已暂停 (再次按音量键可继续/停止)");
}

// 恢复被暂停的脚本
- (void)resume {
    _pauseRequested = NO;
    self.isPaused = NO;
    lua_log(@"[Lua] 脚本已继续");
}

#pragma mark - 网页设置注入

// 递归: 把 NSDictionary/NSArray/NSString/NSNumber 转成 Lua 值
static void lua_pushJSONObject(lua_State *L, id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        lua_newtable(L);
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            lua_pushstring(L, [k description].UTF8String);
            lua_pushJSONObject(L, v);
            lua_rawset(L, -3);
        }];
    } else if ([obj isKindOfClass:[NSArray class]]) {
        lua_newtable(L);
        [(NSArray *)obj enumerateObjectsUsingBlock:^(id v, NSUInteger i, BOOL *stop) {
            lua_pushinteger(L, (lua_Integer)i + 1);
            lua_pushJSONObject(L, v);
            lua_rawset(L, -3);
        }];
    } else if ([obj isKindOfClass:[NSString class]]) {
        lua_pushstring(L, ((NSString *)obj).UTF8String);
    } else if ([obj isKindOfClass:[NSNumber class]]) {
        // 布尔: objCType 为 'c'(char) 或 'B'(BOOL), 其余按数字处理
        const char *otype = [(NSNumber *)obj objCType];
        if (otype && (otype[0] == 'c' || otype[0] == 'B')) {
            lua_pushboolean(L, [obj boolValue]);
        } else {
            lua_pushnumber(L, [obj doubleValue]);
        }
    } else {
        lua_pushnil(L);
    }
}

// 把设置 JSON 解析后注入全局 settings 表; 找不到则注入空表
// 查找顺序:
//   1) 网页设置 UI 约定: /var/mobile/touch/lua/<脚本名>.settings.json
//      (内置脚本运行时路径在 bundle 内, 必须按脚本名去设备目录找)
//   2) 脚本旁侧文件: <脚本路径>.settings.json
- (void)_injectSettingsTable:(lua_State *)L scriptPath:(NSString *)path {
    NSString *settingsPath = nil;
    if (path.length) {
        NSString *fileName = path.lastPathComponent; // 如 demo.lua
        NSString *baseName = fileName.stringByDeletingPathExtension;
        NSString *devPath = [[TSPaths luaDir]
            stringByAppendingPathComponent:[baseName stringByAppendingString:@".settings.json"]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:devPath]) {
            settingsPath = devPath;
        } else {
            NSString *sidePath = [path stringByAppendingString:@".settings.json"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:sidePath]) {
                settingsPath = sidePath;
            }
        }
    }
    if (settingsPath) {
        NSData *data = [NSData dataWithContentsOfFile:settingsPath];
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([obj isKindOfClass:[NSDictionary class]]) {
            lua_pushJSONObject(L, obj);
            lua_setglobal(L, "settings");
            lua_log([NSString stringWithFormat:@"[设置] 已加载网页配置 %@ (%lu 项)",
                     settingsPath.lastPathComponent,
                     (unsigned long)[(NSDictionary *)obj count]]);
            return;
        }
    }
    lua_newtable(L);
    lua_setglobal(L, "settings");
}

- (void)_execute:(NSString *)code filePath:(NSString *)path {
    _stopRequested = NO;
    _pauseRequested = NO;
    self.isPaused = NO;
    self.runningPath = path;
    self.isRunning = YES;
    // 明确标记脚本真正进入执行阶段, 便于远程启动排查
    lua_log([NSString stringWithFormat:@"[Lua] 开始运行: %@",
             path ? path.lastPathComponent : @"(字符串代码)"]);

    // 预热 HUD 宿主 (单 App 架构): 提前创建全屏透明窗口并注册 SBS 系统级托管,
    // 使首次音量键弹窗即时可用; 失败不阻塞脚本 (弹窗会回退前台可见/静默切换)。
    // 注意: warmUp 只是调用 start, SBS 托管是异步注册(延迟 0.8s + 每 0.5s 重试),
    // 不能立即宣称"已就绪"; 等 2.5s 后输出真实注册状态, 便于诊断后台弹窗不可用问题。
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [[TSHUDService sharedInstance] warmUp];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            lua_log([NSString stringWithFormat:@"[HUD] %@",
                     [[TSHUDHost shared] registrationStatusDescription]]);
        });
    });

    // 后台保活: 用户切到游戏/其他 app 时 App 处于后台, iOS 会挂起后台进程,
    // 导致音量键监听与 IOHID 直发触摸停摆。用静音音频播放阻止挂起
    // (需 Info.plist UIBackgroundModes=audio, 见 project.yml)。
    [[TSAudioKeepAlive shared] start];
    // 音量键识别: App 进程内监听私有音量通知 + 轮询 AVAudioSession.outputVolume
    // (物理按键事件广播, 静音/音量到 0 时也响应, 对齐 TrollAutoScript)。
    // 监听由 TAS 服务启动时的常驻监听
    // (startGlobalVolumeMonitoring) 统一管理, 脚本运行/结束不启停监听:
    //   脚本运行中 → _handleVolumeKey → 控制菜单 (暂停/继续·停止·取消);
    //   空闲未运行 → _handleIdleVolumeKey → 询问"运行选中脚本?"。

    lua_State *L = luaL_newstate();
    if (!L) {
        lua_log(@"[Lua] 创建 Lua 状态失败");
        self.runningPath = nil;
        self.isRunning = NO;
        return;
    }
    luaL_openlibs(L);
    lua_register_all(L);

    // 设置脚本路径全局变量(原版兼容: _SCRIPT_PATH_)
    if (path) {
        lua_pushstring(L, path.UTF8String);
        lua_setglobal(L, "_SCRIPT_PATH_");
    }

    // 脚本网页设置 UI: 注入全局 settings 表 (用户经网页配置, 存于 <脚本>.settings.json)
    [self _injectSettingsTable:L scriptPath:path];

    // 注意: 长度必须用 UTF-8 字节数(strlen)，不能用 code.length(NSString 字符数)。
    // 否则含中文的脚本会被截断, 报 ")` expected near <eof>" 之类的假语法错误。
    const char *utf8Code = code.UTF8String;
    int ret = luaL_loadbuffer(L, utf8Code, strlen(utf8Code),
                              path ? path.lastPathComponent.UTF8String : "=(string)");
    if (ret != LUA_OK) {
        size_t errLen = 0;
        const char *errMsg = lua_tolstring(L, -1, &errLen);
        lua_log([NSString stringWithFormat:@"[Lua] 语法错误: %@", luaToNSString(errMsg, errLen)]);
        lua_close(L);
        self.runningPath = nil;
        self.isRunning = NO;
        return;
    }

    // 注册指令计数钩子(每 5000 条指令检查一次停止标志)。
    // 开销极小，但能保证死循环脚本也能被"停止"按钮真正中断。
    lua_sethook(L, luaStopHook, LUA_MASKCOUNT, 5000);

    int pcallRet = lua_pcall(L, 0, 0, 0);
    if (pcallRet != LUA_OK) {
        size_t errLen = 0;
        const char *err = lua_tolstring(L, -1, &errLen);
        lua_log([NSString stringWithFormat:@"[Lua] 运行错误: %@", luaToNSString(err, errLen)]);
        lua_pop(L, 1);
    }
    lua_close(L);

    // 兜底：无论脚本如何结束(正常/停止/报错)，都释放所有残留触摸
    [[TSHIDEventTouch shared] releaseAllTouches];

    _stopRequested = NO;
    _pauseRequested = NO;
    self.isPaused = NO;
    self.runningPath = nil;
    self.isRunning = NO;
    // 脚本结束, 停止后台静音保活 (App 回到正常后台生命周期)
    [[TSAudioKeepAlive shared] stop];
    // 脚本结束, 自动关闭 App 内音量键菜单(若仍在显示)
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.volumeMenuAlert) {
            [self.volumeMenuAlert dismissViewControllerAnimated:NO completion:nil];
            self.volumeMenuAlert = nil;
        }
    });
    lua_log(@"[Lua] 脚本执行结束");
}

// ═══════════ 项目执行 (文件夹) ═══════════
// 与 _execute:filePath: 类似, 但额外设置:
//   - _SCRIPT_DIR_ 全局变量 (项目目录)
//   - _PROJECT_DIR_ 全局变量 (项目目录, 同义)
//   - Lua package.path 包含项目目录 (支持 require())
//   - 自定义 dofile/loadfile 可解析相对路径
- (void)_executeProject:(NSString *)code entryFile:(NSString *)entryFile projectDir:(NSString *)projectDir {
    _stopRequested = NO;
    _pauseRequested = NO;
    self.isPaused = NO;
    self.runningPath = entryFile;
    self.isRunning = YES;

    // 预热 HUD + 保活 (与 _execute 相同)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [[TSHUDService sharedInstance] warmUp];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            lua_log([NSString stringWithFormat:@"[HUD] %@",
                     [[TSHUDHost shared] registrationStatusDescription]]);
        });
    });
    [[TSAudioKeepAlive shared] start];

    lua_State *L = luaL_newstate();
    if (!L) {
        lua_log(@"[Lua] 创建 Lua 状态失败");
        self.runningPath = nil;
        self.isRunning = NO;
        return;
    }
    luaL_openlibs(L);
    lua_register_all(L);

    // 设置路径全局变量
    lua_pushstring(L, entryFile.UTF8String);
    lua_setglobal(L, "_SCRIPT_PATH_");
    lua_pushstring(L, projectDir.UTF8String);
    lua_setglobal(L, "_SCRIPT_DIR_");
    lua_pushstring(L, projectDir.UTF8String);
    lua_setglobal(L, "_PROJECT_DIR_");

    // 配置 Lua package.path 包含项目目录 (支持 require())
    // 将项目目录添加到 package.path, 这样 require('module') 会在项目目录中查找
    NSString *packagePath = [NSString stringWithFormat:@"%@/?.lua;%@/?/init.lua;%@",
                              projectDir, projectDir,
                              projectDir.stringByDeletingLastPathComponent];
    lua_getglobal(L, "package");
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "path");
        if (lua_isstring(L, -1)) {
            const char *oldPath = lua_tostring(L, -1);
            NSString *newPath = [NSString stringWithFormat:@"%@;%s", packagePath, oldPath];
            lua_pop(L, 1);
            lua_pushstring(L, newPath.UTF8String);
            lua_setfield(L, -2, "path");
        } else {
            lua_pop(L, 1);
            lua_pushstring(L, packagePath.UTF8String);
            lua_setfield(L, -2, "path");
        }
        lua_pop(L, 1);
    } else {
        lua_pop(L, 1);
    }

    // 设置 settings (项目级)
    [self _injectSettingsTable:L scriptPath:projectDir];

    // 执行脚本
    const char *utf8Code = code.UTF8String;
    int ret = luaL_loadbuffer(L, utf8Code, strlen(utf8Code),
                              entryFile.lastPathComponent.UTF8String);
    if (ret != LUA_OK) {
        size_t errLen = 0;
        const char *errMsg = lua_tolstring(L, -1, &errLen);
        lua_log([NSString stringWithFormat:@"[Lua] 语法错误: %@", luaToNSString(errMsg, errLen)]);
        lua_close(L);
        self.runningPath = nil;
        self.isRunning = NO;
        return;
    }

    lua_sethook(L, luaStopHook, LUA_MASKCOUNT, 5000);

    int pcallRet = lua_pcall(L, 0, 0, 0);
    if (pcallRet != LUA_OK) {
        size_t errLen = 0;
        const char *err = lua_tolstring(L, -1, &errLen);
        lua_log([NSString stringWithFormat:@"[Lua] 运行错误: %@", luaToNSString(err, errLen)]);
        lua_pop(L, 1);
    }
    lua_close(L);

    [[TSHIDEventTouch shared] releaseAllTouches];

    _stopRequested = NO;
    _pauseRequested = NO;
    self.isPaused = NO;
    self.runningPath = nil;
    self.isRunning = NO;
    [[TSAudioKeepAlive shared] stop];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.volumeMenuAlert) {
            [self.volumeMenuAlert dismissViewControllerAnimated:NO completion:nil];
            self.volumeMenuAlert = nil;
        }
    });
    lua_log(@"[Lua] 项目执行结束");
}

// 音量键被按下 (TSVolumeKeyMonitor 监听回调, 任意线程 → 转主线程):
//   空闲未运行 → 弹"运行脚本/取消"选择(运行当前选中脚本);
//   脚本运行中 → App 前台弹选择菜单; App 后台(游戏等)走 HUD 系统级弹窗
//              (SBSAccessibilityWindowHostingController 托管, 可覆盖游戏)。
// 音量键防抖时间戳(仅主线程访问): 单次按键可能产生多个事件(通知+轮询双通道),
// 快速连按在 0.8s 内忽略; 弹窗关闭时重置为 0, 避免吞掉
// 紧接着的下一次按键(如"取消后马上再按")。
static NSTimeInterval g_lastVolumeKeyAt = 0;
static const NSTimeInterval g_volumeKeyDebounce = 0.8;

- (void)_handleVolumeKey {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if ((now - g_lastVolumeKeyAt) < g_volumeKeyDebounce) return;
        g_lastVolumeKeyAt = now;

        // 诊断日志: 确认音量键监听已触发 + 当前脚本运行状态, 便于排查"按音量没反应"
        lua_log([NSString stringWithFormat:@"[音量键] 按下 (isRunning=%d, appState=%ld)",
                 self.isRunning, (long)[UIApplication sharedApplication].applicationState]);

        // 空闲(无脚本运行): 弹"运行脚本/取消"选择, 运行当前选中的脚本
        if (!self.isRunning) {
            [self _handleIdleVolumeKey];
            return;
        }

        // 脚本运行中: 弹 暂停/继续·停止·取消 菜单。
        // App 前台用 UIAlertController; App 后台(游戏等 app 在前台)走 HUD 系统级弹窗
        // (SBSAccessibilityWindowHostingController 托管, 可覆盖游戏)。
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            [self _presentInAppVolumeMenu];
        } else {
            [self _presentBackgroundVolumeMenu];
        }
    });
}

// ── 常驻音量键监听 (TAS 服务开关) ──────────────────────────────
// App 启动且 TAS 服务开启时调用。音量键监听不随脚本启停:
//   脚本运行中 → _handleVolumeKey → 控制菜单;
//   空闲未运行 → _handleIdleVolumeKey → 询问运行选中脚本。
- (void)startGlobalVolumeMonitoring {
    TSCrashSetVolumeMonitorRunning(1);
    TSVolumeKeyMonitor *vm = [TSVolumeKeyMonitor shared];
    __weak typeof(self) weakSelf = self;
    vm.onVolumeKey = ^{
        [weakSelf _handleVolumeKey];
    };
    // TAS 服务开启期间常驻静音保活: 音频会话始终激活, outputVolume 读值
    // 实时可用, 空闲时按音量键也能被检测到; 引用计数与脚本运行互不干扰。
    [[TSAudioKeepAlive shared] start];
    [vm start];
    lua_log(@"[音量键] 常驻监听已启动 (TAS 服务开)");
}

- (void)stopGlobalVolumeMonitoring {
    [TSVolumeKeyMonitor shared].onVolumeKey = nil;
    [[TSVolumeKeyMonitor shared] stop];
    [[TSAudioKeepAlive shared] stop];
    TSCrashSetVolumeMonitorRunning(0);
    lua_log(@"[音量键] 常驻监听已停止 (TAS 服务关)");
}

// 空闲(无脚本运行)时按音量键: 询问是否运行"当前选中的脚本"。
// 用 HUD 系统级弹窗, 在任意 app(游戏等)前台都能显示;
// 点"运行" → 运行脚本列表里选中的 lua 脚本; 点"取消" → 什么都不做。
- (void)_handleIdleVolumeKey {
    static BOOL s_idleMenuShowing = NO;
    if (s_idleMenuShowing) return; // 弹窗显示期间忽略再次按键
    s_idleMenuShowing = YES;

    NSString *name = [TSScriptListViewController selectedScriptName];
    if (!name.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            s_idleMenuShowing = NO;
            g_lastVolumeKeyAt = 0;
            [[TSHUDHost shared] showToast:@"未选中脚本，请先在配置页选中" duration:1.2 hidden:NO];
        });
        lua_log(@"[音量键] 空闲: 未选中脚本, 忽略");
        return;
    }
    NSString *path = [TSPaths pathForLua:name];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            s_idleMenuShowing = NO;
            g_lastVolumeKeyAt = 0;
            [[TSHUDHost shared] showToast:@"所选脚本/项目已不存在" duration:1.2 hidden:NO];
        });
        lua_log(@"[音量键] 空闲: 选中项不存在, 忽略");
        return;
    }

    NSString *typeLabel = isDir ? @"项目" : @"脚本";
    lua_log([NSString stringWithFormat:@"[音量键] 空闲: 询问是否运行「%@」(%@)", name, typeLabel]);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // HUD 弹窗为阻塞式(等待用户点击), 放后台线程调用避免卡主线程
        NSString *clicked = [[TSHUDService sharedInstance] showAlertWithTitle:@"QQ音乐"
                                                                     message:[NSString stringWithFormat:@"运行%@「%@」？", typeLabel, name]
                                                                     buttons:@[@"运行", @"取消"]
                                                                     timeout:0];
        dispatch_async(dispatch_get_main_queue(), ^{
            s_idleMenuShowing = NO;
            g_lastVolumeKeyAt = 0; // 弹窗关闭后立即允许再次按键触发
            if ([clicked isEqualToString:@"运行"]) {
                if (isDir) {
                    // 文件夹 → 作为项目运行
                    [[TSLuaBridge shared] runProject:path];
                } else {
                    // 文件 → 读取内容后运行
                    NSString *content = [[TSToolExecutor shared] readTextFile:path];
                    if ([TSScriptCipher isEncryptedContent:content]) {
                        content = [TSScriptCipher decryptScript:content];
                    }
                    if (content.length) {
                        [[NSNotificationCenter defaultCenter] postNotificationName:@"TSRunScript"
                                                                            object:nil
                                                                          userInfo:@{@"path": path, @"content": content}];
                    } else {
                        lua_log([NSString stringWithFormat:@"[音量键] 读取脚本失败: %@", path]);
                    }
                }
            }
            // "取消" 或 HUD 不可用(返回 nil): 什么都不做
        });
    });
}

// 注入失败 + App 后台时的音量键控制菜单:
// 通过进程内 HUD 宿主 (TSHUDHost, SBSAccessibilityWindowHostingController 托管)
// 弹出 暂停/继续 · 停止 · 取消 菜单, 覆盖游戏等前台 app, 与 dylib 菜单等价。
// 托管未就绪时 showAlertWithTitle: 立即返回 nil, 回退静默切换, 保证"按了有反应"。
// 脚本启动时会后台预热 HUD, 因此正常情况下按音量键时宿主已就绪, 弹窗秒开。
- (void)_presentBackgroundVolumeMenu {
    static BOOL s_hudMenuShowing = NO;
    if (s_hudMenuShowing) return; // 菜单显示期间忽略再次按键
    s_hudMenuShowing = YES;

    NSString *toggleTitle = _pauseRequested ? @"继续" : @"暂停";
    NSString *message = _pauseRequested ? @"脚本已暂停，请选择操作" : @"脚本运行中，请选择操作";
    lua_log(@"[音量键] 后台模式: 尝试 HUD 全局弹窗");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // HUD 弹窗为阻塞式(等待用户点击), 放后台线程调用避免卡主线程;
        // 进程内宿主未托管到系统级且 App 不在前台时, showAlertWithTitle: 立即
        // 返回 nil, 由下方统一回退静默切换, 保证"按了有反应"。
        // timeout=0 表示永久显示直到点击。
        NSString *clicked = [[TSHUDService sharedInstance] showAlertWithTitle:@"QQ音乐"
                                                                     message:message
                                                                     buttons:@[toggleTitle, @"停止", @"取消"]
                                                                     timeout:0];
        dispatch_async(dispatch_get_main_queue(), ^{
            s_hudMenuShowing = NO;
            if ([clicked isEqualToString:@"停止"]) {
                [self stop];
                lua_log(@"[音量键] 脚本已停止");
            } else if ([clicked isEqualToString:@"继续"]) {
                [self resume];
            } else if ([clicked isEqualToString:@"暂停"]) {
                [self pause];
            } else {
                // HUD 不可用/无响应(超时返回 nil): 回退静默切换
                lua_log(@"[音量键] HUD 弹窗不可用, 回退静默切换");
                [self _togglePauseBackground];
            }
        });
    });
}

// HUD 也不可用时的最后兜底: 静默切换 暂停/继续 (与旧版行为一致)
- (void)_togglePauseBackground {
    if (_pauseRequested) {
        [self resume];
        lua_log(@"[音量键] 后台模式: 脚本已继续 (停止请回 QQ音乐 弹菜单选择)");
    } else {
        [self pause];
    }
}

// App 进程内音量键控制菜单(注入失败时的兜底, 不依赖 dylib 注入):
// 弹原生 UIAlertController, 按钮为 暂停/继续 · 停止 · 取消,
// 用户点哪个按钮就执行对应动作 (等价于 dylib 菜单的返回值分发)。
// 注意: 弹窗只能在本 App 前台时显示; 注入成功时仍走 dylib 全局菜单。
- (void)_presentInAppVolumeMenu {
    // 防重复弹出: 菜单显示期间忽略再次按键
    static BOOL s_menuShowing = NO;
    if (s_menuShowing) return;
    s_menuShowing = YES;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"QQ音乐"
                                                                   message:_pauseRequested ? @"脚本已暂停，请选择操作" : @"脚本运行中，请选择操作"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    // 暂停 ↔ 继续 切换按钮, 标题随当前暂停状态变化
    NSString *toggleTitle = _pauseRequested ? @"继续" : @"暂停";
    [alert addAction:[UIAlertAction actionWithTitle:toggleTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        s_menuShowing = NO;
        if (_pauseRequested) {
            [self resume];
        } else {
            [self pause];
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"停止" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        s_menuShowing = NO;
        [self stop];
        lua_log(@"[音量键] 脚本已停止");
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        s_menuShowing = NO;
    }]];

    // 找到当前可 present 的顶层控制器(主窗口)
    NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
    UIWindow *keyWindow = nil;
    for (UIWindow *w in windows) {
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow) keyWindow = windows.firstObject;
    UIViewController *top = keyWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (top) {
        self.volumeMenuAlert = alert;
        [top presentViewController:alert animated:YES completion:nil];
    } else {
        s_menuShowing = NO; // 无可用窗口, 放弃弹窗, 允许下次按键重试
    }
}

@end
