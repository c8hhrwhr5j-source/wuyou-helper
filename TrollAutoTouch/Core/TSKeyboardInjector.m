//
//  TSKeyboardInjector.m
//  TrollAutoTouch
//
//  GSEvent 键盘事件注入实现。
//
//  逆向依据:
//    原版 TrollAutoScript 的 HUDServices 使用 GraphicsServices 框架的
//    GSEvent 系列函数发送按键事件。本实现通过 dlopen/dlsym 动态加载
//    GraphicsServices，避免硬链接（兼容不同 iOS 版本）。
//
//  关键符号(来自 GraphicsServices 二进制):
//    _GSEventCreateKeyEvent
//    _GSEventPost
//    _GSEventLockDevice
//    _GSEventSetBacklightLevel
//    _GSEventSendKeyToActiveApp
//

#import "TSKeyboardInjector.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>

// ─── GSEvent 私有类型 ───
typedef struct __GSEvent  *GSEventRef;
typedef struct __GSKeyboardRef *GSKeyboardRef;

// ─── 函数指针 ───
static GSEventRef (*_GSEventCreateKeyEvent)(CFAllocatorRef, int keyCode, int keyDown,
    int modifiers, int charCode, int charSet, int senteCode, int flags) = NULL;

static void (*_GSEventPost)(GSEventRef, Boolean) = NULL;

static void (*_GSKeyboardInit)(void) = NULL;

static void (*_GSEventLockDevice)(void) = NULL;

static void (*_GSHIDEventPostKey)(int keyCode, int keyDown) = NULL;

/// 发送单个按键事件（通过 GSEvent 或 GSHIDEventPostKey）
/// keyCode: HID 键盘键码
/// down: 1=按下, 0=弹起
static void _postKey(int keyCode, int keyDown) {
    // 方式1: GSHIDEventPostKey (更通用)
    if (_GSHIDEventPostKey) {
        _GSHIDEventPostKey(keyCode, keyDown);
        return;
    }

    // 方式2: GSEventCreateKeyEvent + GSEventPost
    if (_GSEventCreateKeyEvent && _GSEventPost) {
        GSEventRef evt = _GSEventCreateKeyEvent(kCFAllocatorDefault,
            keyCode,     // keyCode
            keyDown,     // keyDown (1=press, 0=release)
            0,           // modifiers
            keyCode,     // charCode
            0,           // charSet
            0,           // senteCode
            0);          // flags
        if (evt) {
            _GSEventPost(evt, true);
            CFRelease(evt);
        }
    }
}

// ─── 符号初始化 ───
static void _loadGraphicsServices(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices", RTLD_LAZY);
        if (!h) {
            // 备选路径（iOS 14+ 可能合并到其他 dylib）
            h = dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices.bundle/GraphicsServices", RTLD_LAZY);
        }
        if (h) {
            _GSEventCreateKeyEvent = dlsym(h, "GSEventCreateKeyEvent");
            _GSEventPost           = dlsym(h, "GSEventPost");
            _GSEventLockDevice     = dlsym(h, "GSEventLockDevice");

            // 备选符号名（不同 iOS 版本函数名可能略有差异）
            if (!_GSHIDEventPostKey) {
                _GSHIDEventPostKey = dlsym(h, "GSHIDEventPostKey");
            }
            if (!_GSHIDEventPostKey) {
                _GSHIDEventPostKey = dlsym(h, "_GSHIDEventPostKey");
            }
        }

        // 回退: 尝试 libMobileGestalt 或直接通过 IOKit
        if (!_GSHIDEventPostKey && !_GSEventCreateKeyEvent) {
            // 尝试从 BackBoardServices 获取
            void *bh = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
            if (bh) {
                _GSHIDEventPostKey = dlsym(bh, "BKSHIDEventPostKey");
                if (!_GSHIDEventPostKey) {
                    _GSHIDEventPostKey = dlsym(bh, "BKSHIDEventPostEvent");
                }
            }
        }
    });
}

// ─── 实现 ───

@implementation TSKeyboardInjector

+ (instancetype)shared {
    static TSKeyboardInjector *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TSKeyboardInjector alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _loadGraphicsServices();
    }
    return self;
}

#pragma mark - 文本输入

- (BOOL)inputText:(NSString *)text {
    if (!text || text.length == 0) return NO;

    // 方式1: 尝试 GSEvent 逐个字符注入
    if (_GSHIDEventPostKey || _GSEventCreateKeyEvent) {
        [self _injectStringViaKeyEvents:text];
        return YES;
    }

    // 方式2: 回退 — 复制到剪贴板
    [[UIPasteboard generalPasteboard] setString:text];
    return YES;
}

/// 通过逐字符 HID 键盘事件注入文本
/// 将 Unicode 字符映射为 USB HID 键码序列（含 Shift 修饰）
- (void)_injectStringViaKeyEvents:(NSString *)text {
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar ch = [text characterAtIndex:i];
        HIDKeyPress press = [self _hidSequenceForChar:ch];

        if (press.keyCode == 0) {
            // 无法映射的字符，跳过
            continue;
        }

        // 按需按下修饰键
        if (press.modifierDown != 0) {
            _postKey(press.modifierDown, 1);
            [NSThread sleepForTimeInterval:0.005];
        }

        // 按下主键
        _postKey(press.keyCode, 1);
        [NSThread sleepForTimeInterval:0.005];

        // 弹起主键
        _postKey(press.keyCode, 0);
        [NSThread sleepForTimeInterval:0.005];

        // 弹起修饰键
        if (press.modifierDown != 0) {
            _postKey(press.modifierDown, 0);
            [NSThread sleepForTimeInterval:0.005];
        }
    }
}

/// USB HID 键盘键码映射
typedef struct {
    int keyCode;        // HID 键码
    int modifierDown;   // 需要同时按下的修饰键 (0=无, 225=LeftShift)
} HIDKeyPress;

/// USB HID 键码常量
#define HID_KEY_A      4
#define HID_KEY_Z     29
#define HID_KEY_0     39
#define HID_KEY_9     38
#define HID_KEY_SPACE 44
#define HID_KEY_ENTER 40
#define HID_KEY_ESC   41
#define HID_KEY_BKSP  42
#define HID_KEY_TAB   43
#define HID_KEY_MINUS 45   // -
#define HID_KEY_EQUAL 46   // =
#define HID_KEY_LBR   47   // [
#define HID_KEY_RBR   48   // ]
#define HID_KEY_BSLS  49   // backslash
#define HID_KEY_SEMI  51   // ;
#define HID_KEY_QUOTE 52   // '
#define HID_KEY_COMMA 54   // ,
#define HID_KEY_DOT   55   // .
#define HID_KEY_SLASH 56   // /
#define HID_KEY_1     30
#define HID_KEY_2     31
#define HID_KEY_3     32
#define HID_KEY_4     33
#define HID_KEY_5     34
#define HID_KEY_6     35
#define HID_KEY_7     36
#define HID_KEY_8     37
#define HID_KEY_GRAVE 53   // backtick
#define HID_MOD_LSHIFT 225
#define HID_MOD_RSHIFT 229

- (HIDKeyPress)_hidSequenceForChar:(unichar)ch {
    HIDKeyPress none = {0, 0};

    // 小写字母 a-z
    if (ch >= 'a' && ch <= 'z') {
        return (HIDKeyPress){HID_KEY_A + (ch - 'a'), 0};
    }
    // 大写字母 A-Z
    if (ch >= 'A' && ch <= 'Z') {
        return (HIDKeyPress){HID_KEY_A + (ch - 'A'), HID_MOD_LSHIFT};
    }
    // 数字 0-9
    if (ch >= '0' && ch <= '9') {
        if (ch == '0') return (HIDKeyPress){HID_KEY_0, 0};
        return (HIDKeyPress){HID_KEY_1 + (ch - '1'), 0};
    }
    // 空格
    if (ch == ' ') return (HIDKeyPress){HID_KEY_SPACE, 0};
    // 换行
    if (ch == '\n') return (HIDKeyPress){HID_KEY_ENTER, 0};
    // 制表符
    if (ch == '\t') return (HIDKeyPress){HID_KEY_TAB, 0};
    // 退格
    if (ch == '\b') return (HIDKeyPress){HID_KEY_BKSP, 0};

    // 常用符号 (US 键盘布局)
    switch (ch) {
        case '!':  return (HIDKeyPress){HID_KEY_1, HID_MOD_LSHIFT};    // !
        case '@':  return (HIDKeyPress){HID_KEY_2, HID_MOD_LSHIFT};    // @
        case '#':  return (HIDKeyPress){HID_KEY_3, HID_MOD_LSHIFT};    // #
        case '$':  return (HIDKeyPress){HID_KEY_4, HID_MOD_LSHIFT};    // $
        case '%':  return (HIDKeyPress){HID_KEY_5, HID_MOD_LSHIFT};    // %
        case '^':  return (HIDKeyPress){HID_KEY_6, HID_MOD_LSHIFT};    // ^
        case '&':  return (HIDKeyPress){HID_KEY_7, HID_MOD_LSHIFT};    // &
        case '*':  return (HIDKeyPress){HID_KEY_8, HID_MOD_LSHIFT};    // *
        case '(':  return (HIDKeyPress){HID_KEY_9, HID_MOD_LSHIFT};    // (
        case ')':  return (HIDKeyPress){HID_KEY_0, HID_MOD_LSHIFT};    // )
        case '-':  return (HIDKeyPress){HID_KEY_MINUS, 0};             // -
        case '_':  return (HIDKeyPress){HID_KEY_MINUS, HID_MOD_LSHIFT};// _
        case '=':  return (HIDKeyPress){HID_KEY_EQUAL, 0};             // =
        case '+':  return (HIDKeyPress){HID_KEY_EQUAL, HID_MOD_LSHIFT};// +
        case '[':  return (HIDKeyPress){HID_KEY_LBR, 0};               // [
        case '{':  return (HIDKeyPress){HID_KEY_LBR, HID_MOD_LSHIFT};  // {
        case ']':  return (HIDKeyPress){HID_KEY_RBR, 0};               // ]
        case '}':  return (HIDKeyPress){HID_KEY_RBR, HID_MOD_LSHIFT};  // }
        case '\\': return (HIDKeyPress){HID_KEY_BSLS, 0};              // backslash
        case '|':  return (HIDKeyPress){HID_KEY_BSLS, HID_MOD_LSHIFT}; // |
        case ';':  return (HIDKeyPress){HID_KEY_SEMI, 0};              // ;
        case ':':  return (HIDKeyPress){HID_KEY_SEMI, HID_MOD_LSHIFT}; // :
        case '\'': return (HIDKeyPress){HID_KEY_QUOTE, 0};             // '
        case '"':  return (HIDKeyPress){HID_KEY_QUOTE, HID_MOD_LSHIFT};// "
        case ',':  return (HIDKeyPress){HID_KEY_COMMA, 0};             // ,
        case '<':  return (HIDKeyPress){HID_KEY_COMMA, HID_MOD_LSHIFT};// <
        case '.':  return (HIDKeyPress){HID_KEY_DOT, 0};               // .
        case '>':  return (HIDKeyPress){HID_KEY_DOT, HID_MOD_LSHIFT};  // >
        case '/':  return (HIDKeyPress){HID_KEY_SLASH, 0};             // /
        case '?':  return (HIDKeyPress){HID_KEY_SLASH, HID_MOD_LSHIFT};// ?
        case '`':  return (HIDKeyPress){HID_KEY_GRAVE, 0};             // `
        case '~':  return (HIDKeyPress){HID_KEY_GRAVE, HID_MOD_LSHIFT};// ~
    }

    // 中文字符等无法直接映射 —— 返回空
    return none;
}

#pragma mark - 硬件按键

- (void)pressHome {
    _postKey(TSKeyCodeHome, 1);
    [NSThread sleepForTimeInterval:0.05];
    _postKey(TSKeyCodeHome, 0);
}

- (void)pressLock {
    // 优先使用 GSEventLockDevice
    _loadGraphicsServices();
    if (_GSEventLockDevice) {
        _GSEventLockDevice();
        return;
    }
    // 回退: 发送锁屏按键
    _postKey(TSKeyCodeLock, 1);
    [NSThread sleepForTimeInterval:0.05];
    _postKey(TSKeyCodeLock, 0);
}

- (void)pressVolumeUp {
    _postKey(TSKeyCodeVolumeUp, 1);
    [NSThread sleepForTimeInterval:0.05];
    _postKey(TSKeyCodeVolumeUp, 0);
}

- (void)pressVolumeDown {
    _postKey(TSKeyCodeVolumeDown, 1);
    [NSThread sleepForTimeInterval:0.05];
    _postKey(TSKeyCodeVolumeDown, 0);
}

- (void)doublePressHome {
    [self pressHome];
    [NSThread sleepForTimeInterval:0.15];
    [self pressHome];
}

@end
