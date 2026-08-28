import re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
data = open(r'_tas236_extract\Payload\TrollAutoScript.app\HUD\HUDServices','rb').read()

# 找所有 iokit-user-client-class 出现的 XML 段
for m in re.finditer(rb'iokit-user-client-class', data):
    off = m.start()
    # 向前找 <key> 或 dict 开始, 向后找 </dict>
    start = data.rfind(b'<dict>', max(0, off-4000), off)
    end = data.find(b'</dict>', off, min(len(data), off+6000))
    if start == -1 or end == -1:
        continue
    xml = data[start:end+7]
    try:
        print(f"===== iokit-user-client-class @0x{off:x} =====")
        print(xml.decode('utf-8', errors='replace')[:5000])
    except Exception as e:
        print("decode err", e)
    break

# 也找 com.apple.security 其他键
for m in re.finditer(rb'com\.apple\.security\.', data):
    off = m.start()
    start = data.rfind(b'<key>', max(0, off-2000), off)
    if start == -1: continue
    end = data.find(b'</dict>', off, min(len(data), off+4000))
    if end == -1: continue
    xml = data[start:end+7]
    tag = data[off:off+60]
    print(f"\n===== security key @0x{off:x}: {tag.decode(errors='replace')} =====")
    print(xml.decode('utf-8', errors='replace')[:3000])
