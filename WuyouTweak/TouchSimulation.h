//
//  TouchSimulation.h
//  无忧辅助 - 触控模拟（多指支持）
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 滑动对象 — 支持链式调用
@interface TouchSlide : NSObject

/// 设置步进像素（默认 10）
- (TouchSlide *)step:(int)step;

/// 设置每步延迟毫秒（默认 5）
- (TouchSlide *)delay:(int)delayMs;

/// 手指按下
- (TouchSlide *)on:(CGFloat)x y:(CGFloat)y;

/// 手指移动到
- (TouchSlide *)move:(CGFloat)x y:(CGFloat)y;

/// 手指抬起
- (TouchSlide *)up;

@end

@interface TouchSimulation : NSObject

/// 日志回调（由 ScriptEngine 注入，确保诊断信息显示在应用日志中）
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *msg);

/// 输出当前触控系统状态诊断
- (void)logDiagnostic;

+ (instancetype)sharedInstance;

// MARK: - 底层原子操作（多指）

/// 手指按下（手指ID 0-128）
- (void)downAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID;

/// 手指移动
- (void)moveAtX:(CGFloat)x y:(CGFloat)y fingerID:(uint32_t)fingerID;

/// 手指抬起
- (void)upFinger:(uint32_t)fingerID;

// MARK: - 高级封装

/// 点击（随机手指ID，默认 50ms 抬起延迟）
- (void)tapAtX:(CGFloat)x y:(CGFloat)y delayMs:(int)ms fingerID:(uint32_t)fingerID;

/// 随机点击（在 (x±r, y±r) 范围内随机偏移）
- (void)tapRandomAtX:(CGFloat)x y:(CGFloat)y range:(int)r delayMs:(int)ms fingerID:(uint32_t)fingerID;

/// 创建滑动对象
- (TouchSlide *)slideWithFingerID:(uint32_t)fingerID;

// MARK: - 兼容旧接口

/// 点击
- (void)clickAtX:(CGFloat)x y:(CGFloat)y;

/// 长按
- (void)holdAtX:(CGFloat)x y:(CGFloat)y duration:(NSInteger)ms;

/// 滑动
- (void)swipeFromX:(CGFloat)x1 y:(CGFloat)y1
               toX:(CGFloat)x2 y:(CGFloat)y2
          duration:(NSInteger)ms;

@end

NS_ASSUME_NONNULL_END
