# -*- coding: utf-8 -*-
"""列出 PNG 的 chunk 列表与色彩管理信息"""
import struct, sys

for path in sys.argv[1:]:
    d = open(path, 'rb').read()
    print('== %s (%d bytes) ==' % (path, len(d)))
    assert d[:8] == b'\x89PNG\r\n\x1a\n', 'not png'
    pos = 8
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos+4])[0]
        typ = d[pos+4:pos+8].decode('latin1')
        data = d[pos+8:pos+8+ln]
        print('  %s  len=%d' % (typ, ln))
        if typ == 'IHDR':
            w,h,bd,ct,cm,f,il = struct.unpack('>IIBBBBB', data)
            print('    size=%dx%d bd=%d ct=%d cm=%d' % (w,h,bd,ct,cm))
        elif typ == 'cHRM':
            vals = struct.unpack('>8I', data)
            print('    white=(%d,%d) red=(%d,%d) green=(%d,%d) blue=(%d,%d)' % vals)
        elif typ == 'gAMA':
            print('    gamma=%.4f' % (struct.unpack('>I', data)[0]/100000.0))
        elif typ == 'iCCP':
            n = data.index(b'\x00')
            print('    profile=%s len=%d' % (data[:n].decode('latin1','replace'), ln-n-1))
        elif typ == 'sRGB':
            print('    sRGB rendering intent=%d' % data[0])
        pos += 12 + ln
