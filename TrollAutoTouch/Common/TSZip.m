//
//  TSZip.m
//  AutoTouc
//
//  极简 ZIP 解压器(见 TSZip.h)。解析流程:
//    EOCD(结尾扫描签名) → 中央目录(逐条校验名字/大小/偏移)
//    → 本地文件头(定位数据起点) → method 0 直接拷贝 / method 8 inflate
//

#import "TSZip.h"
#import <zlib.h>

// 单文件最大 128MB、压缩前总量最大 512MB, 防止异常包占用内存
static const uint64_t kMaxEntrySize   = 128ull * 1024 * 1024;
static const uint64_t kMaxTotalSize   = 512ull * 1024 * 1024;
static const uint32_t kMaxEntryCount  = 4096;

// ZIP 本地小端整数读取
static inline uint16_t ts_rd16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}
static inline uint32_t ts_rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static BOOL ts_validEntryName(NSString *name) {
    if (name.length == 0) return NO;
    // 绝对路径 / 盘符 / 反斜杠 / 顶层 ~ 一律拒绝
    if ([name hasPrefix:@"/"] || [name hasPrefix:@"~"] ||
        [name containsString:@"\\"] || [name containsString:@":"]) {
        return NO;
    }
    for (NSString *comp in [name componentsSeparatedByString:@"/"]) {
        if ([comp isEqualToString:@".."]) return NO;   // 路径穿越
    }
    return YES;
}

// ── ZIP 打包(method 0 stored)所需的小端写入 / 时间戳 / 收集辅助 ──
static inline void ts_w16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
}
static inline void ts_w32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

// NSDate → DOS 时间/日期 (ZIP 头用)
static void ts_dosDateTime(NSDate *date, uint16_t *dosTime, uint16_t *dosDate) {
    NSDateComponents *c = [[NSCalendar currentCalendar]
        components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                   NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond
          fromDate:(date ?: [NSDate date])];
    NSInteger y = c.year;
    if (y < 1980) y = 1980;
    if (y > 2107) y = 2107;
    if (dosTime) *dosTime = (uint16_t)((c.hour << 11) | (c.minute << 5) | (c.second >> 1));
    if (dosDate) *dosDate = (uint16_t)((((y - 1980) & 0x7F) << 9) | (c.month << 5) | c.day);
}

// 递归收集目录下所有文件 → {name(相对路径), data, mtime}
static void ts_collectDirFiles(NSFileManager *fm, NSString *dir, NSString *root,
                               NSMutableArray<NSDictionary *> *out) {
    NSArray *names = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSString *rootPrefix = [root stringByAppendingString:@"/"];
    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;                      // 隐藏文件/.git 等不入包
        if ([name isEqualToString:@"Thumbs.db"] || [name isEqualToString:@"desktop.ini"]) continue;
        NSString *full = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
        if (isDir) { ts_collectDirFiles(fm, full, root, out); continue; }
        NSData *d = [NSData dataWithContentsOfFile:full];
        if (!d) continue;
        NSString *rel = [full hasPrefix:rootPrefix] ? [full substringFromIndex:rootPrefix.length] : name;
        NSDictionary *attr = [fm attributesOfItemAtPath:full error:nil];
        [out addObject:@{
            @"name"  : rel,
            @"data"  : d,
            @"mtime" : attr[NSFileModificationDate] ?: [NSDate date],
        }];
    }
}

@implementation TSZip

+ (BOOL)unzipData:(NSData *)data toDirectory:(NSString *)destDir error:(NSString *_Nullable *_Nullable)error {
    // 注意: ARC 下 goto 不能跳过 __strong 变量的初始化,
    // 因此所有强引用局部变量必须在本方法最前面声明。
    NSString *errMsg = nil;
    NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    const uint8_t *d = data.bytes;
    NSUInteger len = data.length;

    if (len < 22) { errMsg = @"数据过短, 不是有效的 zip"; goto done; }

    // ── 1. 从结尾找 EOCD 签名 0x06054b50 ──
    NSInteger eocdPos = -1;
    NSUInteger scanFloor = (len > 65557) ? (len - 65557) : 0;
    NSUInteger i = len - 22;
    for (;;) {
        if (i < scanFloor) break;
        if (ts_rd32(d + i) == 0x06054b50) {
            NSUInteger commentLen = ts_rd16(d + i + 20);
            if (i + 22 + commentLen == len) { eocdPos = (NSInteger)i; break; }
        }
        if (i == 0) break;
        i--;
    }
    if (eocdPos < 0) { errMsg = @"未找到 zip 结束标记(EOCD)"; goto done; }

    uint32_t totalEntries = ts_rd16(d + eocdPos + 10);
    uint32_t cdSize       = ts_rd32(d + eocdPos + 12);
    uint32_t cdOffset     = ts_rd32(d + eocdPos + 16);
    if (totalEntries > kMaxEntryCount) { errMsg = @"包内文件数过多"; goto done; }
    if ((uint64_t)cdOffset + cdSize > len) { errMsg = @"中央目录越界"; goto done; }

    // ── 2. 解析中央目录(先全量校验, 再落地, 避免半途写坏目标目录) ──
    NSUInteger p = cdOffset;
    uint64_t totalUncompressed = 0;

    for (uint32_t e = 0; e < totalEntries; e++) {
        if (p + 46 > len) { errMsg = @"中央目录越界"; goto done; }
        if (ts_rd32(d + p) != 0x02014b50) { errMsg = @"中央目录签名损坏"; goto done; }

        uint16_t flags   = ts_rd16(d + p + 8);
        uint16_t method  = ts_rd16(d + p + 10);
        uint32_t crc     = ts_rd32(d + p + 16);
        uint32_t csize   = ts_rd32(d + p + 20);
        uint32_t usize   = ts_rd32(d + p + 24);
        uint16_t nameLen = ts_rd16(d + p + 28);
        uint16_t extra   = ts_rd16(d + p + 30);
        uint16_t comment = ts_rd16(d + p + 32);
        uint32_t localOff= ts_rd32(d + p + 42);

        // 带 data descriptor(flag bit3)的包: 我们自己的打包器不产生, 直接拒绝
        if (flags & 0x0008) { errMsg = @"暂不支持带 data descriptor 的 zip"; goto done; }
        if (method != 0 && method != 8) { errMsg = @"不支持的压缩方式"; goto done; }
        if ((uint64_t)usize > kMaxEntrySize || (uint64_t)csize > kMaxEntrySize) {
            errMsg = @"包内存在超大文件"; goto done;
        }

        NSString *name = [[NSString alloc] initWithBytes:d + p + 46 length:nameLen encoding:NSUTF8StringEncoding];
        if (!name) { errMsg = @"文件名编码非法"; goto done; }
        if (!ts_validEntryName(name)) { errMsg = @"包内含非法路径"; goto done; }

        totalUncompressed += usize;
        if (totalUncompressed > kMaxTotalSize) { errMsg = @"解压总大小超限"; goto done; }

        [files addObject:@{
            @"name"   : name,
            @"dir"    : @([name hasSuffix:@"/"]),
            @"method" : @(method),
            @"crc"    : @(crc),
            @"csize"  : @(csize),
            @"usize"  : @(usize),
            @"offset" : @(localOff),
        }];
        p += 46 + nameLen + extra + comment;
    }

    // ── 3. 逐个落地 ──
    if (![fm fileExistsAtPath:destDir]) {
        if (![fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil]) {
            errMsg = @"创建目标目录失败"; goto done;
        }
    }

    for (NSDictionary *file in files) {
        NSString *name = file[@"name"];
        BOOL isDir = [file[@"dir"] boolValue];
        uint16_t method = [file[@"method"] unsignedShortValue];
        uint32_t crc   = [file[@"crc"] unsignedIntValue];
        uint32_t csize = [file[@"csize"] unsignedIntValue];
        uint32_t usize = [file[@"usize"] unsignedIntValue];
        NSUInteger lo  = [file[@"offset"] unsignedIntegerValue];

        // 目标路径逐级拼接, 每级都建目录; 已过滤掉 .. / 绝对路径
        NSString *dest = destDir;
        NSArray<NSString *> *comps = [name componentsSeparatedByString:@"/"];
        for (NSUInteger ci = 0; ci < comps.count; ci++) {
            NSString *comp = comps[ci];
            if (comp.length == 0 || [comp isEqualToString:@"."]) continue;
            dest = [dest stringByAppendingPathComponent:comp];
            BOOL lastComp = (ci == comps.count - 1);
            if (isDir || !lastComp) {
                // 目录项或文件父目录: 确保存在
                if (![fm fileExistsAtPath:dest]) {
                    if (![fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil]) {
                        errMsg = [NSString stringWithFormat:@"创建目录失败: %@", dest]; goto done;
                    }
                }
                if (isDir) break;  // 目录项到此为止
            } else {
                // 文件项: 定位数据起点
                if (lo + 30 > len) { errMsg = @"本地文件头越界"; goto done; }
                if (ts_rd32(d + lo) != 0x04034b50) { errMsg = @"本地文件头损坏"; goto done; }
                uint16_t ln   = ts_rd16(d + lo + 26);
                uint16_t lex  = ts_rd16(d + lo + 28);
                NSUInteger dataStart = lo + 30 + ln + lex;
                if (dataStart + csize > len) { errMsg = @"文件数据越界"; goto done; }

                NSData *out = nil;
                if (usize == 0) {
                    out = [NSData data];
                } else if (method == 0) {
                    if (csize != usize) { errMsg = @"stored 条目长度不一致"; goto done; }
                    out = [NSData dataWithBytes:d + dataStart length:csize];
                } else {  // method 8: raw deflate
                    z_stream zs;
                    memset(&zs, 0, sizeof(zs));
                    if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) { errMsg = @"inflate 初始化失败"; goto done; }
                    NSMutableData *inflated = [NSMutableData dataWithLength:usize];
                    zs.next_in   = (Bytef *)(d + dataStart);
                    zs.avail_in  = (uInt)csize;
                    zs.next_out  = (Bytef *)inflated.mutableBytes;
                    zs.avail_out = (uInt)usize;
                    int rz = inflate(&zs, Z_FINISH);
                    inflateEnd(&zs);
                    if (rz != Z_STREAM_END || zs.total_out != usize) {
                        errMsg = [NSString stringWithFormat:@"数据解压失败: %@", name]; goto done;
                    }
                    out = inflated;
                }

                // CRC 校验(用系统 zlib, 防传输/解压错误)
                if (out.length > 0) {
                    uLong check = crc32(0L, out.bytes, (uInt)out.length);
                    if ((uint32_t)check != crc) { errMsg = [NSString stringWithFormat:@"CRC 校验失败: %@", name]; goto done; }
                }
                if (![out writeToFile:dest atomically:YES]) {
                    errMsg = [NSString stringWithFormat:@"写入文件失败: %@", dest]; goto done;
                }
            }
        }
    }

done:
    if (error && errMsg) *error = errMsg;
    return errMsg == nil;
}

+ (nullable NSData *)zipDataFromDirectory:(NSString *)dir error:(NSString *_Nullable *_Nullable)error {
    // 注意: ARC 下 goto 不能跳过 __strong 变量的初始化,
    // 因此所有强引用局部变量必须在本方法最前面声明。
    NSString *errMsg = nil;
    NSData *result = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSDictionary *> *files = nil;
    NSMutableData *local = nil;     // 各文件本地头+数据
    NSMutableData *central = nil;   // 中央目录
    NSMutableData *zip = nil;
    uint32_t offset = 0;

    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
        errMsg = @"目录不存在或不是文件夹";
        goto done;
    }

    files = [NSMutableArray array];
    ts_collectDirFiles(fm, dir, dir, files);
    if (files.count == 0) {
        errMsg = @"目录中没有可打包的文件";
        goto done;
    }
    if (files.count > kMaxEntryCount) {
        errMsg = @"文件数超过上限, 无法打包";
        goto done;
    }

    local = [NSMutableData data];
    central = [NSMutableData data];

    for (NSDictionary *f in files) {
        NSData *d = f[@"data"];
        NSData *nameBytes = [f[@"name"] dataUsingEncoding:NSUTF8StringEncoding];
        if (!nameBytes) { errMsg = @"文件名编码失败"; goto done; }
        uLong crc = crc32(0L, d.bytes, (uInt)d.length);
        uint16_t dosT = 0, dosD = 0;
        ts_dosDateTime(f[@"mtime"], &dosT, &dosD);

        uint8_t lh[30];
        ts_w32(lh,      0x04034b50);
        ts_w16(lh + 4,  20);          // version needed
        ts_w16(lh + 6,  0x0800);      // UTF-8 文件名标志
        ts_w16(lh + 8,  0);           // method 0 = stored
        ts_w16(lh + 10, dosT);
        ts_w16(lh + 12, dosD);
        ts_w32(lh + 14, (uint32_t)crc);
        ts_w32(lh + 18, (uint32_t)d.length);   // compressed = original (stored)
        ts_w32(lh + 22, (uint32_t)d.length);
        ts_w16(lh + 26, (uint16_t)nameBytes.length);
        ts_w16(lh + 28, 0);
        [local appendBytes:lh length:30];
        [local appendData:nameBytes];
        [local appendData:d];

        uint8_t cd[46];
        ts_w32(cd,      0x02014b50);
        ts_w16(cd + 4,  20);          // version made by
        ts_w16(cd + 6,  20);
        ts_w16(cd + 8,  0x0800);
        ts_w16(cd + 10, 0);           // method 0
        ts_w16(cd + 12, dosT);
        ts_w16(cd + 14, dosD);
        ts_w32(cd + 16, (uint32_t)crc);
        ts_w32(cd + 20, (uint32_t)d.length);
        ts_w32(cd + 24, (uint32_t)d.length);
        ts_w16(cd + 28, (uint16_t)nameBytes.length);
        ts_w16(cd + 30, 0);           // extra len
        ts_w16(cd + 32, 0);           // comment len
        ts_w16(cd + 34, 0);           // disk start
        ts_w16(cd + 36, 0);           // internal attrs
        ts_w32(cd + 38, 0);           // external attrs
        ts_w32(cd + 42, offset);
        [central appendBytes:cd length:46];
        [central appendData:nameBytes];

        offset += 30 + (uint32_t)nameBytes.length + (uint32_t)d.length;
    }

    zip = [local mutableCopy];
    [zip appendData:central];
    uint8_t eocd[22];
    ts_w32(eocd, 0x06054b50);
    ts_w16(eocd + 4,  0);                              // disk number
    ts_w16(eocd + 6,  0);                              // central dir disk
    ts_w16(eocd + 8,  (uint16_t)files.count);          // entries this disk
    ts_w16(eocd + 10, (uint16_t)files.count);          // total entries
    ts_w32(eocd + 12, (uint32_t)central.length);       // central dir size
    ts_w32(eocd + 16, offset);                         // central dir offset
    ts_w16(eocd + 20, 0);                              // comment len
    [zip appendBytes:eocd length:22];
    result = zip;

done:
    if (error && errMsg) *error = errMsg;
    return result;
}

@end
