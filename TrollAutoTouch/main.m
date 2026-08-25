//
//  main.m
//  TrollAutoTouch
//

#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "TSCrashReporter.h"

int main(int argc, char * argv[]) {
    @autoreleasepool {
        // 必须在任何代码之前安装: 崩溃后把原因与堆栈写入 crash.log,
        // 下次启动自动载入设置页"查看系统日志", 便于定位闪退原因。
        [TSCrashReporter install];
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
