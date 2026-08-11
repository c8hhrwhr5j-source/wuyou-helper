//
//  TSTCCInjector.m
//  运行时直接写入 TCC.db (access + access_overrides 双表) 并重启 tccd
//
#import "TSTCCInjector.h"
#import <sqlite3.h>

#define TCC_DB_PATH "/var/mobile/Library/TCC/TCC.db"
#define BUNDLE_ID    "com.TrollAutoScript.apple"

/// 需要授予的全部 TCC 服务
static NSString * const kAllServices[] = {
    @"kTCCServiceAll",
    @"kTCCServiceAccessibility",
    @"kTCCServiceAddressBook",
    @"kTCCServiceBluetoothAlways",
    @"kTCCServiceBluetoothPeripheral",
    @"kTCCServiceCalendar",
    @"kTCCServiceCalls",
    @"kTCCServiceCamera",
    @"kTCCServiceFacebook",
    @"kTCCServiceKeyboardNetwork",
    @"kTCCServiceLiverpool",
    @"kTCCServiceLocation",
    @"kTCCServiceMediaLibrary",
    @"kTCCServiceMicrophone",
    @"kTCCServiceMotion",
    @"kTCCServiceMSO",
    @"kTCCServicePhotos",
    @"kTCCServiceReminders",
    @"kTCCServiceShareKit",
    @"kTCCServiceSinaWeibo",
    @"kTCCServiceSiri",
    @"kTCCServiceSpeechRecognition",
    @"kTCCServiceTencentWeibo",
    @"kTCCServiceTwitter",
    @"kTCCServiceUbiquity",
    @"kTCCServiceWillow",
    nil
};

/// 探测 access 表是否有 indirect_object_identifier 列 (iOS 15+ 新增)
static BOOL hasIndirectObjectColumn(sqlite3 *db) {
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, "PRAGMA table_info(access)", -1, &stmt, NULL) != SQLITE_OK) return NO;
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *name = (const char *)sqlite3_column_text(stmt, 1);
        if (name && strcmp(name, "indirect_object_identifier") == 0) {
            sqlite3_finalize(stmt);
            return YES;
        }
    }
    sqlite3_finalize(stmt);
    return NO;
}

@implementation TSTCCInjector

+ (void)grantAllPermissions {
    NSLog(@"[TCC] 开始注入 TCC 权限...");

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(TCC_DB_PATH, &db,
                        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                        NULL) != SQLITE_OK) {
        NSLog(@"[TCC] 打开 TCC.db 失败: %s", sqlite3_errmsg(db));
        if (db) sqlite3_close(db);
        return;
    }

    BOOL hasIdCol = hasIndirectObjectColumn(db);

    // 开启事务，提升写入速度
    sqlite3_exec(db, "BEGIN TRANSACTION", NULL, NULL, NULL);

    int success = 0, fail = 0;
    for (int i = 0; kAllServices[i] != nil; i++) {
        NSString *svc = kAllServices[i];
        const char *cSvc = [svc UTF8String];

        // ── access 表 ──
        char sql[1024];
        if (hasIdCol) {
            snprintf(sql, sizeof(sql),
                     "INSERT OR REPLACE INTO access ("
                     "service, client, client_type, auth_value, auth_reason, auth_version, "
                     "csreq, policy_id, indirect_object_identifier_type, "
                     "indirect_object_identifier, indirect_object_code_identity, "
                     "flags, last_modified"
                     ") VALUES ("
                     "'%s', '%s', 0, 2, 1, 1, "
                     "NULL, NULL, 0, "
                     "'UNUSED', NULL, "
                     "0, CAST(strftime('%%s','now') AS INTEGER)"
                     ")",
                     cSvc, BUNDLE_ID);
        } else {
            snprintf(sql, sizeof(sql),
                     "INSERT OR REPLACE INTO access ("
                     "service, client, client_type, auth_value, auth_reason, auth_version, "
                     "csreq, policy_id, flags, last_modified"
                     ") VALUES ("
                     "'%s', '%s', 0, 2, 1, 1, "
                     "NULL, NULL, 0, CAST(strftime('%%s','now') AS INTEGER)"
                     ")",
                     cSvc, BUNDLE_ID);
        }

        if (sqlite3_exec(db, sql, NULL, NULL, NULL) == SQLITE_OK) {
            success++;
        } else {
            fail++;
            NSLog(@"[TCC] access 写入失败 [%s]: %s", cSvc, sqlite3_errmsg(db));
        }

        // ── access_overrides 表 (iOS 14+, MDM 覆盖用) ──
        char sqlOverride[512];
        snprintf(sqlOverride, sizeof(sqlOverride),
                 "INSERT OR REPLACE INTO access_overrides "
                 "(service, client, client_type, auth_value) "
                 "VALUES ('%s', '%s', 0, 2)",
                 cSvc, BUNDLE_ID);
        sqlite3_exec(db, sqlOverride, NULL, NULL, NULL);
        // access_overrides 可能不存在于旧 iOS，忽略错误
    }

    sqlite3_exec(db, "COMMIT", NULL, NULL, NULL);
    sqlite3_close(db);

    NSLog(@"[TCC] 写入完成: 成功 %d, 失败 %d", success, fail);

    // ── 重启 tccd 强制重新加载 TCC.db ──
    NSLog(@"[TCC] 重启 tccd 使权限生效...");
    system("killall -9 tccd 2>/dev/null");

    // 等待 tccd 自动重启
    usleep(500000); // 0.5s
    NSLog(@"[TCC] TCC 权限注入完成");
}

+ (void)grantPermission:(NSString *)tccService {
    // 单个权限注入（保留接口）
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(TCC_DB_PATH, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) != SQLITE_OK) {
        NSLog(@"[TCC] 打开 TCC.db 失败");
        return;
    }

    BOOL hasIdCol = hasIndirectObjectColumn(db);

    const char *svc = [tccService UTF8String];
    char sql[1024];
    if (hasIdCol) {
        snprintf(sql, sizeof(sql),
                 "INSERT OR REPLACE INTO access ("
                 "service, client, client_type, auth_value, auth_reason, auth_version, "
                 "csreq, policy_id, indirect_object_identifier_type, "
                 "indirect_object_identifier, indirect_object_code_identity, "
                 "flags, last_modified"
                 ") VALUES ("
                 "'%s', '%s', 0, 2, 1, 1, "
                 "NULL, NULL, 0, 'UNUSED', NULL, 0, CAST(strftime('%%s','now') AS INTEGER))",
                 svc, BUNDLE_ID);
    } else {
        snprintf(sql, sizeof(sql),
                 "INSERT OR REPLACE INTO access ("
                 "service, client, client_type, auth_value, auth_reason, auth_version, "
                 "csreq, policy_id, flags, last_modified"
                 ") VALUES ("
                 "'%s', '%s', 0, 2, 1, 1, "
                 "NULL, NULL, 0, CAST(strftime('%%s','now') AS INTEGER))",
                 svc, BUNDLE_ID);
    }

    sqlite3_exec(db, sql, NULL, NULL, NULL);
    sqlite3_close(db);
    system("killall -9 tccd 2>/dev/null");
}

@end
