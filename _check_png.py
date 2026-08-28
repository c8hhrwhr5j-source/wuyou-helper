# -*- coding: utf-8 -*-
"""检查 A.png/B.png 的 PNG 元数据(iCCP/gAMA/cHRM) 与中心/平均像素值"""
import struct, sys, zlib

def read_png(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', 'not png'
    pos = 8
    meta = {}
    idat = b''
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos+4])[0]
        typ = d[pos+4:pos+8].decode('latin1')
        data = d[pos+8:pos+8+ln]
        if typ == 'IHDR':
            w, h, bd, ct, comp, filt, inter = struct.unpack('>IIBBBBB', data)
            meta['size'] = (w, h)
            meta['bit_depth'] = bd
            meta['color_type'] = ct
        elif typ == 'iCCP':
            nul = data.index(b'\x00')
            meta['iCCP'] = data[:nul].decode('latin1')
        elif typ == 'gAMA':
            meta['gAMA'] = struct.unpack('>I', data)[0] / 100000.0
        elif typ == 'cHRM':
            vals = struct.unpack('>8I', data)
            meta['cHRM'] = tuple(round(v/100000.0, 4) for v in vals)
        elif typ == 'sRGB':
            meta['sRGB'] = 'rendering-intent=%d' % data[0]
        elif typ == 'IDAT':
            idat += data
        pos += 12 + ln
    raw = zlib.decompress(idat)
    w, h = meta['size']
    bd, ct = meta['bit_depth'], meta['color_type']
    bpp = {0:1, 2:3, 3:1, 4:2, 6:4}[ct] * (bd//8 if bd >= 8 else 1)
    stride = (w * bpp + 1)
    rows = [raw[y*stride:(y+1)*stride] for y in range(h)]
    def unfilter(rows):
        out = []
        prev = bytearray(w*bpp)
        for r in rows:
            ft = r[0]; cur = bytearray(r[1:])
            if ft == 1:
                for i in range(bpp, len(cur)): cur[i] = (cur[i] + cur[i-bpp]) & 0xFF
            elif ft == 2:
                for i in range(len(cur)): cur[i] = (cur[i] + prev[i]) & 0xFF
            elif ft == 3:
                for i in range(len(cur)):
                    a = cur[i-bpp] if i >= bpp else 0
                    cur[i] = (cur[i] + ((a + prev[i]) >> 1)) & 0xFF
            elif ft == 4:
                for i in range(len(cur)):
                    a = cur[i-bpp] if i >= bpp else 0
                    b = prev[i]; c = prev[i-bpp] if i >= bpp else 0
                    p = a + b - c
                    pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                    pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                    cur[i] = (cur[i] + pr) & 0xFF
            out.append(bytes(cur)); prev = cur
        return out
    rows = unfilter(rows)
    # 采样: 中心像素 + 全图平均(RGB8 或 16bit)
    def px(x, y):
        r = rows[y]
        off = x * bpp
        if bd == 8:
            if ct == 6: return r[off], r[off+1], r[off+2]
            if ct == 2: return r[off], r[off+1], r[off+2]
            return None
        else:
            v = struct.unpack('>%dH' % (len(r)//2), r)
            if ct == 6:
                off2 = x*4
                return v[off2], v[off2+1], v[off2+2]
            return None
    # 16bit->8bit 归一(与 PNG 语义一致: 除以 257)
    def to8(c):
        return c if bd == 8 else c // 257
    cx, cy = w//2, h//2
    c = px(cx, cy)
    N = 200
    s = [0,0,0]
    for y in range(0, h, max(1, h//N)):
        for x in range(0, w, max(1, w//N)):
            p = px(x, y)
            if p:
                s[0] += p[0]; s[1] += p[1]; s[2] += p[2]
    n = ((h-1)//max(1, h//N) + 1) * ((w-1)//max(1, w//N) + 1)
    meta['center_px'] = tuple(to8(v) for v in c) if c else None
    meta['avg_px'] = tuple(round(v/n) for v in s)
    return meta

for p in sys.argv[1:]:
    try:
        m = read_png(p)
        print('==== %s ====' % p)
        for k in sorted(m): print('  %s: %s' % (k, m[k]))
    except Exception as e:
        print('==== %s ==== ERROR: %s' % (p, e))
