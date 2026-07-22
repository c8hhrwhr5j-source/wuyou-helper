//
//  ScriptEngine.h
//  无忧辅助 - Lua 脚本引擎
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ScriptState) {
    ScriptStateIdle = 0,
    ScriptStateRunning,
    ScriptStatePaused,
    ScriptStateStopping,
    ScriptStateError,
};

typedef void (^ScriptLogHandler)(NSString *message);
typedef void (^ScriptStateChangeHandler)(ScriptState newState);

@interface ScriptEngine : NSObject

+ (instancetype)sharedInstance;

@property (nonatomic, readonly) ScriptState state;

@property (nonatomic, copy, nullable) ScriptLogHandler logHandler;

@property (nonatomic, copy, nullable) ScriptStateChangeHandler stateChangeHandler;

- (BOOL)runScript:(NSString *)code;

- (BOOL)runScriptFile:(NSString *)path;

- (void)pause;

- (void)resume;

- (void)stop;

- (CGSize)screenSize;

+ (NSString *)defaultScript;

@end

NS_ASSUME_NONNULL_END