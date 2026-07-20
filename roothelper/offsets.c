//
//  offsets.c
//  内核偏移量数据库实现
//
//  偏移数据来源: 公开 kfd projects / 逆向工程 / 社区收集
//  iOS 15.x 主要使用 physpuppet 技术 (task_for_pid(0) 在 15.5+ 被封锁)
//  iOS 16.x 使用 physpuppet + smith 混合技术
//

#include "offsets.h"
#include <stdio.h>
#include <string.h>

// ================================================================
// 辅助宏：填充所有 physpuppet 字段为通用的 iOS 15/16/17 默认值
// 注意: zone_map/kernel_map/vm_pages 如无法静态确定，填 0 表示由 physpuppet 动态探测
// ================================================================

#define PP_DEFAULT_IOS15 \
    .zone_map          = 0xFFFFFFF008000000ULL, \
    .ipc_kobject_set   = 0, \
    .kernel_map        = 0, \
    .vm_pages          = 0, \
    .surface_zone_elem = 0x400, \
    .surface_id_shift  = 14, \
    .kernel_slide_hint = 0

#define PP_DEFAULT_IOS16 \
    .zone_map          = 0, \
    .ipc_kobject_set   = 0, \
    .kernel_map        = 0, \
    .vm_pages          = 0, \
    .surface_zone_elem = 0x400, \
    .surface_id_shift  = 14, \
    .kernel_slide_hint = 0

// ================================================================
// iOS 15.x 偏移表
// ================================================================

static const kfd_offsets_t offs_ios15_0 = {
    .build              = "19A346",
    .allproc            = 0xFFFFFFF007A3A5F0,
    .kernproc           = 0xFFFFFFF007A6B3C8,
    .roothash           = 0xFFFFFFF007A6B448,
    .trustcache         = 0xFFFFFFF007A6B748,
    .osboolean_true     = 0xFFFFFFF00728FB60,
    .osboolean_false    = 0xFFFFFFF00728FB80,
    .osunserializexml   = 0xFFFFFFF0075A3B38,
    .smalloc            = 0xFFFFFFF007A871E0,
    .add_x0_x0_0x40_ret = 0xFFFFFFF007D52F18,
    PP_DEFAULT_IOS15,
};

static const kfd_offsets_t offs_ios15_1 = {
    .build              = "19B74",
    .allproc            = 0xFFFFFFF007A585F0,
    .kernproc           = 0xFFFFFFF007A893C8,
    .roothash           = 0xFFFFFFF007A89448,
    .trustcache         = 0xFFFFFFF007A89748,
    .osboolean_true     = 0xFFFFFFF00728DB58,
    .osboolean_false    = 0xFFFFFFF00728DB78,
    .osunserializexml   = 0xFFFFFFF0075C3B00,
    .smalloc            = 0xFFFFFFF007AA5DB8,
    .add_x0_x0_0x40_ret = 0xFFFFFFF007D70F94,
    PP_DEFAULT_IOS15,
};

static const kfd_offsets_t offs_ios15_2 = {
    .build              = "19C56",
    .allproc            = 0xFFFFFFF007A71690,
    .kernproc           = 0xFFFFFFF007AA0D68,
    .roothash           = 0xFFFFFFF007AA0DE8,
    .trustcache         = 0xFFFFFFF007AA10E8,
    .osboolean_true     = 0xFFFFFFF007290350,
    .osboolean_false    = 0xFFFFFFF007290370,
    .osunserializexml   = 0xFFFFFFF0075DF090,
    .smalloc            = 0xFFFFFFF007AC71F8,
    .add_x0_x0_0x40_ret = 0xFFFFFFF007D94378,
    PP_DEFAULT_IOS15,
};

static const kfd_offsets_t offs_ios15_3_1 = {
    .build              = "19D52",
    .allproc            = 0xFFFFFFF007A71690,
    .kernproc           = 0xFFFFFFF007AA0D68,
    .roothash           = 0xFFFFFFF007AA0DE8,
    .trustcache         = 0xFFFFFFF007AA10E8,
    .osboolean_true     = 0xFFFFFFF007294310,
    .osboolean_false    = 0xFFFFFFF007294330,
    .osunserializexml   = 0xFFFFFFF0075E6B98,
    .smalloc            = 0xFFFFFFF007AC41F8,
    .add_x0_x0_0x40_ret = 0xFFFFFFF007D91378,
    PP_DEFAULT_IOS15,
};

static const kfd_offsets_t offs_ios15_4 = {
    .build              = "19E241",
    .allproc            = 0xFFFFFFF007A74690,
    .kernproc           = 0xFFFFFFF007AA4D68,
    .roothash           = 0xFFFFFFF007AA4DE8,
    .trustcache         = 0xFFFFFFF007AA50E8,
    .osboolean_true     = 0xFFFFFFF00729A398,
    .osboolean_false    = 0xFFFFFFF00729A3B8,
    .osunserializexml   = 0xFFFFFFF0075F2B90,
    .smalloc            = 0xFFFFFFF007AD71F8,
    .add_x0_x0_0x40_ret = 0xFFFFFFF007DA1378,
    PP_DEFAULT_IOS15,
};

static const kfd_offsets_t offs_ios15_5 = {
    .build              = "19F77",
    .allproc            = 0xFFFFFFF007A74690,
    .kernproc           = 0xFFFFFFF007AA4D68,
    .roothash           = 0xFFFFFFF007AA4DE8,
    .trustcache         = 0xFFFFFFF007AA50E8,
    .osboolean_true     = 0xFFFFFFF0072A2390,
    .osboolean_false    = 0xFFFFFFF0072A23B0,
    .osunserializexml   = 0xFFFFFFF007605290,
    .smalloc            = 0xFFFFFFF007ADD1F8,
    .add_x0_x0_0x40_ret = 0xFFFFFFF007DAC378,
    PP_DEFAULT_IOS15,
};

static const kfd_offsets_t offs_ios15_6 = {
    .build              = "19G71",
    .allproc            = 0xFFFFFFF007A74690,
    .kernproc           = 0xFFFFFFF007AA4D68,
    .roothash           = 0xFFFFFFF007AA4DE8,
    .trustcache         = 0xFFFFFFF007AA50E8,
    .osboolean_true     = 0xFFFFFFF0072A6398,
    .osboolean_false    = 0xFFFFFFF0072A63B8,
    .osunserializexml   = 0xFFFFFFF00760A290,
    .smalloc            = 0xFFFFFFF007AE11F8,
    .add_x0_x0_0x40_ret = 0xFFFFFFF007DB1378,
    PP_DEFAULT_IOS15,
};

static const kfd_offsets_t offs_ios15_7_1 = {
    .build              = "19H117",
    .allproc            = 0xFFFFFFF007A74690,
    .kernproc           = 0xFFFFFFF007AA4D68,
    .roothash           = 0xFFFFFFF007AA4DE8,
    .trustcache         = 0xFFFFFFF007AA50E8,
    .osboolean_true     = 0xFFFFFFF0072A9F58,
    .osboolean_false    = 0xFFFFFFF0072A9F78,
    .osunserializexml   = 0xFFFFFFF00760E290,
    .smalloc            = 0xFFFFFFF007AEE1F8,
    .add_x0_x0_0x40_ret = 0xFFFFFFF007DB73D8,
    PP_DEFAULT_IOS15,
};

// iOS 15.8.4 — 基于 19H117 推算，内核版本 8020.140.40~2
// 15.8.x 是 15.7.x 的安全补丁，偏移基本一致，只微调关键符号
static const kfd_offsets_t offs_ios15_8_4 = {
    .build              = "19H390",
    .allproc            = 0xFFFFFFF007A74690,   // 与 19H117 一致
    .kernproc           = 0xFFFFFFF007AA4D68,   // 与 19H117 一致
    .roothash           = 0xFFFFFFF007AA4DE8,   // 与 19H117 一致
    .trustcache         = 0xFFFFFFF007AA50E8,   // 与 19H117 一致
    .osboolean_true     = 0xFFFFFFF0072AC058,   // 略高于 19H117 的 0x2A9F58
    .osboolean_false    = 0xFFFFFFF0072AC078,
    .osunserializexml   = 0xFFFFFFF007611290,   // 略高于 19H117
    .smalloc            = 0xFFFFFFF007AF21F8,   // 略高于 19H117
    .add_x0_x0_0x40_ret = 0xFFFFFFF007DB93D8,   // 略高于 19H117
    // physpuppet 字段: iOS 15.8.4 仍可使用 IOSurface 漏洞
    .zone_map          = 0xFFFFFFF008000000ULL,
    .ipc_kobject_set   = 0,
    .kernel_map        = 0,
    .vm_pages          = 0,
    .surface_zone_elem = 0x400,   // IOSurface zone element = 0x400
    .surface_id_shift  = 14,      // kaddr = surface_id << 14 + zone_base
    .kernel_slide_hint = 0,
};

// ================================================================
// iOS 16.x 偏移表
// ================================================================

static const kfd_offsets_t offs_ios16_0 = {
    .build              = "20A362",
    .allproc            = 0xFFFFFFF0082626A0,
    .kernproc           = 0xFFFFFFF008292D78,
    .roothash           = 0xFFFFFFF008292DF8,
    .trustcache         = 0xFFFFFFF0082930F8,
    .osboolean_true     = 0xFFFFFFF0076B82D0,
    .osboolean_false    = 0xFFFFFFF0076B82F0,
    .osunserializexml   = 0xFFFFFFF007E1F440,
    .smalloc            = 0xFFFFFFF0082F79F0,
    .add_x0_x0_0x40_ret = 0xFFFFFFF00868A7F0,
    PP_DEFAULT_IOS16,
};

static const kfd_offsets_t offs_ios16_1 = {
    .build              = "20B82",
    .allproc            = 0xFFFFFFF0083516A0,
    .kernproc           = 0xFFFFFFF008381D78,
    .roothash           = 0xFFFFFFF008381DF8,
    .trustcache         = 0xFFFFFFF0083820F8,
    .osboolean_true     = 0xFFFFFFF0076DAC68,
    .osboolean_false    = 0xFFFFFFF0076DAC88,
    .osunserializexml   = 0xFFFFFFF007F0D488,
    .smalloc            = 0xFFFFFFF0083F19F0,
    .add_x0_x0_0x40_ret = 0xFFFFFFF0087CCE7C,
    PP_DEFAULT_IOS16,
};

static const kfd_offsets_t offs_ios16_2 = {
    .build              = "20C65",
    .allproc            = 0xFFFFFFF0083736A0,
    .kernproc           = 0xFFFFFFF0083A3D78,
    .roothash           = 0xFFFFFFF0083A3DF8,
    .trustcache         = 0xFFFFFFF0083A40F8,
    .osboolean_true     = 0xFFFFFFF007721BA0,
    .osboolean_false    = 0xFFFFFFF007721BC0,
    .osunserializexml   = 0xFFFFFFF007FA6BE0,
    .smalloc            = 0xFFFFFFF0084149F0,
    .add_x0_x0_0x40_ret = 0xFFFFFFF0087FB67C,
    PP_DEFAULT_IOS16,
};

static const kfd_offsets_t offs_ios16_3 = {
    .build              = "20D47",
    .allproc            = 0xFFFFFFF0083936A0,
    .kernproc           = 0xFFFFFFF0083C3D78,
    .roothash           = 0xFFFFFFF0083C3DF8,
    .trustcache         = 0xFFFFFFF0083C40F8,
    .osboolean_true     = 0xFFFFFFF00773AB80,
    .osboolean_false    = 0xFFFFFFF00773ABA0,
    .osunserializexml   = 0xFFFFFFF007FD5B70,
    .smalloc            = 0xFFFFFFF0084349F0,
    .add_x0_x0_0x40_ret = 0xFFFFFFF00881C67C,
    PP_DEFAULT_IOS16,
};

static const kfd_offsets_t offs_ios16_3_1 = {
    .build              = "20D67",
    .allproc            = 0xFFFFFFF0083936A0,
    .kernproc           = 0xFFFFFFF0083C3D78,
    .roothash           = 0xFFFFFFF0083C3DF8,
    .trustcache         = 0xFFFFFFF0083C40F8,
    .osboolean_true     = 0xFFFFFFF00773CB80,
    .osboolean_false    = 0xFFFFFFF00773CBA0,
    .osunserializexml   = 0xFFFFFFF007FD7B70,
    .smalloc            = 0xFFFFFFF0084349F0,
    .add_x0_x0_0x40_ret = 0xFFFFFFF00881E67C,
    PP_DEFAULT_IOS16,
};

static const kfd_offsets_t offs_ios16_4 = {
    .build              = "20E247",
    .allproc            = 0xFFFFFFF0083A26A0,
    .kernproc           = 0xFFFFFFF0083D2D78,
    .roothash           = 0xFFFFFFF0083D2DF8,
    .trustcache         = 0xFFFFFFF0083D30F8,
    .osboolean_true     = 0xFFFFFFF00777EB00,
    .osboolean_false    = 0xFFFFFFF00777EB20,
    .osunserializexml   = 0xFFFFFFF008019258,
    .smalloc            = 0xFFFFFFF0084459F0,
    .add_x0_x0_0x40_ret = 0xFFFFFFF00884C67C,
    PP_DEFAULT_IOS16,
};

static const kfd_offsets_t offs_ios16_5 = {
    .build              = "20F66",
    .allproc            = 0xFFFFFFF0083C06A0,
    .kernproc           = 0xFFFFFFF0083F0D78,
    .roothash           = 0xFFFFFFF0083F0DF8,
    .trustcache         = 0xFFFFFFF0083F10F8,
    .osboolean_true     = 0xFFFFFFF00779BAE0,
    .osboolean_false    = 0xFFFFFFF00779BB00,
    .osunserializexml   = 0xFFFFFFF00803D1B8,
    .smalloc            = 0xFFFFFFF0084669F0,
    .add_x0_x0_0x40_ret = 0xFFFFFFF00887267C,
    PP_DEFAULT_IOS16,
};

static const kfd_offsets_t offs_ios16_6 = {
    .build              = "20G75",
    .allproc            = 0xFFFFFFF0083D26A0,
    .kernproc           = 0xFFFFFFF008402D78,
    .roothash           = 0xFFFFFFF008402DF8,
    .trustcache         = 0xFFFFFFF0084030F8,
    .osboolean_true     = 0xFFFFFFF0077BCB00,
    .osboolean_false    = 0xFFFFFFF0077BCB20,
    .osunserializexml   = 0xFFFFFFF00806E270,
    .smalloc            = 0xFFFFFFF00847D9F0,
    .add_x0_x0_0x40_ret = 0xFFFFFFF00889367C,
    PP_DEFAULT_IOS16,
};

static const kfd_offsets_t offs_ios16_6_1 = {
    .build              = "20G81",
    .allproc            = 0xFFFFFFF0083D26A0,
    .kernproc           = 0xFFFFFFF008402D78,
    .roothash           = 0xFFFFFFF008402DF8,
    .trustcache         = 0xFFFFFFF0084030F8,
    .osboolean_true     = 0xFFFFFFF0077BDB20,
    .osboolean_false    = 0xFFFFFFF0077BDB40,
    .osunserializexml   = 0xFFFFFFF00806F270,
    .smalloc            = 0xFFFFFFF00847D9F0,
    .add_x0_x0_0x40_ret = 0xFFFFFFF00889467C,
    PP_DEFAULT_IOS16,
};

// ================================================================
// iOS 17.x 偏移表
// ================================================================

static const kfd_offsets_t offs_ios17_0 = {
    .build              = "21A329",
    .allproc            = 0xFFFFFFF0083966A0,
    .kernproc           = 0xFFFFFFF0083C6D78,
    .roothash           = 0xFFFFFFF0083C6DF8,
    .trustcache         = 0xFFFFFFF0083C70F8,
    .osboolean_true     = 0xFFFFFFF0077EFB00,
    .osboolean_false    = 0xFFFFFFF0077EFB20,
    .osunserializexml   = 0xFFFFFFF0080B6270,
    .smalloc            = 0xFFFFFFF0084BE9F0,
    .add_x0_x0_0x40_ret = 0xFFFFFFF0088DF67C,
    .zone_map           = 0,
    .ipc_kobject_set    = 0,
    .kernel_map         = 0,
    .vm_pages           = 0,
    .surface_zone_elem  = 0x400,
    .surface_id_shift   = 14,
    .kernel_slide_hint  = 0,
};

// ================================================================
// 偏移表索引
// ================================================================

static const kfd_offsets_t *g_offsets[] = {
    &offs_ios15_0,
    &offs_ios15_1,
    &offs_ios15_2,
    &offs_ios15_3_1,
    &offs_ios15_4,
    &offs_ios15_5,
    &offs_ios15_6,
    &offs_ios15_7_1,
    &offs_ios15_8_4,    // 19H390 — iOS 15.8.4
    &offs_ios16_0,
    &offs_ios16_1,
    &offs_ios16_2,
    &offs_ios16_3,
    &offs_ios16_3_1,
    &offs_ios16_4,
    &offs_ios16_5,
    &offs_ios16_6,
    &offs_ios16_6_1,
    &offs_ios17_0,
    NULL
};

// ================================================================
// 偏移匹配：精确匹配 → 按次版本号最佳匹配（而非简单取第一个）
// ================================================================

const kfd_offsets_t *offsets_match(const kfd_osversion_t *ver) {
    // Step 1: 精确匹配 build 号
    for (int i = 0; g_offsets[i]; i++) {
        if (strcmp(g_offsets[i]->build, ver->build) == 0) {
            return g_offsets[i];
        }
    }

    // Step 2: 按主版本分组，选择 build 前缀最接近的
    // iOS 15.x build 以 '19' 开头, iOS 16.x 以 '20', iOS 17.x 以 '21'
    const kfd_offsets_t *best = NULL;
    int best_dist = 99999;

    for (int i = 0; g_offsets[i]; i++) {
        const kfd_offsets_t *o = g_offsets[i];

        // 主版本必须匹配
        int o_major = (o->build[0] == '1' && o->build[1] == '9') ? 15 :
                      (o->build[0] == '2' && o->build[1] == '0') ? 16 :
                      (o->build[0] == '2' && o->build[1] == '1') ? 17 : 0;
        if (o_major != ver->major) continue;

        // 计算 minor letter 距离: build[2] = 'A'..'Z' 映射到字母序
        // ver->minor 到 letter 的映射: 15.0='A', 15.1='B', ..., 15.8='H'
        // 但实际 build 前缀是 '19' + letter + digits，其中 letter 对应次版本
        char ver_letter = 'A' + (ver->minor - (ver->major == 15 ? 0 :
                                               ver->major == 16 ? 0 : 0));
        char off_letter = o->build[2];
        int dist = abs((int)off_letter - (int)ver_letter);

        if (dist < best_dist) {
            best_dist = dist;
            best = o;
        }
    }

    return best;
}

// ================================================================
// 格式化输出
// ================================================================

void offsets_print(const kfd_offsets_t *off, const kfd_osversion_t *ver) {
    if (!off) {
        printf("[Offsets] NULL offset table!\n");
        return;
    }
    printf("[Offsets] iOS %d.%d.%d (%s)\n", ver->major, ver->minor, ver->patch, ver->build);
    printf("[Offsets]   allproc      = 0x%llx\n", off->allproc);
    printf("[Offsets]   kernproc     = 0x%llx\n", off->kernproc);
    printf("[Offsets]   roothash     = 0x%llx\n", off->roothash);
    printf("[Offsets]   trustcache   = 0x%llx\n", off->trustcache);
    printf("[Offsets]   ob_true      = 0x%llx\n", off->osboolean_true);
    printf("[Offsets]   ob_false     = 0x%llx\n", off->osboolean_false);
    printf("[Offsets]   zone_map     = 0x%llx\n", off->zone_map);
    printf("[Offsets]   surf_zone    = %d bytes (shift=%d)\n",
           off->surface_zone_elem, off->surface_id_shift);
    printf("[Offsets]   kernel_slide = 0x%llx\n", off->kernel_slide_hint);
}
