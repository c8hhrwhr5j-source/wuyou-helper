//
//  TSScriptEngine.m
//  TrollAutoTouch — 扩展版
//
//  DSL 行式脚本引擎，支持以下命令族:
//   [触控]    tap / swipe / longtap / hold / release / move / stroke
//   [找色]    findcolor / findcs / findmcs / getcolor / keep / unkeep
//   [图像]    findimg  / screenshot
//   [录制]    record  / stoprecord / playrecord / stopreplay
//   [节点]    apptree / findnode / tapnode
//   [OCR]     ocr / findtext / taptext / ocrtext
//   [服务器]  server  / serverstop
//   [Shell]   exec
//   [文件]    filedir / fileread / filewrite / filedelete / filecopy /
//            fexists / fsize / fmkdir / fappend / fisdir
//   [网络]    ip / httpget / httppost
//   [系统]    disk / memory / cpu / uptime
//   [应用]    frontbid / applist / appinfo / openapp / closeapp /
//             uninstall / instapp / openurl
//   [输入]    inputtext
//   [按键]    key home/lock/volumeup/volumedown/home2x
//   [剪贴板]  clipboard / clipboardread / clipboardclear
//   [Plist]   plistread / plistwrite
//   [加密]    md5 / sha256 / base64encode / base64decode
//   [字符串]  trim / split / random
//   [流程]    sleep / loop / endloop / log / run
//   [设备]    deviceinfo / screensize
//

#import "TSScriptEngine.h"
#import "TSHIDEventTouch.h"
#import "TSScreenCapture.h"
#import "TSColorFinder.h"
#import "TSTemplateMatcher.h"
#import "TSTouchRecorder.h"
#import "TSAppNodeInfo.h"
#import "TSDeviceInfo.h"
#import "TSOCREngine.h"
#import "TSHTTPServer.h"
#import "TSToolExecutor.h"
#import "TSAppManager.h"
#import "TSKeyboardInjector.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonCrypto.h>

#pragma mark - 脚本解析器

@interface TSScriptEngine ()
@property (nonatomic, copy)   NSString  *scriptPath;
@property (nonatomic, assign) NSInteger currentLine;
@property (nonatomic, strong) NSArray   *lines;
@property (nonatomic, assign) BOOL      running;
@property (nonatomic, assign) BOOL      paused;
@property (nonatomic, strong) id<TSLogDelegate> logDelegate;

/// 循环状态栈 — 支持嵌套 loop/endloop
/// 每元素 = @{ @"line": @(lineIndex), @"count": @(remaining), @"label": @"..." }
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *loopStack;
@end

@implementation TSScriptEngine

+ (instancetype)shared {
    static TSScriptEngine *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[TSScriptEngine alloc] init]; });
    return instance;
}

- (void)runFile:(NSString *)path delegate:(id<TSLogDelegate>)delegate {
    self.scriptPath = path;
    self.logDelegate = delegate;
    self.currentLine = 0;
    self.paused = NO;
    self.loopStack = nil;

    NSError *err = nil;
    NSString *code = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
    if (!code) {
        [self logError:[NSString stringWithFormat:@"无法读取脚本: %@", err]];
        return;
    }
    [self executeScript:code];
}

- (void)runString:(NSString *)code delegate:(id<TSLogDelegate>)delegate {
    self.scriptPath = nil;
    self.logDelegate = delegate;
    self.currentLine = 0;
    self.paused = NO;
    self.loopStack = nil;
    [self executeScript:code];
}

- (void)pause   { self.paused = YES;  }
- (void)resume  { self.paused = NO;   }
- (void)stop    { self.running = NO; self.paused = NO; }

- (BOOL)isRunning { return self.running; }

// ---------------------------------------------------------------
#pragma mark 脚本执行主循环
// ---------------------------------------------------------------

- (void)executeScript:(NSString *)code {
    self.lines = [code componentsSeparatedByString:@"\n"];
    self.running = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (self.running && self.currentLine < (NSInteger)self.lines.count) {
            while (self.paused && self.running) { [NSThread sleepForTimeInterval:0.1]; }
            if (!self.running) break;

            NSString *line = [self.lines[self.currentLine] stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (line.length > 0 && ![line hasPrefix:@"#"] && ![line hasPrefix:@"//"]) {
                if (![self executeLine:line]) {
                    break; // 失败则终止
                }
            }
            self.currentLine++;
        }
        self.running = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.logDelegate log:[NSString stringWithFormat:@"脚本 %@ (line %ld)",
                                   self.scriptPath.lastPathComponent, (long)(self.currentLine + 1)]];
        });
    });
}

// ---------------------------------------------------------------
#pragma mark 命令行分发
// ---------------------------------------------------------------

- (BOOL)executeLine:(NSString *)line {
    NSArray *tokens = [self splitTokens:line];
    if (tokens.count == 0) return YES;
    NSString *cmd = [tokens[0] lowercaseString];

    // ---- 触控 ----
    if ([cmd isEqualToString:@"tap"] || [cmd isEqualToString:@"touch"]) {
        return [self cmdTap:tokens];
    } else if ([cmd isEqualToString:@"swipe"]) {
        return [self cmdSwipe:tokens];
    } else if ([cmd isEqualToString:@"longtap"] || [cmd isEqualToString:@"holdtap"]) {
        return [self cmdLongTap:tokens];
    } else if ([cmd isEqualToString:@"hold"] || [cmd isEqualToString:@"touchdown"]) {
        return [self cmdHold:tokens];
    } else if ([cmd isEqualToString:@"release"] || [cmd isEqualToString:@"touchup"]) {
        return [self cmdRelease:tokens];
    } else if ([cmd isEqualToString:@"move"] || [cmd isEqualToString:@"touchmove"]) {
        return [self cmdMove:tokens];
    } else if ([cmd isEqualToString:@"stroke"] || [cmd isEqualToString:@"touchstroke"]) {
        return [self cmdStroke:tokens];

    // ---- 找色 ----
    } else if ([cmd isEqualToString:@"findcolor"]) {
        return [self cmdFindColor:tokens];
    } else if ([cmd isEqualToString:@"findcs"]) {
        return [self cmdFindColor:tokens];
    } else if ([cmd isEqualToString:@"findmcs"]) {
        return [self cmdFindMultiColor:tokens];
    } else if ([cmd isEqualToString:@"getcolor"]) {
        return [self cmdGetColor:tokens];
    } else if ([cmd isEqualToString:@"keep"] || [cmd isEqualToString:@"keepscreen"]) {
        return [self cmdKeepScreen:tokens];
    } else if ([cmd isEqualToString:@"unkeep"] || [cmd isEqualToString:@"unkeepscreen"]) {
        return [self cmdUnkeepScreen:tokens];

    // ---- 图像 ----
    } else if ([cmd isEqualToString:@"findimg"] || [cmd isEqualToString:@"findimage"]) {
        return [self cmdFindImage:tokens];
    } else if ([cmd isEqualToString:@"screenshot"] || [cmd isEqualToString:@"snapshot"]) {
        return [self cmdScreenshot:tokens];

    // ---- 录制回放 ----
    } else if ([cmd isEqualToString:@"record"] || [cmd isEqualToString:@"startrecord"]) {
        return [self cmdRecord:tokens];
    } else if ([cmd isEqualToString:@"stoprecord"]) {
        return [self cmdStopRecord:tokens];
    } else if ([cmd isEqualToString:@"playrecord"] || [cmd isEqualToString:@"replay"]) {
        return [self cmdPlayRecord:tokens];
    } else if ([cmd isEqualToString:@"stopreplay"]) {
        return [self cmdStopReplay:tokens];

    // ---- UI 节点 ----
    } else if ([cmd isEqualToString:@"apptree"]) {
        return [self cmdAppTree:tokens];
    } else if ([cmd isEqualToString:@"findnode"]) {
        return [self cmdFindNode:tokens];
    } else if ([cmd isEqualToString:@"tapnode"]) {
        return [self cmdTapNode:tokens];

    // ---- 设备 ----
    } else if ([cmd isEqualToString:@"deviceinfo"]) {
        return [self cmdDeviceInfo:tokens];
    } else if ([cmd isEqualToString:@"screensize"]) {
        return [self cmdScreenSize:tokens];

    // ---- OCR (Vision) ----
    } else if ([cmd isEqualToString:@"ocr"]) {
        return [self cmdOCR:tokens];
    } else if ([cmd isEqualToString:@"findtext"]) {
        return [self cmdFindText:tokens];
    } else if ([cmd isEqualToString:@"taptext"]) {
        return [self cmdTapText:tokens];
    } else if ([cmd isEqualToString:@"ocrtext"]) {
        return [self cmdOCRText:tokens];

    // ---- Web 服务器 ----
    } else if ([cmd isEqualToString:@"server"] || [cmd isEqualToString:@"webserver"]) {
        return [self cmdServer:tokens];
    } else if ([cmd isEqualToString:@"serverstop"]) {
        return [self cmdServerStop:tokens];

    // ---- Shell 执行 ----
    } else if ([cmd isEqualToString:@"exec"] || [cmd isEqualToString:@"shell"]) {
        return [self cmdExec:tokens];

    // ---- 文件操作 ----
    } else if ([cmd isEqualToString:@"filedir"] || [cmd isEqualToString:@"filelist"]) {
        return [self cmdFileList:tokens];
    } else if ([cmd isEqualToString:@"fileread"] || [cmd isEqualToString:@"fget"]) {
        return [self cmdFileRead:tokens];
    } else if ([cmd isEqualToString:@"filewrite"] || [cmd isEqualToString:@"fput"]) {
        return [self cmdFileWrite:tokens];
    } else if ([cmd isEqualToString:@"filedelete"] || [cmd isEqualToString:@"frm"]) {
        return [self cmdFileDelete:tokens];
    } else if ([cmd isEqualToString:@"filecopy"] || [cmd isEqualToString:@"fcp"]) {
        return [self cmdFileCopy:tokens];
    } else if ([cmd isEqualToString:@"fexists"]) {
        return [self cmdFileExists:tokens];
    } else if ([cmd isEqualToString:@"fsize"]) {
        return [self cmdFileSize:tokens];
    } else if ([cmd isEqualToString:@"fmkdir"]) {
        return [self cmdFileMkdir:tokens];
    } else if ([cmd isEqualToString:@"fappend"]) {
        return [self cmdFileAppend:tokens];
    } else if ([cmd isEqualToString:@"fisdir"]) {
        return [self cmdFileIsDir:tokens];

    // ---- 剪贴板 ----
    } else if ([cmd isEqualToString:@"clipboard"] || [cmd isEqualToString:@"pbwrite"]) {
        return [self cmdClipboardWrite:tokens];
    } else if ([cmd isEqualToString:@"clipboardread"] || [cmd isEqualToString:@"pbread"]) {
        return [self cmdClipboardRead:tokens];
    } else if ([cmd isEqualToString:@"clipboardclear"] || [cmd isEqualToString:@"pbclear"]) {
        return [self cmdClipboardClear:tokens];

    // ---- Plist ----
    } else if ([cmd isEqualToString:@"plistread"]) {
        return [self cmdPlistRead:tokens];
    } else if ([cmd isEqualToString:@"plistwrite"]) {
        return [self cmdPlistWrite:tokens];

    // ---- 网络 ----
    } else if ([cmd isEqualToString:@"ip"] || [cmd isEqualToString:@"myip"]) {
        return [self cmdIP:tokens];
    } else if ([cmd isEqualToString:@"httpget"]) {
        return [self cmdHttpGet:tokens];
    } else if ([cmd isEqualToString:@"httppost"]) {
        return [self cmdHttpPost:tokens];

    // ---- 信息 ----
    } else if ([cmd isEqualToString:@"disk"] || [cmd isEqualToString:@"diskinfo"]) {
        return [self cmdDiskInfo:tokens];
    } else if ([cmd isEqualToString:@"memory"] || [cmd isEqualToString:@"meminfo"]) {
        return [self cmdMemoryInfo:tokens];
    } else if ([cmd isEqualToString:@"cpu"] || [cmd isEqualToString:@"cpuinfo"]) {
        return [self cmdCPUInfo:tokens];
    } else if ([cmd isEqualToString:@"uptime"]) {
        return [self cmdUptime:tokens];

    // ---- 应用管理 ----
    } else if ([cmd isEqualToString:@"frontbid"] || [cmd isEqualToString:@"frontapp"]) {
        return [self cmdFrontBid:tokens];
    } else if ([cmd isEqualToString:@"applist"] || [cmd isEqualToString:@"apps"]) {
        return [self cmdAppList:tokens];
    } else if ([cmd isEqualToString:@"appinfo"]) {
        return [self cmdAppInfo:tokens];
    } else if ([cmd isEqualToString:@"openapp"] || [cmd isEqualToString:@"launchapp"]) {
        return [self cmdOpenApp:tokens];
    } else if ([cmd isEqualToString:@"closeapp"] || [cmd isEqualToString:@"killapp"]) {
        return [self cmdCloseApp:tokens];
    } else if ([cmd isEqualToString:@"uninstall"] || [cmd isEqualToString:@"rmapp"]) {
        return [self cmdUninstallApp:tokens];
    } else if ([cmd isEqualToString:@"instapp"] || [cmd isEqualToString:@"installipa"]) {
        return [self cmdInstallApp:tokens];
    } else if ([cmd isEqualToString:@"openurl"]) {
        return [self cmdOpenURL:tokens];

    // ---- 按键 ----
    } else if ([cmd isEqualToString:@"key"]) {
        return [self cmdKey:tokens];

    // ---- 加密与字符串 ----
    } else if ([cmd isEqualToString:@"md5"]) {
        return [self cmdMD5:tokens];
    } else if ([cmd isEqualToString:@"sha256"]) {
        return [self cmdSHA256:tokens];
    } else if ([cmd isEqualToString:@"base64encode"] || [cmd isEqualToString:@"b64enc"]) {
        return [self cmdBase64Encode:tokens];
    } else if ([cmd isEqualToString:@"base64decode"] || [cmd isEqualToString:@"b64dec"]) {
        return [self cmdBase64Decode:tokens];
    } else if ([cmd isEqualToString:@"trim"]) {
        return [self cmdTrim:tokens];
    } else if ([cmd isEqualToString:@"split"]) {
        return [self cmdSplit:tokens];
    } else if ([cmd isEqualToString:@"random"]) {
        return [self cmdRandom:tokens];

    // ---- 输入 ----
    } else if ([cmd isEqualToString:@"inputtext"] || [cmd isEqualToString:@"sendtext"]) {
        return [self cmdInputText:tokens];

    // ---- 流程控制 ----
    } else if ([cmd isEqualToString:@"sleep"]) {
        return [self cmdSleep:tokens];
    } else if ([cmd isEqualToString:@"loop"]) {
        return [self cmdLoop:tokens];
    } else if ([cmd isEqualToString:@"endloop"]) {
        return [self cmdEndLoop:tokens];
    } else if ([cmd isEqualToString:@"log"] || [cmd isEqualToString:@"print"]) {
        return [self cmdLog:tokens];
    } else if ([cmd isEqualToString:@"run"] || [cmd isEqualToString:@"call"]) {
        return [self cmdRun:tokens];

    // ---- 标记 ----
    } else if ([cmd isEqualToString:@"label"] || [cmd isEqualToString:@"goto"]) {
        // 扩展: 可自行实现 goto/label
        [self log:[NSString stringWithFormat:@"[跳过] %@ (未实现)", cmd]];
        return YES;
    }

    [self logError:[NSString stringWithFormat:@"未知命令: %@", cmd]];
    return NO;
}

// ---------------------------------------------------------------
#pragma mark 触控命令
// ---------------------------------------------------------------

- (BOOL)cmdTap:(NSArray *)tokens {
    if (tokens.count < 3) { [self logError:@"tap x y [duration_ms]"]; return NO; }
    CGFloat x = [self floatVal:tokens[1]], y = [self floatVal:tokens[2]];
    NSTimeInterval d = tokens.count > 3 ? [self floatVal:tokens[3]] / 1000.0 : 0.05;
    [[TSHIDEventTouch shared] tapAtPoint:CGPointMake(x, y) duration:d];
    [self logWait];
    return YES;
}

- (BOOL)cmdSwipe:(NSArray *)tokens {
    if (tokens.count < 5) { [self logError:@"swipe x1 y1 x2 y2 [duration_ms]"]; return NO; }
    CGPoint a = CGPointMake([self floatVal:tokens[1]], [self floatVal:tokens[2]]);
    CGPoint b = CGPointMake([self floatVal:tokens[3]], [self floatVal:tokens[4]]);
    NSTimeInterval d = tokens.count > 5 ? [self floatVal:tokens[5]] / 1000.0 : 0.3;
    NSInteger steps = MAX(2, (NSInteger)(d * 60));
    [[TSHIDEventTouch shared] swipeFromPoint:a toPoint:b duration:d steps:steps];
    [self logWait];
    return YES;
}

- (BOOL)cmdLongTap:(NSArray *)tokens {
    if (tokens.count < 3) { [self logError:@"longtap x y [duration_ms]"]; return NO; }
    CGFloat x = [self floatVal:tokens[1]], y = [self floatVal:tokens[2]];
    NSTimeInterval d = tokens.count > 3 ? [self floatVal:tokens[3]] / 1000.0 : 1.0;
    [[TSHIDEventTouch shared] tapAtPoint:CGPointMake(x, y) duration:d];
    [self logWait];
    return YES;
}

- (BOOL)cmdHold:(NSArray *)tokens {
    if (tokens.count < 3) { [self logError:@"hold x y [index]"]; return NO; }
    CGFloat x = [self floatVal:tokens[1]], y = [self floatVal:tokens[2]];
    int idx = tokens.count > 3 ? (int)[tokens[3] integerValue] : 0;
    [[TSHIDEventTouch shared] touchDownAtPoint:CGPointMake(x, y) index:idx];
    return YES;
}

- (BOOL)cmdRelease:(NSArray *)tokens {
    if (tokens.count < 3) { [self logError:@"release x y [index]"]; return NO; }
    CGFloat x = [self floatVal:tokens[1]], y = [self floatVal:tokens[2]];
    int idx = tokens.count > 3 ? (int)[tokens[3] integerValue] : 0;
    [[TSHIDEventTouch shared] touchUpAtPoint:CGPointMake(x, y) index:idx];
    return YES;
}

- (BOOL)cmdMove:(NSArray *)tokens {
    if (tokens.count < 3) { [self logError:@"move x y [index]"]; return NO; }
    CGFloat x = [self floatVal:tokens[1]], y = [self floatVal:tokens[2]];
    int idx = tokens.count > 3 ? (int)[tokens[3] integerValue] : 0;
    [[TSHIDEventTouch shared] touchMoveAtPoint:CGPointMake(x, y) index:idx];
    return YES;
}

- (BOOL)cmdStroke:(NSArray *)tokens {
    // stroke x1 y1 x2 y2 x3 y3 ... [step_delay_ms]
    if (tokens.count < 5) { [self logError:@"stroke x1 y1 x2 y2 ..."]; return NO; }
    
    // 第一个点 down
    CGFloat x0 = [self floatVal:tokens[1]], y0 = [self floatVal:tokens[2]];
    [[TSHIDEventTouch shared] touchDownAtPoint:CGPointMake(x0, y0) index:0];
    
    NSTimeInterval delay = tokens.count > 5 ? [self floatVal:tokens[tokens.count-1]] / 1000.0 : 0.01;
    NSInteger ptCount = tokens.count - 1;
    if (ptCount % 2 != 0) ptCount--; // 成对处理
    
    for (NSInteger i = 2; i < ptCount; i += 2) {
        CGFloat xi = [self floatVal:tokens[i+1]], yi = [self floatVal:tokens[i+2]];
        [NSThread sleepForTimeInterval:delay];
        [[TSHIDEventTouch shared] touchMoveAtPoint:CGPointMake(xi, yi) index:0];
    }
    [NSThread sleepForTimeInterval:0.02];
    // 最后一个点 up
    CGFloat xl = [self floatVal:tokens[ptCount-1]], yl = [self floatVal:tokens[ptCount]];
    [[TSHIDEventTouch shared] touchUpAtPoint:CGPointMake(xl, yl) index:0];
    return YES;
}

// ---------------------------------------------------------------
#pragma mark 找色命令
// ---------------------------------------------------------------

- (BOOL)cmdFindColor:(NSArray *)tokens {
    // findcolor 0xRRGGBB [x y w h] [sim]
    if (tokens.count < 2) { [self logError:@"findcolor color [x y w h] [sim]"]; return NO; }
    
    int color = [self parseColor:tokens[1]];
    CGRect rect = CGRectZero;
    CGFloat sim = 0.9;
    
    if (tokens.count >= 6) {
        rect = CGRectMake([self floatVal:tokens[2]], [self floatVal:tokens[3]],
                          [self floatVal:tokens[4]], [self floatVal:tokens[5]]);
        if (tokens.count >= 7) sim = [self floatVal:tokens[6]];
    } else if (tokens.count >= 3) {
        sim = [self floatVal:tokens[2]];
    }
    
    uint8_t *px = NULL; int w = 0, h = 0;
    if (![[TSScreenCapture shared] getCachedPixels:&px width:&w height:&h]) {
        [self logError:@"截屏失败"]; return NO;
    }
    CGSize ss = [UIScreen mainScreen].bounds.size;
    TSColorResult *res = [TSColorFinder findColor:color rect:rect sim:sim
                                          pixels:px width:w height:h screenSize:ss];
    free(px);
    
    if (res) {
        [self log:[NSString stringWithFormat:@"找到颜色 0x%06X 于 (%.1f, %.1f) diff=%d",
                    color, res.point.x, res.point.y, res.diff]];
    } else {
        [self logError:[NSString stringWithFormat:@"未找到颜色 0x%06X", color]];
        return NO;
    }
    return YES;
}

- (BOOL)cmdFindMultiColor:(NSArray *)tokens {
    // findmcs mainColor sim offx1 offy1 offColor1 [offx2 offy2 offColor2 ...] [x y w h]
    if (tokens.count < 5) {
        [self logError:@"findmcs mainColor sim dx1 dy1 color1 [dx2 dy2 color2 ...]"]; return NO;
    }
    
    int mainColor = [self parseColor:tokens[1]];
    CGFloat sim = [self floatVal:tokens[2]];
    
    // 解析偏移点 (dx, dy, color) 三元组
    NSMutableArray *offsets = [NSMutableArray array];
    NSInteger i = 3;
    while (i + 2 < (NSInteger)tokens.count) {
        NSString *s = tokens[i];
        // 如果是纯数字(偏移), 继续解析三元组
        CGFloat dx = [self floatVal:tokens[i]];
        CGFloat dy = [self floatVal:tokens[i+1]];
        int oc = [self parseColor:tokens[i+2]];
        [offsets addObject:@{@"x": @(dx), @"y": @(dy), @"color": @(oc)}];
        i += 3;
        // 若下一个 token 看起来不是数字偏移(可能是区域)，停止
        if (i >= (NSInteger)tokens.count) break;
        // 简单判断: 如果下一个是区域参数格式
        if (tokens.count - i == 4) break; // 剩余4个=区域
    }
    
    CGRect rect = CGRectZero;
    if (tokens.count - i == 4) {
        rect = CGRectMake([self floatVal:tokens[i]], [self floatVal:tokens[i+1]],
                          [self floatVal:tokens[i+2]], [self floatVal:tokens[i+3]]);
    }
    
    uint8_t *px = NULL; int w = 0, h = 0;
    if (![[TSScreenCapture shared] getCachedPixels:&px width:&w height:&h]) {
        [self logError:@"截屏失败"]; return NO;
    }
    CGSize ss = [UIScreen mainScreen].bounds.size;
    TSColorResult *res = [TSColorFinder findMultiColor:mainColor rect:rect mainColorSim:sim
                                             mainTolR:0 mainTolG:0 mainTolB:0
                                              offsets:offsets offsetSim:sim
                                             direction:0
                                               pixels:px width:w height:h screenSize:ss];
    free(px);
    
    if (res) {
        [self log:[NSString stringWithFormat:@"多点找色命中 (%.1f, %.1f)", res.point.x, res.point.y]];
    } else {
        [self logError:@"多点找色未匹配"];
        return NO;
    }
    return YES;
}

- (BOOL)cmdGetColor:(NSArray *)tokens {
    if (tokens.count < 3) { [self logError:@"getcolor x y"]; return NO; }
    CGFloat x = [self floatVal:tokens[1]], y = [self floatVal:tokens[2]];
    
    uint8_t *px = NULL; int w = 0, h = 0;
    if (![[TSScreenCapture shared] captureScreenToRGBA:&px width:&w height:&h] || !px) {
        [self logError:@"截屏失败"]; return NO;
    }
    CGSize ss = [UIScreen mainScreen].bounds.size;
    int c = [TSColorFinder getColorAtPoint:CGPointMake(x, y) pixels:px width:w height:h screenSize:ss];
    free(px);
    [self log:[NSString stringWithFormat:@"颜色(%.1f, %.1f) = 0x%06X", x, y, c]];
    return YES;
}

- (BOOL)cmdKeepScreen:(NSArray *)tokens {
    [[TSScreenCapture shared] keepPixels];
    [self log:@"截屏已缓存"];
    return YES;
}

- (BOOL)cmdUnkeepScreen:(NSArray *)tokens {
    [[TSScreenCapture shared] unkeepPixels];
    [self log:@"截屏缓存已释放"];
    return YES;
}

// ---------------------------------------------------------------
#pragma mark 图像命令
// ---------------------------------------------------------------

- (BOOL)cmdFindImage:(NSArray *)tokens {
    // findimg path [accuracy 0~1] [x y w h]
    if (tokens.count < 2) { [self logError:@"findimg image_path [accuracy] [x y w h]"]; return NO; }
    
    NSString *imgPath = tokens[1];
    if (![imgPath hasPrefix:@"/"]) {
        if (self.scriptPath) {
            imgPath = [[self.scriptPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:imgPath];
        } else {
            imgPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:imgPath];
        }
    }
    
    CGFloat accuracy = tokens.count > 2 ? [self floatVal:tokens[2]] : 0.8;
    CGRect rect = CGRectZero;
    if (tokens.count >= 7) {
        rect = CGRectMake([self floatVal:tokens[3]], [self floatVal:tokens[4]],
                          [self floatVal:tokens[5]], [self floatVal:tokens[6]]);
    }
    
    UIImage *tpl = [UIImage imageWithContentsOfFile:imgPath];
    if (!tpl) { [self logError:[NSString stringWithFormat:@"找不到图像: %@", imgPath]]; return NO; }
    
    TSTemplateMatchResult *res = [[TSTemplateMatcher shared] findImageOnScreen:tpl
                                                                      accuracy:accuracy rect:rect];
    if (res) {
        [self log:[NSString stringWithFormat:@"图像匹配 (%.1f, %.1f) conf=%.3f",
                    res.center.x, res.center.y, res.confidence]];
    } else {
        [self logError:[NSString stringWithFormat:@"未找到匹配图像 (conf >= %.2f)", accuracy]];
        return NO;
    }
    return YES;
}

- (BOOL)cmdScreenshot:(NSArray *)tokens {
    NSString *path = nil;
    if (tokens.count > 1) {
        path = tokens[1];
        if (![path hasPrefix:@"/"]) {
            path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:path];
        }
    } else {
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"yyyyMMdd_HHmmss";
        path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
            NSUserDomainMask, YES).firstObject
            stringByAppendingFormat:@"/screenshot_%@.png", [f stringFromDate:[NSDate date]]];
    }
    
    UIImage *img = [[TSScreenCapture shared] captureImage];
    if (!img) { [self logError:@"截屏失败"]; return NO; }
    [UIImagePNGRepresentation(img) writeToFile:path atomically:YES];
    [self log:[NSString stringWithFormat:@"截屏已保存: %@", path]];
    return YES;
}

// ---------------------------------------------------------------
#pragma mark 录制回放命令
// ---------------------------------------------------------------

- (BOOL)cmdRecord:(NSArray *)tokens {
    NSTimeInterval interval = tokens.count > 1 ? [self floatVal:tokens[1]] : 0.016;
    [[TSTouchRecorder shared] startRecordingWithInterval:interval];
    [self log:[NSString stringWithFormat:@"开始录制 (间隔 %.3fs)...脚本将暂停在此，等待 stoprecord", interval]];
    
    // 等待录制完成 (外部通过悬浮窗停止)
    while (self.running && [TSTouchRecorder shared].isRecording) {
        [NSThread sleepForTimeInterval:0.2];
    }
    return YES;
}

- (BOOL)cmdStopRecord:(NSArray *)tokens {
    [[TSTouchRecorder shared] stopRecording];
    [self log:@"录制已停止"];
    return YES;
}

- (BOOL)cmdPlayRecord:(NSArray *)tokens {
    CGFloat speed = tokens.count > 1 ? [self floatVal:tokens[1]] : 1.0;
    [[TSTouchRecorder shared] playRecordingWithSpeed:speed];
    [self log:[NSString stringWithFormat:@"开始回放 (速度 %.1fx)...", speed]];
    
    // 等待回放完成
    while (self.running && [TSTouchRecorder shared].isPlaying) {
        [NSThread sleepForTimeInterval:0.1];
    }
    return YES;
}

- (BOOL)cmdStopReplay:(NSArray *)tokens {
    [[TSTouchRecorder shared] stopPlayback];
    [self log:@"回放已停止"];
    return YES;
}

// ---------------------------------------------------------------
#pragma mark UI 节点命令
// ---------------------------------------------------------------

- (BOOL)cmdAppTree:(NSArray *)tokens {
    NSString *json = [[TSAppNodeInfo shared] fullTreeJSON];
    [self log:[NSString stringWithFormat:@"UI树:\n%@", json]];
    return YES;
}

- (BOOL)cmdFindNode:(NSArray *)tokens {
    // findnode class [text]
    if (tokens.count < 2) { [self logError:@"findnode className [text]"]; return NO; }
    
    NSString *cn = tokens[1];
    NSString *text = tokens.count > 2 ? tokens[2] : nil;
    
    NSArray<TSAppNode *> *nodes;
    if (text.length > 0) {
        nodes = [[TSAppNodeInfo shared] findByText:text className:cn];
    } else {
        nodes = [[TSAppNodeInfo shared] findByClassName:cn];
    }
    
    if (nodes.count == 0) {
        [self logError:[NSString stringWithFormat:@"未找到节点 class=%@ text=%@", cn, text ?: @"(any)"]];
        return NO;
    }
    
    [self log:[NSString stringWithFormat:@"找到 %lu 个节点:", (unsigned long)nodes.count]];
    for (TSAppNode *n in nodes) {
        [self log:[NSString stringWithFormat:@"  %@ (%.0f,%.0f %.0fx%.0f) text='%@' addr=%p",
                    n.className, n.frame.origin.x, n.frame.origin.y,
                    n.frame.size.width, n.frame.size.height,
                    n.text, (void *)n.address]];
    }
    return YES;
}

- (BOOL)cmdTapNode:(NSArray *)tokens {
    // tapnode class [text]
    if (tokens.count < 2) { [self logError:@"tapnode className [text]"]; return NO; }
    
    NSString *cn = tokens[1];
    NSString *text = tokens.count > 2 ? tokens[2] : nil;
    
    NSArray<TSAppNode *> *nodes;
    if (text.length > 0) {
        nodes = [[TSAppNodeInfo shared] findByText:text className:cn];
    } else {
        nodes = [[TSAppNodeInfo shared] findByClassName:cn];
    }
    
    if (nodes.count == 0) {
        [self logError:[NSString stringWithFormat:@"未找到可点击节点 class=%@", cn]];
        return NO;
    }
    
    TSAppNode *n = nodes.firstObject;
    [[TSAppNodeInfo shared] tapNode:n];
    [self log:[NSString stringWithFormat:@"点击节点 %@ (%.0f,%.0f)", n.className, n.centerPoint.x, n.centerPoint.y]];
    [self logWait];
    return YES;
}

// ---------------------------------------------------------------
#pragma mark 设备命令
// ---------------------------------------------------------------

- (BOOL)cmdDeviceInfo:(NSArray *)tokens {
    NSDictionary *info = [[TSDeviceInfo shared] fullInfo];
    [self log:[NSString stringWithFormat:@"设备信息:\n%@", info]];
    return YES;
}

- (BOOL)cmdScreenSize:(NSArray *)tokens {
    CGSize ss = [TSDeviceInfo shared].screenSize;
    CGFloat scale = [TSDeviceInfo shared].screenScale;
    [self log:[NSString stringWithFormat:@"屏幕: %.0fx%.0f (scale=%.0f, native=%.0fx%.0f)",
                ss.width, ss.height, scale, ss.width*scale, ss.height*scale]];
    return YES;
}

// ---------------------------------------------------------------
#pragma mark 输入命令
// ---------------------------------------------------------------

- (BOOL)cmdInputText:(NSArray *)tokens {
    if (tokens.count < 2) { [self logError:@"inputtext \"text\""]; return NO; }
    NSString *text = tokens[1];
    if ([text hasPrefix:@"\""] && [text hasSuffix:@"\""]) {
        text = [text substringWithRange:NSMakeRange(1, text.length - 2)];
    }

    BOOL ok = [[TSKeyboardInjector shared] inputText:text];
    [self log:ok ? [NSString stringWithFormat:@"已输入: %@", text]
                : [NSString stringWithFormat:@"已复制到剪贴板: %@ (键盘注入不可用)", text]];
    return YES;
}

// ---------------------------------------------------------------
#pragma mark 流程控制命令
// ---------------------------------------------------------------

- (BOOL)cmdSleep:(NSArray *)tokens {
    if (tokens.count < 2) { [self logError:@"sleep ms"]; return NO; }
    NSInteger ms = [tokens[1] integerValue];
    [NSThread sleepForTimeInterval:(NSTimeInterval)ms / 1000.0];
    return YES;
}

- (BOOL)cmdLoop:(NSArray *)tokens {
    // 语法: loop N  — 开始循环 N 次
    if (tokens.count < 2) { [self logError:@"loop count — 需要循环次数"]; return NO; }
    NSInteger count = [tokens[1] integerValue];
    if (count <= 0) { [self logError:@"loop count 必须 > 0"]; return NO; }

    if (!_loopStack) _loopStack = [NSMutableArray array];
    NSDictionary *frame = @{
        @"line":  @(self.currentLine),   // loop 所在行号
        @"count": @(count),              // 剩余循环次数
    };
    [_loopStack addObject:frame];
    return YES;
}

- (BOOL)cmdEndLoop:(NSArray *)tokens {
    if (!_loopStack || _loopStack.count == 0) {
        [self logError:@"endloop 没有匹配的 loop"];
        return NO;
    }

    NSMutableDictionary *frame = [_loopStack.lastObject mutableCopy];
    [_loopStack removeLastObject];

    NSInteger remaining = [frame[@"count"] integerValue];
    remaining--;

    if (remaining > 0) {
        // 还有剩余循环 → 跳回 loop 行
        frame[@"count"] = @(remaining);
        [_loopStack addObject:frame];
        self.currentLine = [frame[@"line"] integerValue];
    }
    // else: remaining == 0 → 循环结束，继续下一行

    return YES;
}

- (BOOL)cmdLog:(NSArray *)tokens {
    NSString *msg = [[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)] componentsJoinedByString:@" "];
    [self log:msg];
    return YES;
}

- (BOOL)cmdRun:(NSArray *)tokens {
    // run "sub_script.txt"
    if (tokens.count < 2) { [self logError:@"run script_path"]; return NO; }
    NSString *sub = tokens[1];
    if (![sub hasPrefix:@"/"]) {
        sub = [[self.scriptPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:sub];
    }
    [self runFile:sub delegate:self.logDelegate];
    return YES;
}

// ---------------------------------------------------------------
#pragma mark OCR 命令 (Vision Framework)
// ---------------------------------------------------------------

- (BOOL)cmdOCR:(NSArray *)tokens {
    // ocr [x y w h]
    UIImage *img = [[TSScreenCapture shared] captureImage];
    if (!img) { [self logError:@"截屏失败"]; return NO; }

    NSArray<TSOCRResult *> *results;
    if (tokens.count >= 5) {
        CGRect r = CGRectMake([self floatVal:tokens[1]], [self floatVal:tokens[2]],
                              [self floatVal:tokens[3]], [self floatVal:tokens[4]]);
        results = [[TSOCREngine shared] recognize:img inRegion:r];
    } else {
        results = [[TSOCREngine shared] recognize:img];
    }

    [self log:[NSString stringWithFormat:@"OCR 共识别 %lu 条文字:", (unsigned long)results.count]];
    for (TSOCRResult *r in results) {
        [self log:[NSString stringWithFormat:@"  \"%@\" (%.0f,%.0f) conf=%.2f",
                    r.text, r.center.x, r.center.y, r.confidence]];
    }
    return YES;
}

- (BOOL)cmdFindText:(NSArray *)tokens {
    // findtext "搜索文字" [x y w h]
    if (tokens.count < 2) { [self logError:@"findtext \"text\" [x y w h]"]; return NO; }

    UIImage *img = [[TSScreenCapture shared] captureImage];
    if (!img) { [self logError:@"截屏失败"]; return NO; }

    TSOCRResult *hit;
    NSString *text = tokens[1];
    if ([text hasPrefix:@"\""] && [text hasSuffix:@"\""]) {
        text = [text substringWithRange:NSMakeRange(1, text.length - 2)];
    }

    if (tokens.count >= 6) {
        CGRect r = CGRectMake([self floatVal:tokens[2]], [self floatVal:tokens[3]],
                              [self floatVal:tokens[4]], [self floatVal:tokens[5]]);
        hit = [[TSOCREngine shared] findText:text inImage:img inRegion:r];
    } else {
        hit = [[TSOCREngine shared] findText:text inImage:img];
    }

    if (hit) {
        [self log:[NSString stringWithFormat:@"找到文字 \"%@\" 于 (%.0f,%.0f)", hit.text, hit.center.x, hit.center.y]];
    } else {
        [self logError:[NSString stringWithFormat:@"未找到文字: \"%@\"", text]];
        return NO;
    }
    return YES;
}

- (BOOL)cmdTapText:(NSArray *)tokens {
    // taptext "文字"
    if (tokens.count < 2) { [self logError:@"taptext \"text\""]; return NO; }

    UIImage *img = [[TSScreenCapture shared] captureImage];
    if (!img) { [self logError:@"截屏失败"]; return NO; }

    NSString *text = tokens[1];
    if ([text hasPrefix:@"\""] && [text hasSuffix:@"\""]) {
        text = [text substringWithRange:NSMakeRange(1, text.length - 2)];
    }

    BOOL ok = [[TSOCREngine shared] tapText:text inImage:img];
    if (ok) {
        [self log:[NSString stringWithFormat:@"点击文字 \"%@\" 成功", text]];
    } else {
        [self logError:[NSString stringWithFormat:@"点击文字 \"%@\" 失败", text]];
        return NO;
    }
    [self logWait];
    return YES;
}

- (BOOL)cmdOCRText:(NSArray *)tokens {
    // ocrtext x y w h  → 仅返回指定区域的首个文字
    if (tokens.count < 5) { [self logError:@"ocrtext x y w h"]; return NO; }

    UIImage *img = [[TSScreenCapture shared] captureImage];
    if (!img) { [self logError:@"截屏失败"]; return NO; }

    CGRect r = CGRectMake([self floatVal:tokens[1]], [self floatVal:tokens[2]],
                          [self floatVal:tokens[3]], [self floatVal:tokens[4]]);
    NSArray<TSOCRResult *> *results = [[TSOCREngine shared] recognize:img inRegion:r];
    if (results.count > 0) {
        [self log:[NSString stringWithFormat:@"OCR区域文字: \"%@\"", results.firstObject.text]];
    } else {
        [self log:@"区域未识别到文字"];
    }
    return YES;
}

// ---------------------------------------------------------------
#pragma mark Web 服务器命令
// ---------------------------------------------------------------

- (BOOL)cmdServer:(NSArray *)tokens {
    // server [port]
    uint16_t port = tokens.count > 1 ? (uint16_t)[tokens[1] integerValue] : 8080;
    if ([[TSHTTPServer shared] isRunning]) {
        [self log:[NSString stringWithFormat:@"Web 服务器已在运行: http://localhost:%d (或 WiFi IP)", [[TSHTTPServer shared] port]]];
        return YES;
    }

    [[TSHTTPServer shared] start];
    NSString *wifiIP = [[TSToolExecutor shared] wifiIPAddress];
    [self log:[NSString stringWithFormat:@"Web 服务器已启动 → http://%@:%d", wifiIP ?: @"localhost", port]];
    return YES;
}

- (BOOL)cmdServerStop:(NSArray *)tokens {
    [[TSHTTPServer shared] stop];
    [self log:@"Web 服务器已停止"];
    return YES;
}

// ---------------------------------------------------------------
#pragma mark Shell 执行命令
// ---------------------------------------------------------------

- (BOOL)cmdExec:(NSArray *)tokens {
    if (tokens.count < 2) { [self logError:@"exec \"command\""]; return NO; }
    NSString *cmdStr = [[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)] componentsJoinedByString:@" "];
    if ([cmdStr hasPrefix:@"\""] && [cmdStr hasSuffix:@"\""]) {
        cmdStr = [cmdStr substringWithRange:NSMakeRange(1, cmdStr.length - 2)];
    }

    TSCmdResult *result = [[TSToolExecutor shared] executeCommand:cmdStr];
    if (result.exitCode == 0) {
        [self log:[NSString stringWithFormat:@"exec OK (%.2fs):\n%@", result.elapsed, result.standardOutput ?: @""]];
    } else {
        [self logError:[NSString stringWithFormat:@"exec 失败 (exit=%d): %@", result.exitCode, result.standardError]];
        return NO;
    }
    return YES;
}

// ---------------------------------------------------------------
#pragma mark 文件操作命令
// ---------------------------------------------------------------

- (BOOL)cmdFileList:(NSArray *)tokens {
    NSString *path = tokens.count > 1 ? tokens[1] : NSHomeDirectory();
    if ([path hasPrefix:@"\""] && [path hasSuffix:@"\""])
        path = [path substringWithRange:NSMakeRange(1, path.length - 2)];

    NSArray<TSFileEntry *> *entries = [[TSToolExecutor shared] listDirectory:path];
    [self log:[NSString stringWithFormat:@"目录 %@ (%lu 项):", path, (unsigned long)entries.count]];
    for (TSFileEntry *e in entries) {
        [self log:[NSString stringWithFormat:@"  %c %8lld  %@",
                    e.isDirectory ? 'd' : '-', (long long)e.size, e.name]];
    }
    return YES;
}

- (BOOL)cmdFileRead:(NSArray *)tokens {
    if (tokens.count < 2) { [self logError:@"fileread path"]; return NO; }
    NSString *path = tokens[1];
    if ([path hasPrefix:@"\""] && [path hasSuffix:@"\""])
        path = [path substringWithRange:NSMakeRange(1, path.length - 2)];

    NSString *content = [[TSToolExecutor shared] readTextFile:path];
    if (content) {
        [self log:[NSString stringWithFormat:@"%@ (%lu bytes):\n%@", path, (unsigned long)content.length, [content substringToIndex:MIN(500, content.length)]]];
    } else {
        [self logError:[NSString stringWithFormat:@"无法读取: %@", path]]; return NO;
    }
    return YES;
}

- (BOOL)cmdFileWrite:(NSArray *)tokens {
    if (tokens.count < 3) { [self logError:@"filewrite path \"content\""]; return NO; }
    NSString *path = tokens[1];
    NSString *content = tokens[2];
    if ([path hasPrefix:@"\""] && [path hasSuffix:@"\""]) path = [path substringWithRange:NSMakeRange(1, path.length - 2)];
    if ([content hasPrefix:@"\""] && [content hasSuffix:@"\""]) content = [content substringWithRange:NSMakeRange(1, content.length - 2)];

    BOOL ok = [[TSToolExecutor shared] writeTextFile:path content:content];
    [self log:ok ? [NSString stringWithFormat:@"写入成功: %@", path] : [NSString stringWithFormat:@"写入失败: %@", path]];
    return ok;
}

- (BOOL)cmdFileDelete:(NSArray *)tokens {
    if (tokens.count < 2) { [self logError:@"filedelete path"]; return NO; }
    BOOL ok = [[TSToolExecutor shared] removeItem:tokens[1]];
    [self log:ok ? [NSString stringWithFormat:@"已删除: %@", tokens[1]] : [NSString stringWithFormat:@"删除失败: %@", tokens[1]]];
    return ok;
}

- (BOOL)cmdFileCopy:(NSArray *)tokens {
    if (tokens.count < 3) { [self logError:@"filecopy src dst"]; return NO; }
    BOOL ok = [[TSToolExecutor shared] copyItem:tokens[1] to:tokens[2]];
    [self log:ok ? @"复制成功" : @"复制失败"];
    return ok;
}

- (BOOL)cmdFileExists:(NSArray *)tokens {
    if (tokens.count < 2) { [self logError:@"fexists path"]; return NO; }
    BOOL ok = [[TSToolExecutor shared] fileExists:tokens[1]];
    [self log:ok ? @"YES — 文件/目录存在" : @"NO — 不存在"];
    return ok;
}

- (BOOL)cmdFileSize:(NSArray *)tokens {
    if (tokens.count < 2) { [self logError:@"fsize path"]; return NO; }
    off_t sz = [[TSToolExecutor shared] fileSize:tokens[1]];
    if (sz >= 0) {
        [self log:[NSString stringWithFormat:@"%lld bytes (%.1f KB)", (long long)sz, sz / 1024.0]];
    } else {
        [self logError:@"无法获取文件大小"];
        return NO;
    }
    return YES;
}

- (BOOL)cmdFileMkdir:(NSArray *)tokens {
    if (tokens.count < 2) { [self logError:@"fmkdir path"]; return NO; }
    BOOL ok = [[TSToolExecutor shared] createDirectory:tokens[1]];
    [self log:ok ? @"目录已创建" : @"创建失败"];
    return ok;
}

- (BOOL)cmdFileAppend:(NSArray *)tokens {
    // fappend path "text" — 追加文本到文件
    if (tokens.count < 3) { [self logError:@"fappend path \"text\""]; return NO; }
    NSString *path = tokens[1];
    NSString *text = tokens[2];
    if ([text hasPrefix:@"\""] && [text hasSuffix:@"\""])
        text = [text substringWithRange:NSMakeRange(1, text.length - 2)];
    text = [text stringByAppendingString:@"\n"];

    NSString *old = [[TSToolExecutor shared] readTextFile:path] ?: @"";
    BOOL ok = [[TSToolExecutor shared] writeTextFile:path content:[old stringByAppendingString:text]];
    [self log:ok ? @"已追加" : @"追加失败"];
    return ok;
}

- (BOOL)cmdFileIsDir:(NSArray *)tokens {
    if (tokens.count < 2) { [self logError:@"fisdir path"]; return NO; }
    TSFileEntry *info = [[TSToolExecutor shared] fileInfo:tokens[1]];
    [self log:info.isDirectory ? @"YES — 是目录" : @"NO — 不是目录"];
    return YES;
}

// ---------------------------------------------------------------
#pragma mark 剪贴板命令
// ---------------------------------------------------------------

- (BOOL)cmdClipboardWrite:(NSArray *)tokens {
    // clipboard "text" — 写入剪贴板
    if (tokens.count < 2) { [self logError:@"clipboard \"text\""]; return NO; }
    NSString *text = [[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)] componentsJoinedByString:@" "];
    if ([text hasPrefix:@"\""] && [text hasSuffix:@"\""])
        text = [text substringWithRange:NSMakeRange(1, text.length - 2)];
    [[UIPasteboard generalPasteboard] setString:text];
    [self log:[NSString stringWithFormat:@"已写入剪贴板: %@", text]];
    return YES;
}

- (BOOL)cmdClipboardRead:(NSArray *)tokens {
    // clipboardread — 读取剪贴板内容
    NSString *text = [[UIPasteboard generalPasteboard] string];
    [self log:text ? [NSString stringWithFormat:@"剪贴板: %@", text] : @"剪贴板为空"];
    return YES;
}

- (BOOL)cmdClipboardClear:(NSArray *)tokens {
    [[UIPasteboard generalPasteboard] setString:@""];
    [self log:@"剪贴板已清空"];
    return YES;
}

// ---------------------------------------------------------------
#pragma mark Plist 命令
// ---------------------------------------------------------------

- (BOOL)cmdPlistRead:(NSArray *)tokens {
    // plistread path — 读取 plist 文件并打印
    if (tokens.count < 2) { [self logError:@"plistread path"]; return NO; }
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:tokens[1]];
    if (!dict) {
        [self logError:@"无法读取 plist (格式错误或不存在)"];
        return NO;
    }
    [self log:[NSString stringWithFormat:@"Plist (%lu keys):", (unsigned long)dict.count]];
    for (NSString *key in dict) {
        [self log:[NSString stringWithFormat:@"  %@ = %@", key, dict[key]]];
    }
    return YES;
}

- (BOOL)cmdPlistWrite:(NSArray *)tokens {
    // plistwrite path key value — 写入/修改 plist 中的一个键
    if (tokens.count < 4) { [self logError:@"plistwrite path key value"]; return NO; }
    NSString *path = tokens[1];
    NSString *key = tokens[2];
    NSString *value = tokens[3];
    if ([value hasPrefix:@"\""] && [value hasSuffix:@"\""])
        value = [value substringWithRange:NSMakeRange(1, value.length - 2)];

    NSMutableDictionary *dict = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy] ?: [NSMutableDictionary dictionary];
    // 尝试解析为数字
    NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
    NSNumber *num = [f numberFromString:value];
    dict[key] = num ?: value;
    BOOL ok = [dict writeToFile:path atomically:YES];
    [self log:ok ? @"Plist 写入成功" : @"Plist 写入失败"];
    return ok;
}

// ---------------------------------------------------------------
#pragma mark 网络命令
// ---------------------------------------------------------------

- (BOOL)cmdIP:(NSArray *)tokens {
    NSString *wifi = [[TSToolExecutor shared] wifiIPAddress];
    NSString *cell = [[TSToolExecutor shared] cellularIPAddress];
    [self log:[NSString stringWithFormat:@"WiFi: %@ | 蜂窝: %@", wifi ?: @"无", cell ?: @"无"]];
    return YES;
}

- (BOOL)cmdHttpGet:(NSArray *)tokens {
    // httpget "url"
    if (tokens.count < 2) { [self logError:@"httpget url"]; return NO; }
    NSString *url = tokens[1];
    if ([url hasPrefix:@"\""] && [url hasSuffix:@"\""])
        url = [url substringWithRange:NSMakeRange(1, url.length - 2)];

    [self log:[NSString stringWithFormat:@"HTTP GET %@ ...", url]];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSData *respData = nil;
    __block NSError *respErr = nil;

    [[TSToolExecutor shared] httpGet:url completion:^(NSData *data, NSError *error) {
        respData = data;
        respErr = error;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

    if (respErr) {
        [self logError:[NSString stringWithFormat:@"HTTP错误: %@", respErr]];
        return NO;
    }
    NSString *body = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding];
    [self log:[NSString stringWithFormat:@"响应 (%lu bytes):\n%@",
                (unsigned long)respData.length, [body substringToIndex:MIN(500, body.length)]]];
    return YES;
}

- (BOOL)cmdHttpPost:(NSArray *)tokens {
    // httppost "url" "body"
    if (tokens.count < 3) { [self logError:@"httppost url body"]; return NO; }
    NSString *url = tokens[1], *body = tokens[2];
    if ([url hasPrefix:@"\""]) url = [url substringWithRange:NSMakeRange(1, url.length - 2)];
    if ([body hasPrefix:@"\""]) body = [body substringWithRange:NSMakeRange(1, body.length - 2)];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [[TSToolExecutor shared] httpPost:url body:[body dataUsingEncoding:NSUTF8StringEncoding]
                         contentType:@"application/json"
                          completion:^(NSData *data, NSError *error) {
        [self log:error ? [NSString stringWithFormat:@"HTTP POST 失败: %@", error]
                       : [NSString stringWithFormat:@"HTTP POST OK (%lu bytes)", (unsigned long)data.length]];
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    return YES;
}

// ---------------------------------------------------------------
#pragma mark 系统信息命令
// ---------------------------------------------------------------

- (BOOL)cmdDiskInfo:(NSArray *)tokens {
    NSDictionary *info = [[TSToolExecutor shared] diskInfo];
    [self log:[NSString stringWithFormat:@"磁盘: %@", info]];
    return YES;
}

- (BOOL)cmdMemoryInfo:(NSArray *)tokens {
    NSDictionary *info = [[TSToolExecutor shared] memoryInfo];
    [self log:[NSString stringWithFormat:@"内存: %@", info]];
    return YES;
}

- (BOOL)cmdCPUInfo:(NSArray *)tokens {
    NSDictionary *info = [[TSToolExecutor shared] cpuInfo];
    [self log:[NSString stringWithFormat:@"CPU: %@", info]];
    return YES;
}

- (BOOL)cmdUptime:(NSArray *)tokens {
    NSTimeInterval ut = [[TSToolExecutor shared] systemUptime];
    [self log:[NSString stringWithFormat:@"系统运行: %.0f秒 (%.1f小时)", ut, ut / 3600.0]];
    return YES;
}

// ---------------------------------------------------------------
#pragma mark 应用管理命令
// ---------------------------------------------------------------

- (BOOL)cmdFrontBid:(NSArray *)tokens {
    // frontbid — 获取前台应用 BundleID
    NSString *bid = [[TSAppManager shared] frontBid];
    if (bid) {
        pid_t pid = [[TSAppManager shared] frontPid];
        [self log:[NSString stringWithFormat:@"前台: %@ (PID:%d)", bid, pid]];
    } else {
        [self log:@"前台: 未获取到"];
    }
    return YES;
}

- (BOOL)cmdAppList:(NSArray *)tokens {
    // applist [过滤关键词] — 列出所有用户应用
    NSString *filter = tokens.count > 1 ? tokens[1] : nil;
    if ([filter hasPrefix:@"\""] && [filter hasSuffix:@"\""])
        filter = [filter substringWithRange:NSMakeRange(1, filter.length - 2)];

    NSArray<TSAppInfo *> *apps = [[TSAppManager shared] installedApps];
    [self log:[NSString stringWithFormat:@"已安装应用 (%lu个):", (unsigned long)apps.count]];

    NSInteger shown = 0;
    for (TSAppInfo *info in apps) {
        if (filter.length > 0 &&
            ![info.name localizedCaseInsensitiveContainsString:filter] &&
            ![info.bundleId localizedCaseInsensitiveContainsString:filter])
            continue;
        [self log:[NSString stringWithFormat:@"  %@ (%@) v%@ %s",
                    info.name, info.bundleId, info.version,
                    info.pid > 0 ? "[运行中]" : ""]];
        shown++;
    }
    if (filter.length > 0) {
        [self log:[NSString stringWithFormat:@"筛选 \"%@\" 共 %ld 个", filter, (long)shown]];
    }
    return YES;
}

- (BOOL)cmdAppInfo:(NSArray *)tokens {
    // appinfo bundleId — 获取应用详细信息
    if (tokens.count < 2) { [self logError:@"appinfo bundleId"]; return NO; }
    NSString *bid = tokens[1];
    if ([bid hasPrefix:@"\""] && [bid hasSuffix:@"\""])
        bid = [bid substringWithRange:NSMakeRange(1, bid.length - 2)];

    TSAppInfo *info = [[TSAppManager shared] appInfo:bid];
    [self log:[NSString stringWithFormat:@"应用信息:"]] ;
    [self log:[NSString stringWithFormat:@"  名称:     %@", info.name]];
    [self log:[NSString stringWithFormat:@"  BundleID: %@", info.bundleId]];
    [self log:[NSString stringWithFormat:@"  版本:     %@", info.version]];
    [self log:[NSString stringWithFormat:@"  包路径:   %@", info.bundlePath ?: @"?"]];
    [self log:[NSString stringWithFormat:@"  数据路径: %@", info.dataPath ?: @"?"]];
    [self log:[NSString stringWithFormat:@"  状态:     %s (PID:%d)",
              info.pid > 0 ? "运行中" : "未运行", info.pid]];
    return YES;
}

- (BOOL)cmdOpenApp:(NSArray *)tokens {
    // openapp bundleId — 启动应用
    if (tokens.count < 2) { [self logError:@"openapp bundleId"]; return NO; }
    NSString *bid = tokens[1];
    if ([bid hasPrefix:@"\""] && [bid hasSuffix:@"\""])
        bid = [bid substringWithRange:NSMakeRange(1, bid.length - 2)];

    BOOL ok = [[TSAppManager shared] openApp:bid];
    [self log:ok ? [NSString stringWithFormat:@"已启动: %@", bid]
                : [NSString stringWithFormat:@"启动失败: %@", bid]];
    return ok;
}

- (BOOL)cmdCloseApp:(NSArray *)tokens {
    // closeapp bundleId — 关闭/杀死应用
    if (tokens.count < 2) { [self logError:@"closeapp bundleId"]; return NO; }
    NSString *bid = tokens[1];
    if ([bid hasPrefix:@"\""] && [bid hasSuffix:@"\""])
        bid = [bid substringWithRange:NSMakeRange(1, bid.length - 2)];

    BOOL ok = [[TSAppManager shared] closeApp:bid];
    [self log:ok ? [NSString stringWithFormat:@"已关闭: %@", bid]
                : [NSString stringWithFormat:@"关闭失败: %@", bid]];
    return ok;
}

- (BOOL)cmdUninstallApp:(NSArray *)tokens {
    // uninstall bundleId — 卸载应用
    if (tokens.count < 2) { [self logError:@"uninstall bundleId"]; return NO; }
    NSString *bid = tokens[1];
    if ([bid hasPrefix:@"\""] && [bid hasSuffix:@"\""])
        bid = [bid substringWithRange:NSMakeRange(1, bid.length - 2)];

    [self log:[NSString stringWithFormat:@"正在卸载: %@ ...", bid]];
    BOOL ok = [[TSAppManager shared] uninstallApp:bid];
    [self log:ok ? [NSString stringWithFormat:@"已卸载: %@", bid]
                : [NSString stringWithFormat:@"卸载失败: %@", bid]];
    return ok;
}

- (BOOL)cmdInstallApp:(NSArray *)tokens {
    // instapp ipa路径 — 安装IPA
    if (tokens.count < 2) { [self logError:@"instapp ipa路径"]; return NO; }
    NSString *path = tokens[1];
    if ([path hasPrefix:@"\""] && [path hasSuffix:@"\""])
        path = [path substringWithRange:NSMakeRange(1, path.length - 2)];

    [self log:[NSString stringWithFormat:@"正在安装: %@ ...", path]];
    BOOL ok = [[TSAppManager shared] installIPA:path];
    [self log:ok ? @"安装成功" : @"安装失败"];
    return ok;
}

- (BOOL)cmdOpenURL:(NSArray *)tokens {
    // openurl "url" — 打开URL
    if (tokens.count < 2) { [self logError:@"openurl url"]; return NO; }
    NSString *url = tokens[1];
    if ([url hasPrefix:@"\""] && [url hasSuffix:@"\""])
        url = [url substringWithRange:NSMakeRange(1, url.length - 2)];

    BOOL ok = [[TSAppManager shared] openURL:url];
    [self log:ok ? [NSString stringWithFormat:@"已打开: %@", url]
                : [NSString stringWithFormat:@"打开失败: %@", url]];
    return ok;
}

// ---------------------------------------------------------------
#pragma mark 按键命令
// ---------------------------------------------------------------

- (BOOL)cmdKey:(NSArray *)tokens {
    // key home | lock | volumeup | volumedown | home2x
    if (tokens.count < 2) {
        [self logError:@"key home|lock|volumeup|volumedown|home2x"];
        return NO;
    }
    NSString *action = [tokens[1] lowercaseString];
    TSKeyboardInjector *kb = [TSKeyboardInjector shared];

    if ([action isEqualToString:@"home"]) {
        [kb pressHome];
        [self log:@"Home 键"];
    } else if ([action isEqualToString:@"lock"]) {
        [kb pressLock];
        [self log:@"锁屏键"];
    } else if ([action isEqualToString:@"volumeup"] || [action isEqualToString:@"volup"]) {
        [kb pressVolumeUp];
        [self log:@"音量+"];
    } else if ([action isEqualToString:@"volumedown"] || [action isEqualToString:@"voldown"]) {
        [kb pressVolumeDown];
        [self log:@"音量-"];
    } else if ([action isEqualToString:@"home2x"]) {
        [kb doublePressHome];
        [self log:@"双击 Home (多任务)"];
    } else {
        [self logError:[NSString stringWithFormat:@"未知按键: %@, 可用: home/lock/volumeup/volumedown/home2x", action]];
        return NO;
    }
    [self logWait];
    return YES;
}

// ---------------------------------------------------------------
#pragma mark 加密与字符串命令
// ---------------------------------------------------------------

- (BOOL)cmdMD5:(NSArray *)tokens {
    // md5 "string" | md5 @filepath  — 计算MD5
    if (tokens.count < 2) { [self logError:@"md5 \"str\" | md5 @file"]; return NO; }
    NSString *input = tokens[1];
    NSData *data = nil;

    if ([input hasPrefix:@"@"]) {
        // @file — 计算文件 MD5
        NSString *path = [input substringFromIndex:1];
        data = [NSData dataWithContentsOfFile:path];
        if (!data) { [self logError:@"无法读取文件"]; return NO; }
        [self log:[NSString stringWithFormat:@"MD5(%@) = %@", path, [self _md5:data]]];
    } else {
        if ([input hasPrefix:@"\""] && [input hasSuffix:@"\""])
            input = [input substringWithRange:NSMakeRange(1, input.length - 2)];
        data = [input dataUsingEncoding:NSUTF8StringEncoding];
        [self log:[NSString stringWithFormat:@"MD5 = %@", [self _md5:data]]];
    }
    return YES;
}

- (BOOL)cmdSHA256:(NSArray *)tokens {
    // sha256 "string" | sha256 @filepath
    if (tokens.count < 2) { [self logError:@"sha256 \"str\" | sha256 @file"]; return NO; }
    NSString *input = tokens[1];
    NSData *data = nil;

    if ([input hasPrefix:@"@"]) {
        NSString *path = [input substringFromIndex:1];
        data = [NSData dataWithContentsOfFile:path];
        if (!data) { [self logError:@"无法读取文件"]; return NO; }
        [self log:[NSString stringWithFormat:@"SHA256(%@) = %@", path, [self _sha256:data]]];
    } else {
        if ([input hasPrefix:@"\""] && [input hasSuffix:@"\""])
            input = [input substringWithRange:NSMakeRange(1, input.length - 2)];
        data = [input dataUsingEncoding:NSUTF8StringEncoding];
        [self log:[NSString stringWithFormat:@"SHA256 = %@", [self _sha256:data]]];
    }
    return YES;
}

- (BOOL)cmdBase64Encode:(NSArray *)tokens {
    if (tokens.count < 2) { [self logError:@"b64enc \"str\""]; return NO; }
    NSString *input = tokens[1];
    if ([input hasPrefix:@"\""] && [input hasSuffix:@"\""])
        input = [input substringWithRange:NSMakeRange(1, input.length - 2)];
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    NSString *encoded = [data base64EncodedStringWithOptions:0];
    [self log:[NSString stringWithFormat:@"Base64: %@", encoded]];
    return YES;
}

- (BOOL)cmdBase64Decode:(NSArray *)tokens {
    if (tokens.count < 2) { [self logError:@"b64dec \"str\""]; return NO; }
    NSString *input = tokens[1];
    if ([input hasPrefix:@"\""] && [input hasSuffix:@"\""])
        input = [input substringWithRange:NSMakeRange(1, input.length - 2)];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:input options:0];
    if (!data) { [self logError:@"Base64 解码失败"]; return NO; }
    NSString *decoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"(非文本)";
    [self log:[NSString stringWithFormat:@"解码: %@", decoded]];
    return YES;
}

- (BOOL)cmdTrim:(NSArray *)tokens {
    // trim "  hello  " → "hello"
    if (tokens.count < 2) { [self logError:@"trim \"str\""]; return NO; }
    NSString *input = [[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)] componentsJoinedByString:@" "];
    if ([input hasPrefix:@"\""] && [input hasSuffix:@"\""])
        input = [input substringWithRange:NSMakeRange(1, input.length - 2)];
    NSString *result = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self log:[NSString stringWithFormat:@"trim: \"%@\"", result]];
    return YES;
}

- (BOOL)cmdSplit:(NSArray *)tokens {
    // split "a,b,c" ,  → 逐行输出
    if (tokens.count < 3) { [self logError:@"split \"str\" delimiter"]; return NO; }
    NSString *input = tokens[1];
    NSString *delim = tokens[2];
    if ([input hasPrefix:@"\""] && [input hasSuffix:@"\""])
        input = [input substringWithRange:NSMakeRange(1, input.length - 2)];
    if ([delim hasPrefix:@"\""] && [delim hasSuffix:@"\""])
        delim = [delim substringWithRange:NSMakeRange(1, delim.length - 2)];
    NSArray *parts = [input componentsSeparatedByString:delim];
    [self log:[NSString stringWithFormat:@"split 结果 (%lu parts):", (unsigned long)parts.count]];
    for (NSUInteger i = 0; i < parts.count; i++) {
        [self log:[NSString stringWithFormat:@"  [%lu] %@", (unsigned long)i, parts[i]]];
    }
    return YES;
}

- (BOOL)cmdRandom:(NSArray *)tokens {
    // random min max  — 生成 min~max 之间的随机整数
    if (tokens.count < 3) { [self logError:@"random min max"]; return NO; }
    NSInteger lo = [tokens[1] integerValue], hi = [tokens[2] integerValue];
    if (lo > hi) { NSInteger t = lo; lo = hi; hi = t; }
    NSInteger r = lo + arc4random_uniform((uint32_t)(hi - lo + 1));
    [self log:[NSString stringWithFormat:@"随机数: %ld", (long)r]];
    return YES;
}

// ---------------------------------------------------------------
#pragma mark 加密辅助
// ---------------------------------------------------------------

- (NSString *)_md5:(NSData *)data {
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *s = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
        [s appendFormat:@"%02x", digest[i]];
    return s;
}

- (NSString *)_sha256:(NSData *)data {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *s = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        [s appendFormat:@"%02x", digest[i]];
    return s;
}

// ---------------------------------------------------------------
#pragma mark 工具方法
// ---------------------------------------------------------------

- (NSArray *)splitTokens:(NSString *)line {
    NSMutableArray *arr = [NSMutableArray array];
    NSInteger i = 0, n = (NSInteger)line.length;
    
    while (i < n) {
        // 跳过空格
        while (i < n && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[line characterAtIndex:i]]) i++;
        if (i >= n) break;
        
        unichar ch = [line characterAtIndex:i];
        if (ch == '"' || ch == '\'') {
            // 引号字符串
            unichar q = ch; i++;
            NSMutableString *s = [NSMutableString string];
            while (i < n && [line characterAtIndex:i] != q) {
                [s appendFormat:@"%C", [line characterAtIndex:i]];
                i++;
            }
            i++; // 跳闭合引号
            [arr addObject:s];
        } else {
            // 普通 token
            NSInteger start = i;
            while (i < n && ![[NSCharacterSet whitespaceCharacterSet] characterIsMember:[line characterAtIndex:i]]) i++;
            [arr addObject:[line substringWithRange:NSMakeRange(start, i - start)]];
        }
    }
    return arr;
}

- (CGFloat)floatVal:(NSString *)s {
    return (CGFloat)[s doubleValue];
}

- (int)parseColor:(NSString *)s {
    NSString *clean = s;
    if ([clean hasPrefix:@"0x"] || [clean hasPrefix:@"0X"]) clean = [clean substringFromIndex:2];
    if ([clean hasPrefix:@"#"]) clean = [clean substringFromIndex:1];
    unsigned int val = 0;
    [[NSScanner scannerWithString:clean] scanHexInt:&val];
    return (int)val;
}

- (void)log:(NSString *)msg {
    // 直接回调 delegate: ViewController log: 内部已做线程安全聚合节流,
    // 无需再向主线程逐条派发(高频日志时避免主线程队列堆积)。
    [self.logDelegate log:msg];
}

- (void)logError:(NSString *)msg {
    [self.logDelegate log:[NSString stringWithFormat:@"[ERROR] %@", msg]];
}

- (void)logWait {
    [NSThread sleepForTimeInterval:0.05];
}

@end
