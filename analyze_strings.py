import os
import re

def find_strings_in_binary(filepath, keywords):
    """Find strings containing keywords in binary file"""
    with open(filepath, 'rb') as f:
        content = f.read()
    
    # Find all C-style strings (sequences of printable ASCII)
    strings = []
    current = b''
    for byte in content:
        if 32 <= byte <= 126:
            current += bytes([byte])
        else:
            if len(current) >= 4:
                strings.append(current.decode('ascii', errors='ignore'))
            current = b''
    if len(current) >= 4:
        strings.append(current.decode('ascii', errors='ignore'))
    
    # Filter for keywords
    results = []
    for s in strings:
        s_lower = s.lower()
        for kw in keywords:
            if kw.lower() in s_lower:
                results.append(s)
                break
    
    return results

def search_binary_for_patterns(filepath, patterns):
    """Search binary for specific byte patterns"""
    with open(filepath, 'rb') as f:
        content = f.read()
    
    results = []
    for name, pattern in patterns:
        if isinstance(pattern, str):
            pattern = pattern.encode('utf-8', errors='ignore')
        positions = []
        start = 0
        while True:
            pos = content.find(pattern, start)
            if pos == -1:
                break
            positions.append(pos)
            start = pos + 1
        if positions:
            results.append((name, positions, len(positions)))
    
    return results

# Keywords to search for
keywords = [
    'volume', 'Volume', 'VOLUME',
    'button', 'Button', 'BUTTON',
    'keyboard', 'Keyboard', 'KEYBOARD',
    'CPDistributedMessagingCenter',
    'IOHID', 'HID',
    'SpringBoard', 'springboard',
    'mach_port', 'mach',
    'dlsym', 'dlopen',
    'SBApplication',
    'launchd',
    'daemon', 'Daemon', 'DAEMON',
    'HUDServices', 'HUDService', 'hud',
    'TAS', 'wudiKeyBoard', 'wudi',
    'hardware', 'Hardware', 'HARDWARE',
    'bounce', 'Bounce',
    'outputVolume', 'AUDIOSESSION',
    'AVSystemController',
    'setVolume',
    'KVO', 'keyValue',
    'poll', 'Poll', 'POLL',
    'callback', 'Callback',
    'notification', 'Notification',
    'observe', 'Observe',
    'register', 'Register',
    'subscribe', 'Subscribe',
    'listen', 'Listen',
    'monitor', 'Monitor',
    'physical', 'Physical',
    'key', 'Key',
    'press', 'Press',
    'touch', 'Touch',
    'input', 'Input',
    'event', 'Event',
    'system', 'System',
    'frontboard', 'FrontBoard',
    'BSService', 'bservice',
    'entitlement', 'Entitlement',
    'TrollStore', 'trollstore',
    'TrollAuto', 'trollauto',
]

# Search patterns (byte sequences that might indicate API calls)
patterns = [
    ('CPDistributedMessagingCenter', 'CPDistributedMessagingCenter'),
    ('IOHIDEventSystemClient', 'IOHIDEventSystemClient'),
    ('IOHIDEventSystemClientCreate', 'IOHIDEventSystemClientCreate'),
    ('IOHIDEventSystemClientRegisterEventCallback', 'IOHIDEventSystemClientRegisterEventCallback'),
    ('AVSystemController', 'AVSystemController'),
    ('setVolumeTo', 'setVolumeTo'),
    ('outputVolume', 'outputVolume'),
    ('SpringBoard', 'SpringBoard'),
    ('hardware-button-service', 'hardware-button-service'),
    ('wudiKeyBoard', 'wudiKeyBoard'),
    ('TASKeyBoard', 'TASKeyBoard'),
    ('RequestsOpenAccess', 'RequestsOpenAccess'),
    ('keyboard-service', 'keyboard-service'),
    ('FrontBoard', 'FrontBoard'),
    ('BSServiceDomains', 'BSServiceDomains'),
    ('com.apple.frontboard', 'com.apple.frontboard'),
    ('HUDServices', 'HUDServices'),
    ('CPDMC', 'CPDMC'),
    ('DMCenters', 'DMCenters'),
    ('hardware-button', 'hardware-button'),
    ('volumeChanged', 'volumeChanged'),
    ('VolumeChanged', 'VolumeChanged'),
    ('audioSession', 'audioSession'),
    ('AVAudioSession', 'AVAudioSession'),
    ('outputVolume', 'outputVolume'),
    ('addObserver', 'addObserver'),
    ('removeObserver', 'removeObserver'),
    ('keyPath', 'keyPath'),
    ('KeyValue', 'KeyValue'),
    ('KVO', 'KVO'),
]

# Files to analyze
files = {
    'Main executable': r'C:\TrollAutoTouch\_reverse_eng\Payload\TrollAutoScript.app\TrollAutoScript',
    'HUDServices': r'C:\TrollAutoTouch\_reverse_eng\Payload\TrollAutoScript.app\HUD\HUDServices',
    'wudiKeyBoard': r'C:\TrollAutoTouch\_reverse_eng\Payload\TrollAutoScript.app\PlugIns\TASKeyBoard.appex\wudiKeyBoard',
    'TASWidgetHelper': r'C:\TrollAutoTouch\_reverse_eng\Payload\TrollAutoScript.app\PlugIns\TASWidgetExtension.appex\TASWidgetHelper.dylib',
}

for name, path in files.items():
    if not os.path.exists(path):
        print(f"\n{name}: NOT FOUND at {path}")
        continue
    
    file_size = os.path.getsize(path)
    print(f"\n{'='*80}")
    print(f"{name}: {path}")
    print(f"Size: {file_size} bytes")
    print(f"{'='*80}")
    
    # Find interesting strings
    found = find_strings_in_binary(path, keywords)
    if found:
        print(f"\nInteresting strings found ({len(found)}):")
        for s in found[:80]:
            print(f"  \"{s}\"")
        if len(found) > 80:
            print(f"  ... and {len(found) - 80} more")
    else:
        print("\nNo interesting strings found")
    
    # Search for patterns
    pattern_results = search_binary_for_patterns(path, patterns)
    if pattern_results:
        print(f"\nAPI/Pattern matches found ({len(pattern_results)}):")
        for name, positions, count in pattern_results:
            print(f"  {name}: found {count} time(s)")
    else:
        print("\nNo API/pattern matches found")
