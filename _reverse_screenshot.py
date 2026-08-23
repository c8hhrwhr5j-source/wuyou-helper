#!/usr/bin/env python3
"""分析 screenShot: / snapshot / mainScreen 相关调用点"""
from macholib.MachO import MachO
from macholib.mach_o import LC_SEGMENT_64
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

BIN = r"C:\TrollAutoTouch\_autotouch_extract\Payload\TrollAutoScript.app\HUD\HUDServices"
data = open(BIN, 'rb').read()
m = MachO(BIN)
h = m.headers[0]
segs = []
for lc in h.commands:
    if getattr(lc[0], 'cmd', None) == LC_SEGMENT_64:
        seg = lc[1]
        segs.append((seg, lc[2]))

def find_sel(sel):
    found = []
    for seg, secs in segs:
        for s in secs:
            name = s.sectname.decode().rstrip('\x00')
            if name in ('__objc_methname', '__cstring'):
                blob = data[s.offset:s.offset + s.size]
                off = blob.find(sel)
                while off != -1:
                    found.append((s.addr + off, name))
                    off = blob.find(sel, off + 1)
    return found

md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = True
text_insns = []
for seg, secs in segs:
    for s in secs:
        if s.sectname.rstrip(b'\x00') == b'__text':
            code = data[s.offset:s.offset + s.size]
            for insn in md.disasm(code, s.addr):
                text_insns.append((insn.address, insn.mnemonic, insn.op_str))

for sel in (b'mainScreen', b'screenShot:', b'createScreenIOSurface'):
    founds = find_sel(sel)
    print(f"### {sel.decode()} 出现: {[(hex(a), n) for a, n in founds]}")
    if not founds:
        continue
    sel_addr = founds[0][0]
    sel_page = sel_addr & ~0xFFF
    sel_off = sel_addr & 0xFFF
    print(f"    page=0x{sel_page:x} off=0x{sel_off:x}")
    # 找 adrp xN, page 且后续 add xN, xN, #off 的组合
    for i in range(len(text_insns)):
        addr, mn, ops = text_insns[i]
        if mn == 'adrp':
            parts = ops.split(',')
            if len(parts) != 2:
                continue
            try:
                imm = int(parts[1].strip().replace('#', ''), 0)
            except Exception:
                continue
            if imm != sel_page:
                continue
            reg = parts[0].strip()
            # 向后找 add <reg>, <reg>, #sel_off 在 3 条指令内
            for j in range(i + 1, min(i + 4, len(text_insns))):
                a2, mn2, ops2 = text_insns[j]
                if mn2 == 'add' and ops2 == f'{reg}, {reg}, #{hex(sel_off)}':
                    print(f"    => 引用点 0x{a2:x}: add {ops2}")
                    # 打印上下文
                    s = max(0, j - 8)
                    e = min(len(text_insns), j + 12)
                    for k in range(s, e):
                        a3, mn3, ops3 = text_insns[k]
                        mark = "   <<<" if k == j else ""
                        print(f"      0x{a3:x}: {mn3:10s} {ops3}{mark}")
                    print()
    print()
