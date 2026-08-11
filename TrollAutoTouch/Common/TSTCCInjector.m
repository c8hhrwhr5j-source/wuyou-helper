//
//  TSTCCInjector.m
//  TrollAutoTouch
//
//  原理：iOS 的 TCC.db 就是一个 SQLite 数据库，位于
//  /var/mobile/Library/TCC/TCC.db，拥有者为 mobile (UID 501)。
//  巨魔签名应用以 no-sandbox 运行在 mobile 身份下，可直接读写该文件。
//
//  access 表关键字段：
//    auth_value: 0=拒绝, 2=允许, 3=受限
//    client:     请求服务的 Bundle ID
//    client_type: 0 (= Bundle ID)
//

#import "TSTCCInjector.h"
#import <sqlite3.h>

static const char *kTCCServices[] = {
    "kTCCServiceMicrophone",
    "kTCCServiceCamera",
    "kTCCServiceLocation",
    "kTCCServiceBluetoothAlways",
    "kTCCServiceMotion",
    "kTCCServiceAddressBook",
    "kTCCServiceCalendar",
    "kTCCServiceReminders",
    "kTCCServicePhotos",
    "kTCCServiceSpeechRecognition",
    "kTCCServiceWillow",        // HomeKit
    "kTCCServiceSiri",
    "kTCCServiceUserTracking",
    "kTCCServiceMediaLibrary",
};
static const int kTCCServiceCount = sizeof(kTCCServices) / sizeof(kTCCServices[0]);

@implementation TSTCCInjector

+ (void)injectAllPermissions {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 异步执行，不阻塞主线程启动
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            [self doInject];
        });
    });
}

+ (void)doInject {
    NSString *dbPath = @"/var/mobile/Library/TCC/TCC.db";
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!bundleID.length) return;

    // 先确认文件可访问
    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) {
        NSLog(@"[TCCInject] TCC.db not found at %@", dbPath);
        return;
    }

    sqlite3 *db = NULL;
    int rc = sqlite3_open([dbPath UTF8String], &db);
    if (rc != SQLITE_OK || !db) {
        NSLog(@"[TCCInject] sqlite3_open failed: %d", rc);
        return;
    }

    // 开启 WAL（不阻塞 tccd 并发写入）
    sqlite3_exec(db, "PRAGMA journal_mode=WAL;", NULL, NULL, NULL);

    // 尝试完整列 INSERT，失败则回退到最小列
    const char *sqlFull =
        "INSERT OR REPLACE INTO access "
        "(service, client, client_type, auth_value, auth_reason, auth_version, "
        " csreq, policy_id, indirect_object_identifier, indirect_object_identifier_type, flags) "
        "VALUES (?1, ?2, 0, 2, 3, 1, NULL, NULL, NULL, NULL, 0);";

    const char *sqlMin =
        "INSERT OR REPLACE INTO access "
        "(service, client, client_type, auth_value, auth_reason, auth_version) "
        "VALUES (?1, ?2, 0, 2, 3, 1);";

    int injected = 0;
    for (int i = 0; i < kTCCServiceCount; i++) {
        const char *service = kTCCServices[i];

        sqlite3_stmt *stmt = NULL;
        rc = sqlite3_prepare_v2(db, sqlFull, -1, &stmt, NULL);
        if (rc != SQLITE_OK) {
            // 列数不匹配（iOS 版本差异），用最小列重试
            rc = sqlite3_prepare_v2(db, sqlMin, -1, &stmt, NULL);
        }
        if (rc == SQLITE_OK && stmt) {
            sqlite3_bind_text(stmt, 1, service, -1, SQLITE_STATIC);
            sqlite3_bind_text(stmt, 2, [bundleID UTF8String], -1, SQLITE_STATIC);
            rc = sqlite3_step(stmt);
            if (rc == SQLITE_DONE) injected++;
            else  NSLog(@"[TCCInject] %s → rc=%d err=%s", service, rc, sqlite3_errmsg(db));
            sqlite3_finalize(stmt);
        }
    }

    sqlite3_close(db);
    NSLog(@"[TCCInject] %d/%d services registered for %@", injected, kTCCServiceCount, bundleID);

    // 可选：踢 tccd 让变更立即生效（部分 iOS 版本需要）
    // killall tccd 并非必须，因为 Settings 读取的是同一份 db
}
@end
