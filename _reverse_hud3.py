#!/usr/bin/env python3
"""打印 createScreenIOSurface 引用点上下文"""
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

md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = True
text_insns = []
for seg, secs in segs:
    for s in secs:
        if s.sectname.rstrip(b'\x00') == b'__text':
            code = data[s.offset:s.offset + s.size]
            for insn in md.disasm(code, s.addr):
                text_insns.append((insn.address, insn.mnemonic, insn.op_str))
            print(f"__text 指令数: {len(text_insns)}")

TARGETS = {0x10024d4e8, 0x10024d6e0}
addr_of = {}
for i, (addr, mn, ops) in enumerate(text_insns):
    addr_of[addr] = i

for target in sorted(TARGETS):
    i = addr_of[target]
    print(f"===== 引用点 0x{target:x} =====")
    start = max(0, i - 15)
    end = min(len(text_insns), i + 20)
    for j in range(start, end):
        a, mn, ops = text_insns[j]
        mark = "  <<<" if a == target else ""
        print(f"  0x{a:x}: {mn:10s} {ops}{mark}")
    print()
