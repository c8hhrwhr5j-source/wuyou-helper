#!/usr/bin/env python3
"""找字符串引用: adrp reg,#page + 后续任意位置 add reg,reg,#off (OLLVM 平坦化无窗口限制)"""
import sys
from macholib.MachO import MachO
from macholib.mach_o import LC_SEGMENT_64
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

BIN = r"C:\TrollAutoTouch\_tas236_extract\Payload\TrollAutoScript.app\HUD\HUDServices"
data = open(BIN, 'rb').read()
m = MachO(BIN)
h = m.headers[0]
segs = []
for lc in h.commands:
    if getattr(lc[0], 'cmd', None) == LC_SEGMENT_64:
        segs.append((lc[1], lc[2]))

text = None
for seg, secs in segs:
    for s in secs:
        if s.sectname.rstrip(b'\x00') == b'__text':
            text = (s.addr, data[s.offset:s.offset + s.size])

t_base, t_bytes = text
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = False
insns = [(i.address, i.mnemonic, i.op_str) for i in md.disasm(t_bytes, t_base)]
print(f"text insns={len(insns)}", file=sys.stderr)

def va(off):
    return 0x100000000 + off

CTX = 60
for arg in sys.argv[1:]:
    off = int(arg, 0)
    addr = va(off)
    page = addr & ~0xFFF
    o = addr & 0xFFF
    print(f"\n===== target off=0x{off:x} va=0x{addr:x} (page=0x{page:x} off=0x{o:x}) =====")
    # 收集所有 adrp: reg -> 指令index
    adrps = {}
    for i in range(len(insns)):
        a, mn, ops = insns[i]
        if mn != 'adrp':
            continue
        parts = ops.split(',')
        if len(parts) != 2:
            continue
        try:
            imm = int(parts[1].strip().lstrip('#'), 0)
        except Exception:
            continue
        if imm == page:
            adrps.setdefault(parts[0].strip(), []).append(i)
    found = 0
    for reg, idxs in adrps.items():
        for i in idxs:
            # 在 adrp 之后找 add reg, reg, #off (同 reg)
            for j in range(i + 1, min(i + 300, len(insns))):
                a2, mn2, ops2 = insns[j]
                if mn2 == 'add' and ops2 == f'{reg}, {reg}, #{hex(o)}':
                    found += 1
                    print(f"\n  ---- ref #{found} at 0x{a2:x} (adrp@0x{insns[i][0]:x}) ----")
                    s = max(0, j - CTX)
                    e = min(len(insns), j + CTX)
                    for k in range(s, e):
                        a3, mn3, ops3 = insns[k]
                        mark = "   <<<<" if k == j else ""
                        print(f"   0x{a3:x}: {mn3:9s} {ops3}{mark}")
                    break
    if not found:
        print("  (未找到 adrp+add 引用)")
