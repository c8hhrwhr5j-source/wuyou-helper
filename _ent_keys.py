import re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
data = open(r'_tas236_extract\Payload\TrollAutoScript.app\HUD\HUDServices','rb').read()

print("===== IOSurface 常量符号 (导入符号表) =====")
off = 0
for m in re.finditer(rb'_kIOSurface[A-Za-z0-9_]*', data):
    s = m.group().decode()
    if s not in ('_kIOSurfaceAcceleratorMatrix','_kIOSurfaceAcceleratorTransferMode'):
        print(f"  {s} @0x{m.start():x}")

print("\n===== 内存区/GPU 相关字符串 =====")
for key in (b'Purple', b'GFX', b'Gfx', b'gfx', b'Memory', b'AGX', b'IOAccel', b'Writable', b'CacheMode', b'DeviceMemory'):
    hits = []
    for m in re.finditer(key, data):
        hits.append(m.start())
    if hits:
        shown = ', '.join(f'0x{h:x}' for h in hits[:10])
        more = f' ...({len(hits)})' if len(hits) > 10 else ''
        print(f"  {key.decode():12s} x{len(hits):3d}: {shown}{more}")

print("\n===== 'PurpleGFXMemory' / 'PurpleGfxMemory' 精确串 =====")
for key in (b'PurpleGFXMemory', b'PurpleGfxMemory', b'PurpleGfxMemory1', b'PurpleGfxMemory2'):
    print(f"  {key.decode():18s}: {data.count(key)} 次")

print("\n===== 像素格式相关 (fourcc) =====")
for key in (b'BGRA', b'RGBA', b'BGRX', b'XRGB', b'w30r', b'b30r', b'w24r', b'ABGR', b'YpCbCr8', b'2vuy'):
    c = data.count(key)
    if c:
        print(f"  {key.decode():10s}: x{c} (首个@0x{data.find(key):x})")
