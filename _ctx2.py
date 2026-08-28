import re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
data = open(r'_tas236_extract\Payload\TrollAutoScript.app\HUD\HUDServices','rb').read()
for off in (0x4c14e5, 0x4cdcc1, 0x4058f7, 0x405930):
    s = max(0, off-200); e = min(len(data), off+500)
    chunk = data[s:e]
    strs = re.findall(rb'[\x20-\x7e]{4,}', chunk)
    print(f'===== off=0x{off:x} nearby =====')
    for x in strs:
        print('   ', x.decode(errors='replace'))
