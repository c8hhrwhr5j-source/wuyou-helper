//
//  kfd.h
//  roothelper — kfd 内核提权模块
//
//  kfd (kernel file descriptor) exploit:
//  利用 IOSurface / puaf_landa 获取内核读写原语，
//  找到当前进程 proc/ucred 并提权为 root (uid=0, gid=0)
//

#ifndef KFD_H
#define KFD_H

#include <stdint.h>
#include <stdbool.h>

// ============================================================
// 公共 API
// ============================================================

/// 初始化 kfd 漏洞利用，获取内核读写能力
/// 返回 0 成功，非 0 失败
int kfd_init(void);

/// 将当前进程提权为 root (uid=0, gid=0, svuid=0)
/// 必须先调用 kfd_init() 成功
/// 返回 0 成功，非 0 失败
int kfd_get_root(void);

/// 清理 kfd 资源
void kfd_cleanup(void);

/// 获取 kfd 信息（调试用）
void kfd_print_info(void);

// ============================================================
// 内部：内核读写原语（仅供内部使用）
// ============================================================

/// 内核 32 位读
uint32_t kread32(uint64_t kaddr);

/// 内核 64 位读
uint64_t kread64(uint64_t kaddr);

/// 内核 32 位写
void kwrite32(uint64_t kaddr, uint32_t val);

/// 内核 64 位写
void kwrite64(uint64_t kaddr, uint64_t val);

/// 内核任意大小读
void kread_buf(uint64_t kaddr, void *buf, size_t len);

/// 内核任意大小写
void kwrite_buf(uint64_t kaddr, const void *buf, size_t len);

#endif // KFD_H
