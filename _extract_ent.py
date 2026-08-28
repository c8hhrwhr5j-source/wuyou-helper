# -*- coding: utf-8 -*-
# 从 Mach-O 签名 blob (type 2/5) 提取 XML plist entitlements 并输出 plist
import struct, sys, re, plistlib

def main(path):
    data = open(path, 'rb').read()
    magic = data[:4]
    slices = []
    if magic in (b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
        nfat = struct.unpack('>I', data[4:8])[0]
        off = 8
        for _ in range(nfat):
            cpu, sub, o, sz, al = struct.unpack('>IIIII', data[off:off+20])
            off += 20
            if cpu in (0x0100000c, 0x01000007):
                slices.append((cpu, data[o:o+sz]))
    else:
        slices.append((0, data))
    found = []
    for cpu, m in slices:
        endian = '>' if m[:4] == b'\xfe\xed\xfa\xcf' else '<'
        ncmds = struct.unpack(endian+'I', m[16:20])[0]
        off = 32
        for _ in range(ncmds):
            cmd, csz = struct.unpack('<II', m[off:off+8])
            if cmd == 0x1d:
                doff, dsz = struct.unpack('<II', m[off+8:off+16])
                sig = m[doff:doff+dsz]
                count = struct.unpack('>I', sig[8:12])[0]
                for i in range(count):
                    typ, elo = struct.unpack('>II', sig[12+i*8:12+i*8+8])
                    el = sig[elo:]
                    for mm in re.finditer(rb'<\?xml.*?</plist>', el, re.S):
                        try:
                            d = plistlib.loads(mm.group(0))
                            if isinstance(d, dict) and len(d) > 3:
                                found.append((typ, d))
                        except Exception as e:
                            pass
            off += csz
    return found

if __name__ == '__main__':
    res = main(sys.argv[1])
    print("found %d plist blobs" % len(res))
    for typ, d in res:
        print("=== type %d, %d keys ===" % (typ, len(d)))
        for k in sorted(d):
            print("%s = %r" % (k, d[k]))
