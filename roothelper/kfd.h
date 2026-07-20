//
//  kfd.h
//  iOS kernel fd exploit — task_for_pid(0) 内核内存读写提权
//
//  == 为什么用 task_for_pid(0) 而不是 physpuppet/smith/landa? ==
//  TrollStore 签名的应用拥有以下关键 entitlements：
//    - get-task-allow          → 允许 task_for_pid
//    - platform-application    → 以 platform 身份运行
//    - com.apple.system-task-ports → 允许获取内核 task 端口
//  task_for_pid(0) 可以直接获取 kernel_task 的 mach port，
//  然后通过 mach_vm_read / mach_vm_write 直接读写内核内存。
//  不需要任何内核漏洞（physpuppet/smith/landa/cicuta_virosa），
//  适用范围更广且不依赖系统版本。
//
//  == 提权流程 ==
//  1. task_for_pid(0) → kernel_task mach port
//  2. kread64 / kwrite64 读写内核内存
//  3. 遍历 allproc 链表找到目标进程的 proc 结构
//  4. 修改 ucred.cr_uid/cr_ruid/cr_svuid/cr_groups[0] = 0
//  5. setuid(0) 让用户态也感知 root
//
//  运行环境: TrollStore iOS 14-17, arm64
//

#ifndef KFD_H
#define KFD_H

#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>
#include <mach/mach.h>

// ---- 内核版本信息 ----
typedef struct {
    uint32_t major;
    uint32_t minor;
    uint32_t patch;
    char     build[32];
} kfd_osversion_t;

// ---- kfd 状态 ----
typedef enum {
    KFD_ERR_NONE = 0,
    KFD_ERR_OPEN_FAILED,
    KFD_ERR_NO_SUITABLE_TECHNIQUE,
    KFD_ERR_UNSUPPORTED_OS,
    KFD_ERR_KERNEL_RW_FAILED,
    KFD_ERR_CRED_PATCH_FAILED,
} kfd_error_t;

// ---- 公开 API ----

/// 初始化 kfd 内部数据结构（偏移表、版本检测等），返回 0 表示成功。
int kfd_init(void);

/// 尝试通过 task_for_pid(0) 获取内核 r/w 能力，返回 0 表示成功。
int kfd_open(void);

/// 将当前进程提权为 UID=0（root），通过修改内核 ucred 结构实现，返回 0 表示成功。
int kfd_get_root(void);

/// 关闭 kfd 句柄并清理。
void kfd_close(void);

/// 完整的提权流程: init → open → get_root，返回 0 表示成功。
/// 成功时当前进程的 EUID 已变为 0。
int kfd_escalate(void);

/// 提权指定 PID 的进程（通过 allproc 链表找到并修改其 ucred）。
/// 需要先 kfd_open 成功。
int kfd_escalate_pid(pid_t pid);

/// 检查当前进程是否已经获得 root 权限。
/// 返回 1 = 已是 root, 0 = 不是。
int kfd_is_root(void);

/// 获取最后一次错误描述。
const char *kfd_get_error(void);

#endif // KFD_H
