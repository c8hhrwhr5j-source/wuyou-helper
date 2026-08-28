# -*- coding: utf-8 -*-
"""对比 A/C 顶部区域与全局通道均值, 判断界面/转换差异"""
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

A, C = sys.argv[1], sys.argv[2]
wa, ha, bpa, ra = read_pixels(A)
wc, hc, bpc, rc = read_pixels(C)
W, H = wa, ha
bpp = min(bpa, bpc)

print('== 全局通道均值 ==')
for name, rows in (('A', ra), ('C', rc)):
    s = [0,0,0]
    for y in range(0, H, 2):
        for x in range(0, W, 2):
            p = px(rows, x, y, W, bpp)
            for i in range(3): s[i] += p[i]
    n = (H//2)*(W//2)
    print('  %s: R=%.1f G=%.1f B=%.1f' % (name, s[0]/n, s[1]/n, s[2]/n))

print('== 顶部 y=0..120 采样 (x=60,180,300,420,540,660) ==')
for y in range(0, 121, 12):
    rowA, rowC = [], []
    for x in (60,180,300,420,540,660):
        rowA.append('%d,%d,%d' % px(ra, x, y, W, bpp))
        rowC.append('%d,%d,%d' % px(rc, x, y, W, bpp))
    print('  y=%3d  A: %s' % (y, '  '.join(rowA)))
    print('         C: %s' % ('  '.join(rowC)))

print('== 底部 y=1250..1310 采样 ==')
for y in (1250,1270,1290,1310):
    rowA, rowC = [], []
    for x in (100,300,500,700):
        rowA.append('%d,%d,%d' % px(ra, x, y, W, bpp))
        rowC.append('%d,%d,%d' % px(rc, x, y, W, bpp))
    print('  y=%4d A: %s' % (y, '  '.join(rowA)))
    print('        C: %s' % ('  '.join(rowC)))
