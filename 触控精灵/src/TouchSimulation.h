/**
 *  TouchSimulation.h
 *  屏幕触控模拟 — 单击 / 长按 / 滑动
 *
 *  基于 IOHIDEvent 底层事件发送，无需注入 / Hook
 *  需要 entitlement: com.apple.private.iohid.event-system
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface TouchSimulation : NSObject

+ (instancetype)shared;

/// 屏幕单击
- (void)clickAtX:(CGFloat)x y:(CGFloat)y;

/// 长按（durationMs 为按住时长，单位毫秒）
- (void)longClickAtX:(CGFloat)x y:(CGFloat)y durationMs:(int)durationMs;

/// 滑动
- (void)swipeFromX:(CGFloat)x1 y:(CGFloat)y1
              toX:(CGFloat)x2 y:(CGFloat)y2
        durationMs:(int)durationMs;

/// 获取屏幕尺寸
- (CGSize)screenSize;

@end
