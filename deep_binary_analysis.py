import re
import sys

def analyze_binary(filepath):
    """Extract ObjC method names and BKS-related strings from binary"""
    with open(filepath, 'rb') as f:
        data = f.read()
    
    results = {
        'bks_selectors': [],
        'hid_selectors': [],
        'volume_selectors': [],
        'event_selectors': [],
        'class_names': [],
        'all_objc_methods': [],
        'interesting_strings': [],
    }
    
    # Find all Objective-C method patterns
    # ObjC methods start with common prefixes like + or - followed by method name
    # In __objc_methname section, selectors are stored as plain C strings
    
    # Extract all printable strings of reasonable length
    text_pattern = re.compile(b'[ -~]{4,}')
    strings_found = set()
    
    for match in text_pattern.finditer(data):
        try:
            s = match.group().decode('ascii', errors='ignore').strip()
            if len(s) >= 4 and len(s) <= 200:
                strings_found.add(s)
        except:
            pass
    
    # Class names (NSClassFromString targets)
    class_pattern = re.compile(r'^[A-Z][A-Za-z0-9]+$')
    
    for s in sorted(strings_found):
        # ObjC method selectors (contain colons or start with common keywords)
        if ':' in s and len(s) < 100:
            # This looks like an ObjC selector
            results['all_objc_methods'].append(s)
            
            lower = s.lower()
            if any(kw in lower for kw in ['bks', 'backboard', 'hid', 'event', 'volume', 'key', 'button', 'delivery', 'router']):
                results['bks_selectors'].append(s)
        
        # Class-like names
        if class_pattern.match(s) and len(s) > 5:
            lower = s.lower()
            if any(kw in lower for kw in ['bks', 'backboard', 'hid', 'event', 'volume', 'key', 'button', 'delivery', 'router', 'frontboard', 'board']):
                results['class_names'].append(s)
        
        # Interesting strings
        lower = s.lower()
        if any(kw in lower for kw in ['backboard', 'bks', 'bkshid', 'volume', 'hardware', 'physical', 'hid event', 'event type']):
            if s not in results['interesting_strings']:
                results['interesting_strings'].append(s)
    
    return results

# Analyze HUDServices binary
huds_path = r'_reverse_eng\Payload\TrollAutoScript.app\HUD\HUDServices'
app_path = r'_reverse_eng\Payload\TrollAutoScript.app\TrollAutoScript'

print("=" * 60)
print("ANALYZING HUDServices BINARY")
print("=" * 60)
results = analyze_binary(huds_path)

print("\n[BKSHIDEventDeliveryManager 类名]")
for c in results['class_names']:
    print(f"  {c}")

print("\n[BKS/HID/Volume 相关 Selector]")
for s in results['bks_selectors']:
    print(f"  {s}")

print("\n[有趣的字符串]")
for s in results['interesting_strings']:
    print(f"  {s}")

print("\n[所有 ObjC 方法 (包含 bks/hid/event/volume/key 关键字)]")
for s in results['all_objc_methods']:
    lower = s.lower()
    if any(kw in lower for kw in ['bks', 'hid', 'volume', 'key', 'button', 'event', 'delivery', 'router', 'register', 'observe', 'monitor']):
        print(f"  {s}")

print("\n" + "=" * 60)
print("ANALYZING MAIN APP BINARY")
print("=" * 60)
results2 = analyze_binary(app_path)

print("\n[BKS/HID/Volume 相关 Selector]")
for s in results2['bks_selectors']:
    print(f"  {s}")

print("\n[有趣的字符串]")
for s in results2['interesting_strings']:
    print(f"  {s}")

print("\n[所有 ObjC 方法 (包含 bks/hid/event/volume/key 关键字)]")
for s in results2['all_objc_methods']:
    lower = s.lower()
    if any(kw in lower for kw in ['bks', 'hid', 'volume', 'key', 'button', 'event', 'delivery', 'router', 'register', 'observe', 'monitor']):
        print(f"  {s}")
