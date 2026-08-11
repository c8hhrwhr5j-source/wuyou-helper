//
//  TSTouchRecorder.m
//  TrollAutoTouch
//
//  录制: 使用 CADisplayLink 按固定帧率采样当前触摸状态(需要用户实际触摸)
//        TrollStore 环境下，通过 IOHIDEvent 监听来实现录制
//  回放: 通过 TSHIDEventTouch 逐帧重现
//
//  注意: iOS 没有公开 API 可以监听全局触摸事件。录制模式依赖于:
//        1) 本 App 内触摸: 通过 UIResponder 链捕获
//        2) 全局触摸录制: 需要重写 UIApplication sendEvent: 并全局截获
//           (TrollStore App 只能录制自身窗口的触摸)
//

#import "TSTouchRecorder.h"
#import "TSHIDEventTouch.h"
#import <UIKit/UIKit.h>

#pragma mark - TSTouchFrame

@implementation TSTouchFrame

- (instancetype)init {
    self = [super init];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeDouble:self.timestamp forKey:@"ts"];
    [coder encodeDouble:self.point.x forKey:@"px"];
    [coder encodeDouble:self.point.y forKey:@"py"];
    [coder encodeInteger:self.phase forKey:@"ph"];
    [coder encodeInteger:self.fingerIndex forKey:@"fi"];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        self.timestamp = [coder decodeDoubleForKey:@"ts"];
        self.point = CGPointMake([coder decodeDoubleForKey:@"px"], [coder decodeDoubleForKey:@"py"]);
        self.phase = [coder decodeIntegerForKey:@"ph"];
        self.fingerIndex = [coder decodeIntegerForKey:@"fi"];
    }
    return self;
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

#pragma mark - TSTouchRecording

@implementation TSTouchRecording

- (instancetype)init {
    self = [super init];
    if (self) {
        _frames = [NSMutableArray array];
        _totalDuration = 0;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.frames forKey:@"frames"];
    [coder encodeDouble:self.totalDuration forKey:@"dur"];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _frames = [coder decodeObjectOfClass:[NSMutableArray class] forKey:@"frames"] ?: [NSMutableArray array];
        _totalDuration = [coder decodeDoubleForKey:@"dur"];
    }
    return self;
}

+ (BOOL)supportsSecureCoding { return YES; }

@end

#pragma mark - TouchCaptureView (录制用透明覆盖层)

/// 覆盖在最上层的透明视图，拦截触摸事件用于录制
@interface TSTouchCaptureView : UIView
@property (nonatomic, copy) void(^touchBeganHandler)(NSSet<UITouch *> *touches, UIEvent *event);
@property (nonatomic, copy) void(^touchMovedHandler)(NSSet<UITouch *> *touches, UIEvent *event);
@property (nonatomic, copy) void(^touchEndedHandler)(NSSet<UITouch *> *touches, UIEvent *event);
@end

@implementation TSTouchCaptureView

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // 先透传事件
    [super touchesBegan:touches withEvent:event];
    if (self.touchBeganHandler) { self.touchBeganHandler(touches, event); }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    if (self.touchMovedHandler) { self.touchMovedHandler(touches, event); }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    if (self.touchEndedHandler) { self.touchEndedHandler(touches, event); }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    if (self.touchEndedHandler) { self.touchEndedHandler(touches, event); }
}

/// 允许触摸穿透(录制完后放行给下层)
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) {
        // 录制中: 捕获事件；录制完成: 返回nil让事件穿透
        return self.touchBeganHandler ? self : nil;
    }
    return hit;
}

@end

#pragma mark - TSTouchRecorder

@interface TSTouchRecorder () {
    TSTouchCaptureView *_captureView;
    NSTimeInterval _recordingStartTime;
    NSTimeInterval _sampleInterval;
    TSTouchRecording *_recording;
    BOOL _isRecording;
    BOOL _isPlaying;
    volatile BOOL _stopPlaybackFlag;
}

@property (nonatomic, strong, readwrite, nullable) TSTouchRecording *recording;
@end

@implementation TSTouchRecorder

+ (instancetype)shared {
    static TSTouchRecorder *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[TSTouchRecorder alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    return self;
}

#pragma mark - 录制

- (void)startRecordingWithInterval:(NSTimeInterval)interval {
    if (_isRecording) return;
    
    _isRecording = YES;
    _sampleInterval = interval > 0 ? interval : 0.016; // 默认 60fps
    _recording = [[TSTouchRecording alloc] init];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _setupCaptureView];
    });
}

- (void)_setupCaptureView {
    UIWindowScene *scene = (UIWindowScene *)[UIApplication sharedApplication].connectedScenes.allObjects.firstObject;
    UIWindow *keyWindow = scene.keyWindow ?: scene.windows.firstObject;
    if (!keyWindow) return;
    
    _captureView = [[TSTouchCaptureView alloc] initWithFrame:keyWindow.bounds];
    _captureView.backgroundColor = [UIColor clearColor];
    _captureView.userInteractionEnabled = YES;
    _captureView.multipleTouchEnabled = YES;
    _captureView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    __weak typeof(self) weakSelf = self;
    _captureView.touchBeganHandler = ^(NSSet<UITouch *> *touches, UIEvent *event) {
        [weakSelf _recordTouches:touches phase:TSTouchPhaseBegan];
    };
    _captureView.touchMovedHandler = ^(NSSet<UITouch *> *touches, UIEvent *event) {
        [weakSelf _recordTouches:touches phase:TSTouchPhaseMoved];
    };
    _captureView.touchEndedHandler = ^(NSSet<UITouch *> *touches, UIEvent *event) {
        [weakSelf _recordTouches:touches phase:TSTouchPhaseEnded];
    };
    
    [keyWindow addSubview:_captureView];
    [keyWindow bringSubviewToFront:_captureView];
    _recordingStartTime = CACurrentMediaTime();
    
    NSLog(@"[TSTouchRecorder] 开始录制 (间隔: %.3fs)", _sampleInterval);
}

- (void)_recordTouches:(NSSet<UITouch *> *)touches phase:(TSTouchPhase)phase {
    if (!_isRecording || !_recording) return;
    
    NSTimeInterval now = CACurrentMediaTime() - _recordingStartTime;
    
    for (UITouch *touch in touches) {
        TSTouchFrame *frame = [[TSTouchFrame alloc] init];
        frame.timestamp = now;
        frame.point = [touch locationInView:nil]; // 窗口坐标
        frame.phase = (NSInteger)phase;
        frame.fingerIndex = 0; // 简化: 暂不支持多指, TODO: 按 touch hash 分配 index
        
        [_recording.frames addObject:frame];
    }
}

- (void)stopRecording {
    if (!_isRecording) return;
    
    _isRecording = NO;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_captureView) {
            [self->_captureView removeFromSuperview];
            self->_captureView = nil;
        }
    });
    
    if (_recording) {
        _recording.totalDuration = _recording.frames.lastObject ? _recording.frames.lastObject.timestamp : 0;
    }
    
    NSLog(@"[TSTouchRecorder] 录制停止，共 %lu 帧, 时长 %.2fs",
          (unsigned long)_recording.frames.count, _recording.totalDuration);
}

#pragma mark - 回放

- (void)playRecordingWithSpeed:(CGFloat)speed {
    if (_isPlaying || !_recording || _recording.frames.count == 0) return;
    if (speed <= 0) speed = 1.0;
    
    _isPlaying = YES;
    _stopPlaybackFlag = NO;
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<TSTouchFrame *> *frames = self->_recording.frames;
        NSTimeInterval lastTime = -1;
        TSTouchPhase lastPhase = TSTouchPhaseEnded;
        
        for (TSTouchFrame *frame in frames) {
            if (self->_stopPlaybackFlag) break;
            
            // 按帧间时间差等待
            if (lastTime >= 0) {
                NSTimeInterval wait = (frame.timestamp - lastTime) / speed;
                if (wait > 0) {
                    [NSThread sleepForTimeInterval:wait];
                }
            }
            if (self->_stopPlaybackFlag) break;
            
            // 需要先抬起上一个触摸(如果相位变化)
            if (frame.phase != (NSInteger)lastPhase && lastPhase != TSTouchPhaseEnded) {
                [[TSHIDEventTouch shared] touchUpAtPoint:frame.point index:frame.fingerIndex];
            }
            
            switch (frame.phase) {
                case 0: // began
                    [[TSHIDEventTouch shared] touchDownAtPoint:frame.point index:frame.fingerIndex];
                    break;
                case 1: // moved
                    [[TSHIDEventTouch shared] touchMoveAtPoint:frame.point index:frame.fingerIndex];
                    break;
                case 2: // ended
                    [[TSHIDEventTouch shared] touchUpAtPoint:frame.point index:frame.fingerIndex];
                    break;
            }
            
            lastTime = frame.timestamp;
            lastPhase = (TSTouchPhase)frame.phase;
        }
        
        // 确保最后抬起
        if (lastPhase != TSTouchPhaseEnded && !self->_stopPlaybackFlag) {
            TSTouchFrame *last = frames.lastObject;
            [[TSHIDEventTouch shared] touchUpAtPoint:last.point index:last.fingerIndex];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_isPlaying = NO;
        });
        
        NSLog(@"[TSTouchRecorder] 回放完成");
    });
}

- (void)stopPlayback {
    _stopPlaybackFlag = YES;
}

- (BOOL)isRecording { return _isRecording; }
- (BOOL)isPlaying { return _isPlaying; }

#pragma mark - 持久化

- (BOOL)saveToFile:(NSString *)path {
    if (!_recording) return NO;
    
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:_recording
                                         requiringSecureCoding:YES
                                                         error:&error];
    if (!data) {
        NSLog(@"[TSTouchRecorder] 归档失败: %@", error);
        return NO;
    }
    return [data writeToFile:path atomically:YES];
}

- (BOOL)loadFromFile:(NSString *)path {
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return NO;
    
    TSTouchRecording *rec = [NSKeyedUnarchiver unarchivedObjectOfClass:[TSTouchRecording class]
                                                              fromData:data
                                                                 error:&error];
    if (!rec) {
        NSLog(@"[TSTouchRecorder] 加载失败: %@", error);
        return NO;
    }
    _recording = rec;
    return YES;
}

@end
