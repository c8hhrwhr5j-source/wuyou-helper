//
//  TSHIDEventTouch.h
//  TrollAutoTouch
//
//  系统级触摸事件注入 —— 对应原版 TrollAutoScript 的 HUDServices 触摸实现。
//
//  原理(逆向自 HUDServices):
//    HUDServices 链接 BackBoardServices / FrontBoard 私有框架，并直接调用
//    IOKit 的 IOHIDEvent* 系列 C 函数构造"数位板/手指"事件，再通过
//    IOHIDEventSystemClientDispatchEvent 投递给 backboardd，从而在任意 App
//    之上产生系统级触摸(与 ZXTouch / SimulateTouch 同一技术路线)。
//
//  本文件声明这些私有函数并封装为高层 API: touchDown / touchMove / touchUp /
//  tap / swipe。坐标系为屏幕逻辑点 (point)。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 触摸阶段
typedef NS_ENUM(NSInteger, TSTouchPhase) {
    TSTouchPhaseBegan  = 0,  // 手指按下
    TSTouchPhaseMoved  = 1,  // 手指移动
    TSTouchPhaseEnded  = 2,  // 手指抬起
    TSTouchPhaseStationary = 3,
};

/// 单点触摸注入器(支持多点，每个手指用不同 index)。
@interface TSHIDEventTouch : NSObject

+ (instancetype)shared;

/// 在 (x,y) 处按下第 index 个手指 (index 从 0 起)
- (void)touchDownAtPoint:(CGPoint)point index:(NSInteger)index;
/// 移动第 index 个手指到 (x,y)
- (void)touchMoveAtPoint:(CGPoint)point index:(NSInteger)index;
/// 抬起第 index 个手指
- (void)touchUpAtPoint:(CGPoint)point index:(NSInteger)index;

/// 高层: 在 (x,y) 点击。pressDuration=按下到抬起的时长(秒)。
- (void)tapAtPoint:(CGPoint)point duration:(NSTimeInterval)pressDuration;
/// 高层: 从 from 滑动到 to，duration=总时长，steps=中间采样点数。
- (void)swipeFromPoint:(CGPoint)from toPoint:(CGPoint)to
              duration:(NSTimeInterval)duration steps:(NSInteger)steps;

/// 释放所有仍处于按下状态的手指(补发 touchUp)。
/// 用于脚本停止/出错时清理，避免留下"幽灵手指"导致后续真实触摸被系统吞掉。
- (void)releaseAllTouches;

@end

NS_ASSUME_NONNULL_END
