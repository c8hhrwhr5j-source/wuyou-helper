#!/usr/bin/env python3
"""dump HUDServices 指定虚拟地址范围的反汇编"""
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
print(f"text vmaddr=0x{t_base:x} size=0x{len(t_bytes):x}", file=sys.stderr)
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = False

lo = int(sys.argv[1], 0)
hi = int(sys.argv[2], 0)
for i in md.disasm(t_bytes[lo - t_base:t_base + hi - lo], lo):
    print(f"0x{i.address:x}: {i.mnemonic:10s} {i.op_str}")
