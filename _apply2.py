# -*- coding: utf-8 -*-
"""E.png: 编码域对比度拉伸 E = 1.74*C - 188.7 (金/蓝/绿/白样本拟合)"""
import struct, zlib, sys

K = 1.74
OFF = 0.74 * 255.0  # 188.7

def read_pixels(path):
    d = open(path, 'rb').read()
    pos = 8; idat = b''; meta = {}
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos+4])[0]
        typ = d[pos+4:pos+8].decode('latin1')
        data = d[pos+8:pos+8+ln]
        if typ == 'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', data[:10])
            meta['size'] = (w, h); meta['bd'] = bd; meta['ct'] = ct
        elif typ == 'IDAT':
            idat += data
        pos += 12 + ln
    raw = zlib.decompress(idat)
    w, h = meta['size']; bd = meta['bd']; ct = meta['ct']
    bpp = {0:1, 2:3, 3:1, 4:2, 6:4}[ct] * (bd//8)
    stride = w*bpp + 1
    rows = [raw[y*stride:(y+1)*stride] for y in range(h)]
    prev = bytearray(w*bpp); out = []
    for r in rows:
        ft = r[0]; cur = bytearray(r[1:])
        if ft == 1:
            for i in range(bpp, len(cur)): cur[i] = (cur[i]+cur[i-bpp]) & 0xFF
        elif ft == 2:
            for i in range(len(cur)): cur[i] = (cur[i]+prev[i]) & 0xFF
        elif ft == 3:
            for i in range(len(cur)):
                a = cur[i-bpp] if i >= bpp else 0
                cur[i] = (cur[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(len(cur)):
                a = cur[i-bpp] if i >= bpp else 0
                b = prev[i]; c = prev[i-bpp] if i >= bpp else 0
                p = a+b-c; pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                cur[i] = (cur[i]+pr) & 0xFF
        out.append(bytes(cur)); prev = cur
    return w, h, bpp, out

def write_png(path, w, h, rows):
    raw = b''
    for r in rows:
        raw += b'\x00' + r
    def chunk(typ, data):
        c = struct.pack('>I', len(data)) + typ + data
        c += struct.pack('>I', zlib.crc32(typ + data) & 0xffffffff)
        return c
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b'')
    open(path, 'wb').write(png)

def transform(c):
    return tuple(max(0, min(255, round(K*v - OFF))) for v in c)

src = sys.argv[1] if len(sys.argv) > 1 else 'C.png'
dst = sys.argv[2] if len(sys.argv) > 2 else 'E.png'
w, h, bpp, rows = read_pixels(src)
out = []
for y in range(h):
    r = bytearray(w*3)
    for x in range(w):
        o = x*bpp
        p = (rows[y][o], rows[y][o+1], rows[y][o+2])
        q = transform(p)
        r[x*3] = q[0]; r[x*3+1] = q[1]; r[x*3+2] = q[2]
    out.append(bytes(r))
write_png(dst, w, h, out)
print('已生成 %s  (E = %.2f*C - %.1f)' % (dst, K, OFF))
for pt in ((375,667),(690,66),(100,1310),(100,600)):
    x, y = pt
    o = x*bpp
    p = (rows[y][o], rows[y][o+1], rows[y][o+2])
    print('  (%d,%d) C=%s -> E=%s' % (x, y, p, transform(p)))
