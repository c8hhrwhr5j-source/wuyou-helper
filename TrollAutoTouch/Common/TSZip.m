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

@end
