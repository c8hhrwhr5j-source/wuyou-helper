//
//  TSKeyboardInjector.h
//  TrollAutoTouch
//
//  系统级键盘事件注入 —— 使用 GSEvent 私有 API 发送按键与文本。
//  在 TrollStore 环境下可绕过沙箱向前台 App 注入键盘事件。
//
//  原理: 通过 GraphicsServices.framework 的 GSEvent 系列函数构造并投递
//        键盘事件到 backboardd，实现真实文本输入和硬件按键模拟。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 硬件按键类型（对应 iOS 硬件按键）
typedef NS_ENUM(NSInteger, TSKeyCode) {
    TSKeyCodeHome        = 102,  // Home 键
    TSKeyCodeLock        = 105,  // 电源/锁屏键
    TSKeyCodeVolumeUp    = 115,  // 音量+
    TSKeyCodeVolumeDown  = 114,  // 音量-
    TSKeyCodeMute        = 113,  // 静音
    TSKeyCodeSiri        = 0x0D, // Siri 键 (旧机型长按 Home)
};

@interface TSKeyboardInjector : NSObject

+ (instancetype)shared;

#pragma mark - 文本输入

/// 向前台应用注入文本（模拟键盘输入）
/// 优先使用 GSEventKey 低层注入，失败则回退到剪贴板
- (BOOL)inputText:(NSString *)text;

#pragma mark - 硬件按键

/// 按 Home 键（HID 直发优先，通道不可用时回退 GSEvent）
- (void)pressHome;

/// 只走 HID 直发（IOHIDEventCreateKeyboardEvent，原版 luaLib 同款通道）。
/// 返回 NO = 直发通道不可用（HID client 没建起来），事件未发出。
- (BOOL)pressHomeViaHID;

/// 只走老的 GSEvent 通道（GSEventCreateKeyEvent + GSEventPost）
- (void)pressHomeViaGSEvent;

/// 锁定屏幕（电源键）
- (void)pressLock;

/// 音量+
- (void)pressVolumeUp;

/// 音量-
- (void)pressVolumeDown;

/// 按两下 Home 键（打开多任务）
- (void)doublePressHome;

@end

NS_ASSUME_NONNULL_END
