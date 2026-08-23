#!/usr/bin/env python3
"""解析 HUDServices 的 createScreenIOSurface / screenShot 调用链(receiver 是谁)"""
import sys, struct
from macholib.MachO import MachO
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM, CS_OP_IMM, CS_OP_REG

BIN = r"C:\TrollAutoTouch\_autotouch_extract\Payload\TrollAutoScript.app\HUD\HUDServices"

# 1) 读取整个文件, 找到 selector 字符串的 file offset
data = open(BIN, 'rb').read()

_macho = MachO(BIN)

def _seg_sections():
    """返回 [(segment_command_64, [section, ...]), ...]"""
    from macholib.mach_o import LC_SEGMENT_64
    out = []
    for lc in _macho.headers[0].commands:
        if getattr(lc[0], 'cmd', None) == LC_SEGMENT_64:
            out.append((lc[1], lc[2]))
    return out

def find_sel_addr(sel):
    """返回该 selector 在 __objc_methname 段中的虚拟地址(可能多个). 通过扫描所有段的 string 匹配"""
    found = []
    for seg, secs in _seg_sections():
        for s in secs:
            name = s.sectname.decode().rstrip('\x00')
            if name in ('__objc_methname', '__cstring', '__objc_classname', '__objc_methlist'):
                start = s.offset
                end = s.offset + s.size
                blob = data[start:end]
                off = blob.find(sel.encode())
                while off != -1:
                    addr = s.addr + off
                    found.append(addr)
                    off = blob.find(sel.encode(), off + 1)
    return found

def segments_info():
    segs = []
    for seg, secs in _seg_sections():
        segs.append((seg.segname.rstrip(b'\x00').decode(), seg.vmaddr, seg.vmsize, seg.fileoff))
    return segs

def addr_to_fileoff(addr):
    for name, va, vs, fo in segments_info():
        if va <= addr < va + vs:
            return fo + (addr - va)
    return None

def disasm_text():
    """反汇编 __TEXT.__text, 返回 (addr, mnemonic, op_str, bytes) 列表"""
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    md.detail = True
    out = []
    for seg, secs in _seg_sections():
        for s in secs:
            if s.sectname.rstrip(b'\x00') == b'__text':
                code = data[s.offset:s.offset + s.size]
                for insn in md.disasm(code, s.addr):
                    out.append((insn.address, insn.mnemonic, insn.op_str, insn.bytes))
    return out

def main():
    for kw in (b'createScreenIOSurface', b'screenShot:', b'snapshot:'):
        sel_addr_list = find_sel_addr(kw.decode())
        print(f"### selector {kw.decode()} @ {[hex(a) for a in sel_addr_list[:5]]}")
        if not sel_addr_list:
            continue
        sel_set = set(sel_addr_list)
        text = disasm_text()
        # 找 adrp <reg>, <page-of-sel> 的指令(selector 可放任意寄存器)
        page_of = {sa: (sa & ~0xFFF) for sa in sel_set}
        targets = []
        adrp_total = 0
        for addr, mn, ops, byts in text:
            if mn == 'adrp':
                adrp_total += 1
                parts = ops.split(',')
                if len(parts) == 2:
                    try:
                        imm = int(parts[1].strip().replace('#', ''), 0)
                    except Exception:
                        continue
                    reg = parts[0].strip()
                    for sa in sel_set:
                        if page_of[sa] == imm:
                            targets.append((addr, reg, sa))
        print(f"  总 adrp 数: {adrp_total}; 引用 selector 的 adrp 数量: {len(targets)}")
        # 打印引用点的上下文
        idx_map = {}
        for t in targets:
            idx_map.setdefault(t[0], []).append(t)
        for i in range(len(text)):
            addr, mn, ops, byts = text[i]
            if addr in idx_map:
                for (_, reg, sel_addr) in idx_map[addr]:
                    # 打印附近 8 条指令
                    print(f"  --- 引用点 0x{addr:x} reg={reg} (sel=0x{sel_addr:x}) ---")
                    for j in range(max(0, i-3), min(len(text), i+8)):
                        a, mn2, ops2, byts2 = text[j]
                        flag = " <== adrp" if a == addr else ""
                        print(f"    0x{a:x}: {mn2:10s} {ops2}{flag}")

if __name__ == '__main__':
    main()
