"""用 TrollAutoTouch_icon.png 生成所有需要的 App 图标尺寸"""
import os, struct, zlib

def make_png_header(width, height):
    """返回 PNG IHDR 数据"""
    return struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)

def png_size(filepath):
    with open(filepath, 'rb') as f:
        f.read(8)  # skip signature
        f.read(4)  # length
        f.read(4)  # 'IHDR'
        w, h = struct.unpack('>II', f.read(8))
        return w, h

def chunk(type, data):
    c = type + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)

def nearest_resize_png(src, dst, new_w, new_h):
    """简陋但有效的 nearest-neighbor PNG 缩放"""
    w, h = png_size(src)
    with open(src, 'rb') as f:
        sig = f.read(8)
        raw = bytearray()
        while True:
            l = f.read(4)
            if len(l) < 4: break
            length = struct.unpack('>I', l)[0]
            ctype = f.read(4)
            data = f.read(length)
            f.read(4)  # crc
            if ctype == b'IHDR':
                raw.append(f.read(1) for _ in range(len(data)))  # skip, we generate new
            elif ctype == b'IDAT':
                raw.extend(data)
            # ignore other chunks
    
    decomp = zlib.decompress(bytes(raw))
    stride = w * 4 + 1  # +1 filter byte per row
    new_stride = new_w * 4 + 1
    new_raw = bytearray()
    
    for y in range(new_h):
        src_y = int(y * h / new_h)
        new_raw.append(0)  # filter none
        row_start = src_y * stride + 1
        for x in range(new_w):
            src_x = int(x * w / new_w)
            offset = row_start + src_x * 4
            new_raw.extend(decomp[offset:offset+4])
    
    new_data = zlib.compress(bytes(new_raw))
    
    with open(dst, 'wb') as f:
        f.write(sig)
        f.write(chunk(b'IHDR', make_png_header(new_w, new_h)))
        f.write(chunk(b'IDAT', new_data))
        f.write(chunk(b'IEND', b''))

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.join(ROOT, 'TrollAutoTouch_icon.png')
DEST = os.path.join(ROOT, 'TrollAutoTouch', 'Assets.xcassets', 'AppIcon.appiconset')

TARGETS = [
    ('AppIcon60x60@2x.png', 120, 120),   # iPhone 主屏
    ('AppIcon60x60@3x.png', 180, 180),   # iPhone 主屏 (3x)
    ('AppIcon76x76~ipad.png', 76, 76),   # iPad
    ('AppIcon76x76@2x~ipad.png', 152, 152),  # iPad 2x
    ('icon-1024.png', 1024, 1024),       # App Store / 巨魔
]

w0, h0 = png_size(SRC)
print(f'源图标: {w0}x{h0}')

os.makedirs(DEST, exist_ok=True)
for name, w, h in TARGETS:
    path = os.path.join(DEST, name)
    nearest_resize_png(SRC, path, w, h)
    print(f'  生成 {name} ({w}x{h})')

print('完成!')
