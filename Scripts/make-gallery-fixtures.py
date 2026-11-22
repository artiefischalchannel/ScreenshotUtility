#!/usr/bin/env python3
"""Generate disposable synthetic screenshots for native menu validation."""
from pathlib import Path
import struct, time, zlib, subprocess

folder = Path(__file__).resolve().parents[1] / '.build/gallery-validation/captures'
folder.mkdir(parents=True, exist_ok=True)

def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)

for n, (w, h) in enumerate([(1200, 750), (390, 844), (1500, 420), (800, 600), (850, 1100), (600, 600)] * 2):
    rows = []
    for y in range(h):
        row = bytearray()
        for x in range(w):
            color = (244, 246, 249)
            if y < h * .12:
                color = (40, 50, 70)
            elif n % 3 == 0:
                if w * .12 < x < w * .88 and any(h * t < y < h * (t + .035) for t in [.24, .34, .44, .54, .64, .74]):
                    color = (70 + 10 * n, 115, 200)
            elif n % 3 == 1:
                if w * .15 < x < w * .85 and h * .20 < y < h * .50:
                    color = (80, 100 + 10 * n, 220)
                elif w * .15 < x < w * .75 and any(h * t < y < h * (t + .025) for t in [.6, .68, .76, .84]):
                    color = (120, 130, 150)
            else:
                bar = int(x / (w / 7))
                if 1 <= bar <= 5 and x % (w / 7) < w * .1 and h * (.8 - bar * .1) < y < h * .85:
                    color = (70 + bar * 20, 150, 220 - bar * 20)
            row.extend(color)
        rows.append(b'\0' + row)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b'')
    file = folder / f'fixture-{n:02}.png'
    file.write_bytes(png)
    subprocess.run(['xattr', '-wx', 'local.screenshotutility.capturedAt', struct.pack('d', time.time() - n * 300).hex(), str(file)], check=True)
print(folder)
