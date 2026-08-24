import os
import struct

def analyze_macho_header(filepath):
    """Analyze Mach-O binary header"""
    with open(filepath, 'rb') as f:
        magic = f.read(4)
        
        if magic == b'\xcf\xfa\xed\xfe':  # 64-bit little-endian
            is_64 = True
            endian = '<'
            print(f"File: {os.path.basename(filepath)}")
            print(f"Type: Mach-O 64-bit executable")
        elif magic == b'\xce\xfa\xed\xfe':  # 64-bit big-endian
            is_64 = True
            endian = '>'
            print(f"File: {os.path.basename(filepath)}")
            print(f"Type: Mach-O 64-bit executable (big-endian)")
        elif magic == b'\xfe\xed\xfa\xcf':  # 32-bit little-endian
            is_64 = False
            endian = '<'
            print(f"File: {os.path.basename(filepath)}")
            print(f"Type: Mach-O 32-bit executable")
        elif magic == b'\xfe\xed\xfa\xce':  # 32-bit big-endian
            is_64 = False
            endian = '>'
            print(f"File: {os.path.basename(filepath)}")
            print(f"Type: Mach-O 32-bit executable (big-endian)")
        elif magic == b'\xca\xfe\xba\xbe':  # Fat binary
            print(f"File: {os.path.basename(filepath)}")
            print(f"Type: Fat binary (multiple architectures)")
            # Read number of architectures
            f.seek(4)
            narchs = struct.unpack('>I', f.read(4))[0]
            print(f"Number of architectures: {narchs}")
            for i in range(min(narchs, 10)):
                arch_info = f.read(20)
                cpu_type, cpu_subtype, offset, size, align = struct.unpack('>iiIII', arch_info)
                cpu_names = {
                    12: 'armv7',
                    16777228: 'arm64',
                    16777229: 'arm64e',
                    7: 'x86',
                    0x01000007: 'x86_64',
                }
                arch_name = cpu_names.get(cpu_type, f'Unknown({cpu_type})')
                print(f"  Arch {i}: {arch_name} at offset {offset}, size {size}")
            return
        else:
            print(f"File: {os.path.basename(filepath)}")
            print(f"Unknown magic: {magic.hex()}")
            return
        
        # Read header
        if is_64:
            # mach_header_64: 32 bytes + cmd_size = 32
            f.seek(4)
            cpu_type = struct.unpack(endian + 'I', f.read(4))[0]
            cpu_subtype = struct.unpack(endian + 'I', f.read(4))[0]
            filetype = struct.unpack(endian + 'I', f.read(4))[0]
            ncmds = struct.unpack(endian + 'I', f.read(4))[0]
            sizeofcmds = struct.unpack(endian + 'I', f.read(4))[0]
            flags = struct.unpack(endian + 'I', f.read(4))[0]
            reserved = struct.unpack(endian + 'I', f.read(4))[0]
        else:
            # mach_header: 28 bytes
            f.seek(4)
            cpu_type = struct.unpack(endian + 'I', f.read(4))[0]
            cpu_subtype = struct.unpack(endian + 'I', f.read(4))[0]
            filetype = struct.unpack(endian + 'I', f.read(4))[0]
            ncmds = struct.unpack(endian + 'I', f.read(4))[0]
            sizeofcmds = struct.unpack(endian + 'I', f.read(4))[0]
            flags = struct.unpack(endian + 'I', f.read(4))[0]
        
        cpu_names = {
            12: 'armv7',
            16777228: 'arm64',
            16777229: 'arm64e',
            7: 'x86',
            0x01000007: 'x86_64',
        }
        arch_name = cpu_names.get(cpu_type, f'Unknown({cpu_type})')
        
        filetypes = {
            1: 'object',
            2: 'executable',
            3: 'fvmlib',
            4: 'core',
            5: 'preload',
            6: 'dylib',
            7: 'dylinker',
            8: 'bundle',
        }
        ft_name = filetypes.get(filetype, f'Unknown({filetype})')
        
        print(f"  Architecture: {arch_name}")
        print(f"  File type: {ft_name}")
        print(f"  Number of load commands: {ncmds}")
        print(f"  Size of load commands: {sizeofcmds}")
        print(f"  Flags: 0x{flags:08x}")
        
        # Search for interesting strings
        f.seek(0)
        content = f.read()
        
        interesting_strings = [
            'volume', 'Volume', 'VOLUME',
            'button', 'Button', 'BUTTON',
            'keyboard', 'Keyboard', 'KEYBOARD',
            'CPDistributedMessagingCenter',
            'IOHID', 'HID',
            'SpringBoard',
            'mach_port',
            'dlsym', 'dlopen',
            'SBApplication',
            'launchd',
            'daemon', 'Daemon', 'DAEMON',
            'HUDServices', 'HUDService',
            'TAS', 'wudiKeyBoard',
            'hardware', 'Hardware', 'HARDWARE',
            '物理', '音量', '按键',
        ]
        
        print(f"\n  Searching for interesting strings...")
        found_strings = set()
        for s in interesting_strings:
            if s.encode('utf-8') in content or s.encode('latin-1') in content:
                found_strings.add(s)
        
        if found_strings:
            print(f"  Found {len(found_strings)} interesting strings:")
            for s in sorted(found_strings):
                print(f"    - {s}")
        else:
            print(f"  No interesting strings found")
        
        # Find all C-style strings in the binary
        strings_found = []
        current_string = b''
        for byte in content:
            if 32 <= byte <= 126:  # printable ASCII
                current_string += bytes([byte])
            else:
                if len(current_string) >= 8:
                    strings_found.append(current_string.decode('ascii', errors='ignore'))
                current_string = b''
        if len(current_string) >= 8:
            strings_found.append(current_string.decode('ascii', errors='ignore'))
        
        # Filter for volume/keyboard/HID related strings
        relevant = [s for s in strings_found if any(kw in s.lower() for kw in 
                    ['volume', 'button', 'key', 'hid', 'messag', 'spring', 
                     'daemon', 'hud', 'tas', 'wudi', 'hardware', 'launch'])]
        
        if relevant:
            print(f"\n  Relevant strings found:")
            for s in relevant[:50]:  # Limit to 50
                print(f"    \"{s}\"")
            if len(relevant) > 50:
                print(f"    ... and {len(relevant) - 50} more")

# Analyze the main executable
exe_path = r'C:\TrollAutoTouch\_reverse_eng\Payload\TrollAutoScript.app\TrollAutoScript'
if os.path.exists(exe_path):
    analyze_macho_header(exe_path)
else:
    print(f"Main executable not found at {exe_path}")

# Analyze HUDServices
hud_path = r'C:\TrollAutoTouch\_reverse_eng\Payload\TrollAutoScript.app\HUD\HUDServices'
if os.path.exists(hud_path):
    print("\n" + "="*60)
    analyze_macho_header(hud_path)
else:
    print(f"\nHUDServices not found at {hud_path}")

# Analyze TASKeyBoard
keyboard_path = r'C:\TrollAutoTouch\_reverse_eng\Payload\TrollAutoScript.app\PlugIns\TASKeyBoard.appex\wudiKeyBoard'
if os.path.exists(keyboard_path):
    print("\n" + "="*60)
    analyze_macho_header(keyboard_path)
else:
    print(f"\nwudiKeyBoard not found at {keyboard_path}")

# Analyze TASWidgetExtension
widget_path = r'C:\TrollAutoTouch\_reverse_eng\Payload\TrollAutoScript.app\PlugIns\TASWidgetExtension.appex\TASWidgetExtension'
if os.path.exists(widget_path):
    print("\n" + "="*60)
    analyze_macho_header(widget_path)
else:
    print(f"\nTASWidgetExtension not found at {widget_path}")
