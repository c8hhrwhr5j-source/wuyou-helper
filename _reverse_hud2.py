#!/usr/bin/env python3
"""更精确地分析 createScreenIOSurface 调用点"""
from macholib.MachO import MachO
from macholib.mach_o import LC_SEGMENT_64
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

BIN = r"C:\TrollAutoTouch\_autotouch_extract\Payload\TrollAutoScript.app\HUD\HUDServices"
data = open(BIN, 'rb').read()
m = MachO(BIN)

# 1) 打印架构
h = m.headers[0]
print("arch:", hex(getattr(h.header, 'cputype', 0)), "sub:", hex(getattr(h.header, 'cpusubtype', 0)), "filetype:", hex(getattr(h.header, 'filetype', 0)))

# 2) 收集段
segs = []
for lc in h.commands:
    if getattr(lc[0], 'cmd', None) == LC_SEGMENT_64:
        seg = lc[1]
        secs = lc[2]
        segs.append((seg, secs))

# 3) 找 selector 地址及所在段
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

sel = b'createScreenIOSurface'
founds = find_sel(sel)
print(f"selector {sel.decode()} 出现位置:")
for addr, sec in founds:
    print(f"  0x{addr:x} ({sec})")

if not founds:
    raise SystemExit

sel_addr = founds[0][0]
sel_page = sel_addr & ~0xFFF
sel_off = sel_addr & 0xFFF
print(f"目标 page=0x{sel_page:x} off=0x{sel_off:x}")

# 4) 反汇编 __text, 匹配 adrp xN, sel_page + add xN, xN, sel_off
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = True
text_insns = []
for seg, secs in segs:
    for s in secs:
        if s.sectname.rstrip(b'\x00') == b'__text':
            code = data[s.offset:s.offset + s.size]
            for insn in md.disasm(code, s.addr):
                text_insns.append((insn.address, insn.mnemonic, insn.op_str))
            print(f"__text 大小 {len(code)} bytes, 指令数 {len(text_insns)}")

# 匹配 adrp 到 sel_page
candidates = []
for i, (addr, mn, ops) in enumerate(text_insns):
    if mn == 'adrp':
        parts = ops.split(',')
        if len(parts) == 2:
            try:
                imm = int(parts[1].strip().replace('#', ''), 0)
            except Exception:
                continue
            if imm == sel_page:
                reg = parts[0].strip()
                # 看下一条 add 是否 reg, reg, #sel_off
                next_ops = text_insns[i+1][2] if i+1 < len(text_insns) else ''
                next_mn = text_insns[i+1][1] if i+1 < len(text_insns) else ''
                candidates.append((addr, reg, next_mn, next_ops))

print(f"匹配到 {len(candidates)} 个 adrp -> page")
for c in candidates:
    addr, reg, next_mn, next_ops = c
    print(f"  adrp {reg} @ 0x{addr:x}; next: {next_mn} {next_ops}")

# 5) 如果 candidates 少, 打印所有引用 sel_off 的 add 指令
print("--- 打印含偏移", hex(sel_off), "的 add 指令(前20) ---")
cnt = 0
for addr, mn, ops in text_insns:
    if mn == 'add' and ('#' + hex(sel_off)) in ops:
        print(f"  0x{addr:x}: add {ops}")
        cnt += 1
        if cnt >= 20:
            break
