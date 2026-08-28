# -*- coding: utf-8 -*-
"""采样 A/C/D 多处颜色对比"""
import struct, sys, zlib

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

def px(rows, x, y, w, bpp):
    o = x*bpp
    return (rows[y][o], rows[y][o+1], rows[y][o+2])

files = [(f, read_pixels(f)) for f in sys.argv[1:4]]
pts = [(375,667),(690,66),(100,1310),(100,600),(375,400),(600,900),(200,500),(375,200),(650,1300),(30,100)]
print('点位对比:')
for pt in pts:
    line = []
    for name, (w,h,bpp,rows) in files:
        line.append('%s=%s' % (name, px(rows, pt[0], pt[1], w, bpp)))
    print('  (%3d,%4d)  %s' % (pt[0], pt[1], '  '.join(line)))
