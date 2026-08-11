//
//  TSTouchRecorder.h
//  TrollAutoTouch
//
//  触控录制与回放模块 —— 对应原版 touch.Record / touch.StopRecode / touch.PlayRecode。
//  原理: 按固定帧率采样 IOKit 触摸事件，记录时间戳+坐标+相位，
//        回放时同步重现所有触摸动作。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 触摸相位
typedef NS_ENUM(NSInteger, TSTouchPhase) {
    TSTouchPhaseBegan = 0,
    TSTouchPhaseMoved = 1,
    TSTouchPhaseEnded  = 2,
    TSTouchPhaseCancelled = 2,  // 与 ended 等同处理
};

/// 单个触摸帧记录
@interface TSTouchFrame : NSObject <NSSecureCoding>
@property (nonatomic, assign) NSTimeInterval timestamp;  // 相对首帧的偏移(秒)
@property (nonatomic, assign) CGPoint point;
@property (nonatomic, assign) NSInteger phase;           // 0=began, 1=moved, 2=ended
@property (nonatomic, assign) NSInteger fingerIndex;     // 多指支持
@end

/// 一次完整的触摸序列
@interface TSTouchRecording : NSObject <NSSecureCoding>
@property (nonatomic, strong) NSMutableArray<TSTouchFrame *> *frames;
@property (nonatomic, assign) NSTimeInterval totalDuration;
- (instancetype)init;
@end

/// 触摸录制/回放器
@interface TSTouchRecorder : NSObject

+ (instancetype)shared;

/// 是否正在录制
@property (nonatomic, readonly) BOOL isRecording;

/// 是否正在回放
@property (nonatomic, readonly) BOOL isPlaying;

/// 当前录制(录制完成后可用)
@property (nonatomic, strong, readonly, nullable) TSTouchRecording *recording;

// ---- 录制 ----

/// 开始录制。采样间隔 interval(秒)，推荐 0.016(60fps)。
- (void)startRecordingWithInterval:(NSTimeInterval)interval;

/// 停止录制
- (void)stopRecording;

// ---- 回放 ----

/// 回放当前录制。speed: 1.0=原速, 0.5=半速, 2.0=二倍速。
- (void)playRecordingWithSpeed:(CGFloat)speed;

/// 停止回放
- (void)stopPlayback;

// ---- 持久化 ----

/// 保存录制到文件
- (BOOL)saveToFile:(NSString *)path;

/// 从文件加载录制
- (BOOL)loadFromFile:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
