# -*- coding: utf-8 -*-
"""分析 PNG 的最饱和像素(RGB max-min 最大), 判断色域: sRGB vs P3 直出"""
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
        elif typ == 'iCCP':
            meta['iCCP'] = data[:data.index(b'\x00')].decode('latin1')
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
    return w, h, bd, ct, out

def px_of(rows, x, y, w, bd, ct, bpp):
    off = x*bpp
    if bd == 16:
        v = struct.unpack('>%dH' % (len(rows[y])//2), rows[y])
        if ct == 6: return (v[off]//257, v[off+1]//257, v[off+2]//257)
    if ct == 6: return (rows[y][off], rows[y][off+1], rows[y][off+2])
    if ct == 2: return (rows[y][off], rows[y][off+1], rows[y][off+2])
    return None

def analyze(path):
    w, h, bd, ct, rows = read_pixels(path)
    bpp = {0:1, 2:3, 3:1, 4:2, 6:4}[ct] * (bd//8)
    if rows: assert len(rows[0]) == w*bpp, 'stride mismatch: row=%d want=%d w=%d bpp=%d bd=%d ct=%d' % (len(rows[0]), w*bpp, w, bpp, bd, ct)
    best = []  # (sat, r, g, b, x, y)
    for y in range(0, h, 3):
        for x in range(0, w, 3):
            p = px_of(rows, x, y, w, bd, ct, bpp)
            if not p: continue
            r, g, b = p
            mx, mn = max(r,g,b), min(r,g,b)
            sat = mx - mn
            if len(best) < 12 or sat > best[0][0]:
                best.append((sat, r, g, b, x, y))
                best.sort()
                if len(best) > 12: best = best[1:]
    print('==== %s (%dx%d) ====' % (path, w, h))
    print('  色彩空间: %s' % ('iCCP' if 'iCCP' in globals() else '无标记(默认sRGB)'))
    for sat, r, g, b, x, y in reversed(best):
        print('  饱和%3d  R=%3d G=%3d B=%3d  @(%d,%d)  %s' % (sat, r, g, b, x, y, classify(r,g,b)))

def classify(r, g, b):
    # sRGB 纯红(255,0,0), P3 纯红(~(255,30,30)); 根据模式判断
    return ''

for p in sys.argv[1:]:
    analyze(p)
