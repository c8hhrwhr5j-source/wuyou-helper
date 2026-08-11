//
//  TSTCCRequestor.m
//  TrollAutoTouch
//
//  通过真实调用 iOS 隐私 API 来注册 TCC.db 条目，
//  从而在 Settings > 隐私 列表中显示对应服务。
//
//  每次请求间隔 0.6s，避免权限弹窗叠加导致用户困惑。
//

#import "TSTCCRequestor.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <CoreMotion/CoreMotion.h>
#import <Contacts/Contacts.h>
#import <EventKit/EventKit.h>
#import <Photos/Photos.h>
#import <Speech/Speech.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <HomeKit/HomeKit.h>
#import <Intents/Intents.h>
#import <AdSupport/AdSupport.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UserNotifications/UserNotifications.h>

static NSString *const kTCCDoneKey = @"com.TrollAutoTouch.TCCRequestedOnce";

@implementation TSTCCRequestor

+ (void)requestAllPermissionsIfNeeded {
    // 仅首次启动执行
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kTCCDoneKey]) return;
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kTCCDoneKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // 延时启动，避免在 App 初始化时卡主线程
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self performRequests];
    });
}

+ (void)performRequests {
    [self request:kAudio at:0.0];
    [self request:kCamera at:0.6];
    [self request:kLocation at:1.2];
    [self request:kBluetooth at:1.8];
    [self request:kMotion at:2.4];
    [self request:kContacts at:3.0];
    [self request:kCalendars at:3.6];
    [self request:kReminders at:4.2];
    [self request:kPhotos at:4.8];
    [self request:kSpeech at:5.4];
    [self request:kBiometrics at:6.0];
    [self request:kHomeKit at:6.6];
    [self request:kSiri at:7.2];
    [self request:kTracking at:7.8];
    [self request:kMediaLibrary at:8.4];
    [self request:kNotifications at:9.0];
}

// ── 各服务请求 ──

static NSString *const kAudio       = @"Audio";        // TCCServiceMicrophone
static NSString *const kCamera      = @"Camera";       // TCCServiceCamera
static NSString *const kLocation    = @"Location";     // TCCServiceLocation
static NSString *const kBluetooth   = @"Bluetooth";    // TCCServiceBluetoothAlways
static NSString *const kMotion      = @"Motion";       // TCCServiceMotion
static NSString *const kContacts    = @"Contacts";     // TCCServiceAddressBook
static NSString *const kCalendars   = @"Calendars";    // TCCServiceCalendar
static NSString *const kReminders   = @"Reminders";    // TCCServiceReminders
static NSString *const kPhotos      = @"Photos";       // TCCServicePhotos
static NSString *const kSpeech      = @"Speech";       // TCCServiceSpeechRecognition
static NSString *const kBiometrics  = @"Biometrics";   // TCCServiceFaceID
static NSString *const kHomeKit     = @"HomeKit";      // TCCServiceWillow
static NSString *const kSiri        = @"Siri";         // TCCServiceSiri
static NSString *const kTracking    = @"Tracking";     // TCCServiceUserTracking
static NSString *const kMediaLibrary= @"MediaLibrary"; // TCCServiceMediaLibrary
static NSString *const kNotifications = @"Notifications";

+ (void)request:(NSString *)service at:(NSTimeInterval)delay {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([service isEqualToString:kAudio])          [self reqAudio];
        else if ([service isEqualToString:kCamera])      [self reqCamera];
        else if ([service isEqualToString:kLocation])    [self reqLocation];
        else if ([service isEqualToString:kBluetooth])   [self reqBluetooth];
        else if ([service isEqualToString:kMotion])      [self reqMotion];
        else if ([service isEqualToString:kContacts])    [self reqContacts];
        else if ([service isEqualToString:kCalendars])   [self reqCalendars];
        else if ([service isEqualToString:kReminders])   [self reqReminders];
        else if ([service isEqualToString:kPhotos])      [self reqPhotos];
        else if ([service isEqualToString:kSpeech])      [self reqSpeech];
        else if ([service isEqualToString:kBiometrics])  [self reqBiometrics];
        else if ([service isEqualToString:kHomeKit])     [self reqHomeKit];
        else if ([service isEqualToString:kSiri])        [self reqSiri];
        else if ([service isEqualToString:kTracking])    [self reqTracking];
        else if ([service isEqualToString:kMediaLibrary]) [self reqMediaLib];
        else if ([service isEqualToString:kNotifications]) [self reqNotifications];
    });
}

+ (void)reqAudio {
    [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {}];
}

+ (void)reqCamera {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {}];
}

static CLLocationManager *locMgr = nil;
+ (void)reqLocation {
    locMgr = [[CLLocationManager alloc] init];
    [locMgr requestWhenInUseAuthorization];
    // 保活：2 秒后释放（弹窗期间必须持有）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        locMgr = nil;
    });
}

static CBCentralManager *cbc = nil;
+ (void)reqBluetooth {
    // 触发 TCCServiceBluetoothAlways 弹窗
    cbc = [[CBCentralManager alloc] initWithDelegate:nil queue:nil options:@{
        CBCentralManagerOptionShowPowerAlertKey: @NO
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        cbc = nil;
    });
}

static CMMotionActivityManager *motMgr = nil;
+ (void)reqMotion {
    motMgr = [[CMMotionActivityManager alloc] init];
    [motMgr queryActivityStartingFromDate:[NSDate date] toDate:[NSDate date]
                                  toQueue:[NSOperationQueue mainQueue]
                              withHandler:^(NSArray *activities, NSError *err) {}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        motMgr = nil;
    });
}

+ (void)reqContacts {
    CNContactStore *store = [[CNContactStore alloc] init];
    [store requestAccessForEntityType:CNEntityTypeContacts completionHandler:^(BOOL granted, NSError *err) {}];
}

+ (void)reqCalendars {
    EKEventStore *store = [[EKEventStore alloc] init];
    if (@available(iOS 17.0, *)) {
        [store requestFullAccessToEventsWithCompletion:^(BOOL granted, NSError *err) {}];
    } else {
        [store requestAccessToEntityType:EKEntityTypeEvent completion:^(BOOL granted, NSError *err) {}];
    }
}

+ (void)reqReminders {
    EKEventStore *store = [[EKEventStore alloc] init];
    if (@available(iOS 17.0, *)) {
        [store requestFullAccessToRemindersWithCompletion:^(BOOL granted, NSError *err) {}];
    } else {
        [store requestAccessToEntityType:EKEntityTypeReminder completion:^(BOOL granted, NSError *err) {}];
    }
}

+ (void)reqPhotos {
    if (@available(iOS 14, *)) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite
                                                   handler:^(PHAuthorizationStatus status) {}];
    } else {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {}];
    }
}

+ (void)reqSpeech {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {}];
}

+ (void)reqBiometrics {
    LAContext *ctx = [[LAContext alloc] init];
    NSError *err = nil;
    [ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&err];
    // 不真正 evaluate，避免弹窗干扰。仅 query 就足以触发 FaceID 行。
}

+ (void)reqHomeKit {
    HMHomeManager *mgr = [[HMHomeManager alloc] init];
    // 保持引用 1 秒
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        (void)mgr;
    });
}

+ (void)reqSiri {
    [INPreferences requestSiriAuthorization:^(INSiriAuthorizationStatus status) {}];
}

+ (void)reqTracking {
    if (@available(iOS 14, *)) {
        // ATTrackingManager 必须在主线程，且需 Info.plist 声明
        [self compatRequestTracking];
    }
}

+ (void)compatRequestTracking NS_EXTENSION_UNAVAILABLE("Disallowed in extensions") {
    // ATT 是 swift-only framework? No, it has ObjC API
    // Use performSelector to avoid link-time error on older iOS
    Class ATT = NSClassFromString(@"ATTrackingManager");
    if (ATT) {
        SEL sel = NSSelectorFromString(@"requestTrackingAuthorizationWithCompletionHandler:");
        NSMethodSignature *sig = [ATT methodSignatureForSelector:sel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:ATT];
            [inv setSelector:sel];
            void(^cb)(NSUInteger) = ^(NSUInteger status){};
            [inv setArgument:&cb atIndex:2];
            [inv invoke];
        }
    }
}

+ (void)reqMediaLib {
    [MPMediaLibrary requestAuthorization:^(MPMediaLibraryAuthorizationStatus status) {}];
}

+ (void)reqNotifications {
    [[UNUserNotificationCenter currentNotificationCenter]
     requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionBadge | UNAuthorizationOptionSound)
                   completionHandler:^(BOOL granted, NSError *err) {}];
}

@end
