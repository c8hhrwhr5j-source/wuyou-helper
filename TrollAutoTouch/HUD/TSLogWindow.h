//
//  TSLogWindow.h — 脚本日志浮动窗口
//
//  对齐原版 TrollAutoScript 2.3.6 的 logWindow 模块:
//      local lw = logWindow.init(x, y [, 宽, 高, 背景透明度, 背景色, 字体色, 字体尺寸])
//      lw:addLog("文本" [, 文字颜色, 文字尺寸])
//      lw:release()
//      logWindow.setHideWindowMode(true)
//
//  实现要点(逆向 + 本机(iOS 15 / TrollStore)验证路线):
//   · 所有日志面板挂在**同一个**全屏透明 UIWindow 上 —— 跨应用显示只需注册
//     一次 SBS 系统级托管 (每个 UIWindow 各需一个 CAContext, 见 TSHUDWindow);
//   · 窗口本身 userInteractionEnabled = NO 且 hitTest 恒返回 nil: 完全穿透,
//     不影响任何触摸;
//   · "隐藏模式"(setHideWindowMode) 下, 截图瞬间把内容层临时隐藏并提交,
//     使找图/找色/取色拿到的画面里不含面板 —— 肉眼可见, 脚本看不见。
//     (原版 logWindowDict / logWindowRelease: 也是"肉眼可见、不参与取色"的语义)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSLogWindowManager : NSObject

+ (instancetype)shared;

/// 隐藏模式: YES = 面板肉眼可见, 但脚本取到的画面(找图/找色/取色)里没有它。
/// 默认 NO(面板会被截进画面对找图找色产生干扰)。
@property (nonatomic, assign) BOOL hideWindowMode;

/// 脚本坐标系方向 (对应 Lua screen.init): 0=home在下(竖屏) 1=home在右 2=home在左。
/// 面板坐标按脚本坐标系解释, 内容层随之旋转 —— 横屏脚本里日志也是横着读的,
/// 与 tap/findColor/getScreenSize 完全同源。线程安全。
@property (nonatomic, assign) NSInteger scriptOrientation;

/// 创建一个日志窗口并立即显示。alpha=背景透明度(0.1~1.0), 颜色为 0xRRGGBB。
/// 返回窗口 id (<=0 = 创建失败)。
- (NSInteger)openAt:(CGPoint)origin
               size:(CGSize)size
              alpha:(CGFloat)alpha
              bgHex:(int)bgHex
              fgHex:(int)fgHex
           fontSize:(CGFloat)fontSize;

/// 追加一行日志。hex = 0xRRGGBB; size <= 0 时沿用窗口的字体尺寸。
- (void)appendText:(NSString *)text hex:(int)hex size:(CGFloat)size windowId:(NSInteger)wid;

/// 关闭指定日志窗口。
- (void)closeWindow:(NSInteger)wid;

/// 关闭全部日志窗口(脚本停止时兜底清理)。
- (void)closeAll;

/// 截图前传 YES、截图后传 NO: 隐藏模式下临时把面板从合成画面里摘掉。
/// 未开启隐藏模式 / 没有任何面板时为空操作, 零开销。
- (void)setExcludedFromCapture:(BOOL)excluded;

@end

NS_ASSUME_NONNULL_END
