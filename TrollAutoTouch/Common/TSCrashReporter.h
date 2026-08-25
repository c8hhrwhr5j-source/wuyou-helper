//
//  TSCrashReporter.h
//  TrollAutoTouch
//
//  轻量崩溃捕获: 捕获 NSException 与常见信号
//  (SIGABRT / SIGSEGV / SIGBUS / SIGILL / SIGFPE / SIGTRAP),
//  把崩溃原因与调用栈写入 /var/mobile/touch/log/crash.log,
//  并在 App 启动时载入 TSLogStore —— 用户可在设置页"查看系统日志"
//  直接看到上次崩溃原因与堆栈, 无需连接电脑。
//
//  注意: 信号 handler 只做 C 级文件写入(async-signal-safe),
//  不调用任何 Objective-C 运行时, 避免崩溃时二次崩溃。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSCrashReporter : NSObject

+ (void)install;

@end

NS_ASSUME_NONNULL_END
