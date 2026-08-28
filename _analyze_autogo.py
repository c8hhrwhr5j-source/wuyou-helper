#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""分析 AutoGoRunner Runtime/app 的截屏+色彩相关字符串"""
import os, re, sys, struct

BIN = r"C:\TrollAutoTouch\_app_release_extract\Payload\AutoGoRunner.app\Runtime\app"

def extract_strings(data, min_len=4):
    strings = []
    cur = b''
    start = 0
    for i, b in enumerate(data):
        if 32 <= b <= 126:
            if not cur:
                start = i
            cur += bytes([b])
        else:
            if len(cur) >= min_len:
                strings.append((start, cur.decode('ascii', errors='ignore')))
            cur = b''
    if len(cur) >= min_len:
        strings.append((start, cur.decode('ascii', errors='ignore')))
    return strings

KEYWORDS = [
    'screenshot', 'screenShot', 'ScreenShot', 'snapshot', 'Snapshot',
    'IOSurface', 'w30r', 'w4rg', 'CVPixelBuffer', 'pixelFormat',
    'createScreenIOSurface', 'CGImage', 'UIGraphics', 'TransferSurface',
    'colorSpace', 'sRGB', 'DisplayP3', 'P3', 'WideGamut', 'Linear',
    'BITM', 'RGB10', 'RGB101010', 'BGRA', 'RGBA', 'ARGB',
    'IOSurfaceAccelerator', 'Transfer', 'frameBuffer', 'framebuffer',
    'pixel', 'Pixel', 'Screenshot', 'screenShot:', 'snapshot',
    'mobileFramebuffer', 'GetMainDisplay',
]

def main():
    data = open(BIN, 'rb').read()
    print(f"文件大小: {len(data):,} bytes")
    strings = extract_strings(data)
    print(f"提取字符串: {len(strings)} 条\n")

    # 1) 关键字过滤
    seen = set()
    print("=" * 80)
    print("关键字字符串 (截屏/色彩相关):")
    print("=" * 80)
    for off, s in strings:
        sl = s.lower()
        if any(k.lower() in sl for k in KEYWORDS):
            key = s
            if key in seen:
                continue
            seen.add(key)
            print(f"  0x{off:08x}: {s}")

    # 2) 端口上下文
    print("\n" + "=" * 80)
    print("8820/8080 端口上下文 (前后 60 字节可打印):")
    print("=" * 80)
    for pat in (b'8820', b'8080'):
        start = 0
        while True:
            pos = data.find(pat, start)
            if pos == -1:
                break
            ctx = data[max(0, pos - 40):pos + 60]
            ctx_s = ''.join(chr(b) if 32 <= b <= 126 else '.' for b in ctx)
            print(f"  [0x{pos:08x}] ...{ctx_s}...")
            start = pos + 1

    # 3) 常见 socket 字符串
    print("\n" + "=" * 80)
    print("socket/port 相关字符串:")
    print("=" * 80)
    for off, s in strings:
        sl = s.lower()
        if any(k in sl for k in ['bind(', 'listen(', 'accept(', 'htons', 'socket(', 'inet_addr',
                                  'port:', 'port=', 'localhost', '127.0.0.1', '0.0.0.0',
                                  'listen', 'noblock', 'setopt', 'sockaddr']):
            if len(s) < 200:
                print(f"  0x{off:08x}: {s}")

if __name__ == '__main__':
    main()
