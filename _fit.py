# -*- coding: utf-8 -*-
"""从 A/C 同一元素的渐变区域提取样本, 拟合原版转换 A=f(C)"""
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

# 1) 金色横幅行 y=66, x=660..749 逐像素
print('== 横幅行 y=66 x=660..749 (C -> A) ==')
for x in range(660, 750, 3):
    p = px(rc, x, 66, W, bpp); q = px(ra, x, 66, W, bpp)
    print('  x=%3d  C=%3d,%3d,%3d  A=%3d,%3d,%3d' % (x, p[0],p[1],p[2], q[0],q[1],q[2]))

# 2) 底部蓝色元素 y=1280..1333, x 扫蓝色像素
print('== 底部蓝色元素 (y=1280..1333) ==')
def blue_rows(rows):
    out = {}
    for y in range(1280, 1334):
        for x in range(0, 750, 2):
            p = px(rows, x, y, W, bpp)
            if p[2] > 150 and p[2] - p[0] > 30 and p[2] - p[1] > 30:
                out.setdefault((x//40*40, y//8*8), []).append(p)
    return out
for name, rows in (('C', rc), ('A', ra)):
    o = blue_rows(rows)
    total = sum(len(v) for v in o.values())
    print('  %s: 蓝色块数量=%d 像素=%d' % (name, len(o), total))
    for k in sorted(o)[:10]:
        v = o[k]
        avg = tuple(sum(c[i] for c in v)//len(v) for i in range(3))
        print('    (%d,%d) n=%d avg=%s' % (k[0], k[1], len(v), avg))

# 3) 全图中性色样本(差异<=2)的通道变换
print('== 中性色样本拟合 (差异<=2 像素) ==')
bins = {}
for y in range(0, H, 2):
    for x in range(0, W, 2):
        p = px(rc, x, y, W, bpp); q = px(ra, x, y, W, bpp)
        d = max(abs(p[i]-q[i]) for i in range(3))
        if d <= 2:
            b = min(p[0]//32*32, 255)
            if b not in bins: bins[b] = [0,0,0,0]
            bins[b][0] += 1
            for i in range(3): bins[b][1+i] += (q[i]-p[i])
for b in sorted(bins):
    n, dR, dG, dB = bins[b]
    if n < 50: continue
    print('  C亮度bin %3d: n=%4d  均值差 A-C = (R%+.1f G%+.1f B%+.1f)' % (b, n, dR/n, dG/n, dB/n))
