# -*- coding: utf-8 -*-
"""逐像素对比两张 PNG: 总体差异 + 按 y 带分布 + 中心白验证"""
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

a, c = sys.argv[1], sys.argv[2]
wa, ha, bpa, ra = read_pixels(a)
wc, hc, bpc, rc = read_pixels(c)
assert (wa, ha) == (wc, hc), '尺寸不同'
W, H = wa, ha
bpp = min(bpa, bpc)

total = W*H
identical = 0
diff_px = []  # (dist, x, y)
band_diff = {}  # y//100 -> (diff, count)
percept = 0  # 显著差异(任一通道差>30)
avgdiff = [0,0,0]
for y in range(H):
    band = y//100
    if band not in band_diff: band_diff[band] = [0, 0]
    for x in range(W):
        p = px(ra, x, y, W, bpp); q = px(rc, x, y, W, bpp)
        d = max(abs(p[i]-q[i]) for i in range(3))
        if d == 0:
            identical += 1
        else:
            band_diff[band][0] += 1
            band_diff[band][1] += 1
            avgdiff[0] += abs(p[0]-q[0]); avgdiff[1] += abs(p[1]-q[1]); avgdiff[2] += abs(p[2]-q[2])
            if d > 30: percept += 1
            diff_px.append((d, x, y))

print('== %s vs %s (%dx%d) ==' % (a, c, W, H))
print('完全相同像素: %d / %d = %.1f%%' % (identical, total, 100.0*identical/total))
ndiff = total - identical
if ndiff:
    print('差异像素均值(R,G,B): %.1f %.1f %.1f' % (avgdiff[0]/ndiff, avgdiff[1]/ndiff, avgdiff[2]/ndiff))
print('显著差异(通道差>30): %d (%.1f%%)' % (percept, 100.0*percept/total))
print('按 y 带差异率 (y: 差异/总数):')
for band in sorted(band_diff):
    c_, n = band_diff[band]
    print('  y=%d-%d: %5.1f%%' % (band*100, band*100+99, 100.0*c_/ (W*100)))

# 中心与金色横幅对比
def sample(rows, x, y):
    return px(rows, x, y, W, bpp)
print('中心(375,667)      A=%s C=%s' % (sample(ra,375,667), sample(rc,375,667)))
print('金色横幅(690,66)   A=%s C=%s' % (sample(ra,690,66), sample(rc,690,66)))
