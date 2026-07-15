//
//  offsets.h
//  内核偏移量数据库 — iOS 15.0 ~ 18.x
//
//  每个版本需要: allproc, our_proc, trustcache, vm_map, kernel_task 等
//  注意: 偏移会随版本/机型变化，以下为参考值，基于公开资料整理
//

#ifndef OFFSETS_H
#define OFFSETS_H

#include "kfd.h"
#include <stdint.h>
#include <string.h>

// ---- 每版本偏移结构 ----
typedef struct {
    const char   *build;          // 内核 build 号
    uint64_t      allproc;
    uint64_t      kernproc;       // kernel_task 的 proc 地址
    uint64_t      roothash;
    uint64_t      trustcache;
    uint64_t      osboolean_true;
    uint64_t      osboolean_false;
    uint64_t      osunserializexml;
    uint64_t      smalloc;
    uint64_t      add_x0_x0_0x40_ret;
} kfd_offsets_t;

// ---- 公开 API ----

/// 根据 osversion 匹配最合适的偏移表，返回 NULL 表示不支持。
const kfd_offsets_t *offsets_match(const kfd_osversion_t *ver);

/// 打印偏移信息到 stdout。
void offsets_print(const kfd_offsets_t *off, const kfd_osversion_t *ver);

#endif // OFFSETS_H
