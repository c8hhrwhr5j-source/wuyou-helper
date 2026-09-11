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

/// senderID 获取成功通知（userInfo 含 senderID）
FOUNDATION_EXPORT NSString * const TSHIDSenderIDDidChangeNotification;

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

/// 在 (x,y) 处按下第 index 个手指 (index 从 0 起)。
/// pressure=压力(0~1 通常, 可大于 1 模拟重按), radius=触摸半径(毫米, 0 用默认 4.5)。
- (void)touchDownAtPoint:(CGPoint)point index:(NSInteger)index
                pressure:(CGFloat)pressure radius:(CGFloat)radius;
/// 移动第 index 个手指到 (x,y)
- (void)touchMoveAtPoint:(CGPoint)point index:(NSInteger)index
                pressure:(CGFloat)pressure radius:(CGFloat)radius;
/// 抬起第 index 个手指
- (void)touchUpAtPoint:(CGPoint)point index:(NSInteger)index;

/// 高层: 在 (x,y) 点击。pressDuration=按下到抬起的时长(秒), pressure/radius 同上。
- (void)tapAtPoint:(CGPoint)point duration:(NSTimeInterval)pressDuration
          pressure:(CGFloat)pressure radius:(CGFloat)radius;
/// 高层: 从 from 滑动到 to，duration=总时长，steps=中间采样点数。
- (void)swipeFromPoint:(CGPoint)from toPoint:(CGPoint)to
              duration:(NSTimeInterval)duration steps:(NSInteger)steps
              pressure:(CGFloat)pressure radius:(CGFloat)radius;

// ---- 便捷封装(默认压力 1.0 / 半径自动) ----
- (void)touchDownAtPoint:(CGPoint)point index:(NSInteger)index;
- (void)touchMoveAtPoint:(CGPoint)point index:(NSInteger)index;
- (void)tapAtPoint:(CGPoint)point duration:(NSTimeInterval)pressDuration;
- (void)swipeFromPoint:(CGPoint)from toPoint:(CGPoint)to
              duration:(NSTimeInterval)duration steps:(NSInteger)steps;

/// 释放所有仍处于按下状态的手指(补发 touchUp)。
/// 用于脚本停止/出错时清理，避免留下"幽灵手指"导致后续真实触摸被系统吞掉。
- (void)releaseAllTouches;

/// 触摸注入通道(自检对照用):
///   Auto    = 直发可用则直发, 直发不可用(HID client 建不起来)时回退本应用点击(AX/进程内)
///   HIDOnly = 只走 IOHID 直发(用于判定"直发是否被系统受理")
///   AXOnly  = 只走本应用点击(用于判定"AX 兜底是否有效")
typedef NS_ENUM(NSInteger, TSTouchChannel) {
    TSTouchChannelAuto    = 0,
    TSTouchChannelHIDOnly = 1,
    TSTouchChannelAXOnly  = 2,
};

/// 当前触摸发送者 ID（默认即原版同款固定触屏值 0x8000000800，可直接直发，无需手动触摸）。
- (uint64_t)senderID;

/// 当前 senderID 的来源描述: 固定伪装值 / 历史保存值 / 服务枚举 / 运行时监听 / 手动指定
- (NSString *)senderIDSourceDescription;

/// 触摸注入通道(默认 Auto)。脚本可临时切到 HIDOnly / AXOnly 做对照自检。
@property (nonatomic, assign) TSTouchChannel channel;

/// 主动枚举本机 digitizer(触屏)服务, 取真实 senderID —— 不需要任何真实手指触摸。
/// 返回探测到的 senderID(0 = 未找到), 并把枚举结果写入 touch.log。
- (uint64_t)probeSenderID;

/// 清除 NSUserDefaults 中保存的 senderID(可疑脏数据), 并把当前值重置为固定伪装值。
- (void)resetSenderID;

/// 手动指定 senderID(0 = 恢复自动: 服务枚举 > 保存值 > 固定值)。
/// 返回实际生效的 senderID。
- (uint64_t)setSenderIDValue:(uint64_t)sid;

/// 本机枚举到的 digitizer(触屏)服务候选列表, 每项: value / usage / product / transport。
/// 枚举不到时退化为"保存值 + 固定伪装值"两个候选。供脚本逐个试出本机可用值。
- (NSArray<NSDictionary *> *)senderIDCandidates;

/// 启用候选列表第 index 项(0 起)作为 senderID 并持久化。越界返回 0。
- (uint64_t)useSenderIDCandidateAtIndex:(NSInteger)index;

/// 监听一段时间内系统真实触摸(digitizer)事件的 senderID —— 期间请用肉手在屏幕上点一下。
/// 这是最可信的"本机真实 senderID"来源(不依赖服务枚举, 也不受候选顺序猜测影响);
/// 返回观察到的去重值列表(可能为空: 该时段内没有任何真实触摸)。
/// 注意: 期间不要同时跑脚本自己的点击 —— 内部虽有 1.5s 回显过滤, 但物理点击才是干净样本。
- (NSArray<NSNumber *> *)watchSenderIDsForMilliseconds:(NSInteger)ms;

/// 诊断状态描述（client 是否创建成功 / senderID 来源 / 通道 / 候选数 / 直发下发次数），供 Lua 层显示。
- (NSString *)statusDescription;

@end

NS_ASSUME_NONNULL_END
