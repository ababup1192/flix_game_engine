# engine のテストの資材 lightmap_srgb_chunks.png を作る（Blender が lightmap の PNG に付ける sRGB・gAMA・cHRM の chunk つきの 4 × 4 の RGB）。
#   python3 lightmap_srgb_chunks.py
# 画素 (x, y) の値は ((x * 60 + y * 10) % 256, 64, 200)。Texture3d.decode が chunk を掛けずに生の値を返すかを確かめる。
import os, struct, zlib
HERE = os.path.dirname(os.path.abspath(__file__))
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
w = h = 4
rows = b''.join(b'\x00' + bytes(v for x in range(w) for v in ((x * 60 + y * 10) % 256, 64, 200)) for y in range(h))
png = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'sRGB', b'\x00') + chunk(b'gAMA', struct.pack('>I', 45455))
       + chunk(b'cHRM', struct.pack('>8I', 31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000))
       + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))
open(os.path.join(HERE, 'testdata', 'lightmap_srgb_chunks.png'), 'wb').write(png)
