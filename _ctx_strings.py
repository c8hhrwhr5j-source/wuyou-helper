import re, sys
sys.stdout.reconfigure(encoding='ascii', errors='replace')
data = open(r'_tas236_extract\Payload\TrollAutoScript.app\HUD\HUDServices','rb').read()
for off in (0x49a0bf, 0x4be28b, 0x4cda2e, 0x4a4e6f, 0x4b524b, 0x4b3cab, 0x4a5c9b):
    s = max(0, off-300); e = min(len(data), off+700)
    chunk = data[s:e]
    strs = re.findall(rb'[\x20-\x7e]{4,}', chunk)
    print(f'===== off=0x{off:x} nearby strings =====')
    for x in strs:
        print('   ', x.decode(errors='replace'))
