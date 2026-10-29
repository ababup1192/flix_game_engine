import json, zlib, struct, os
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PAL = json.load(open(ROOT + "/assets/rpg.palette.json"))
def rgb(key):
    r = PAL[key]["rgb"]; return tuple(int(round(c * 255)) for c in r)

# legend: 1 文字 -> 色票キー
LEG = {
 'k': 'ink',
 'g': 'fc00', 'G': 'fc10', 'h': 'fc2D',
 'w': 'fc02', 'b': 'fc12', 'B': 'fc21', 'c': 'fc31', 'W': 'fc30',
 'd': 'fc0A', 'e': 'fc1A', 'f': 'fc2A', 'F': 'fc29', 'L': 'fc39',
 'm': 'fc08', 'n': 'fc18', 'N': 'fc38',
 'o': 'fc17', 'O': 'fc27', 'y': 'fc28',
 'r': 'fc06', 's': 'fc16', 'S': 'fc26', 'R': 'fc07',
 'p': 'fc37', 'P': 'fc35', 'q': 'fc36',
 'v': 'fc03', 'V': 'fc0C', 'u': 'fc13', 'U': 'fc23',
}

class Cv:
    def __init__(s, w, h, fill='.'):
        s.w, s.h = w, h
        s.g = [[fill] * w for _ in range(h)]
    def copy(s):
        c = Cv(s.w, s.h); c.g = [r[:] for r in s.g]; return c
    def get(s, x, y, wrap=False):
        if wrap: x %= s.w; y %= s.h
        if 0 <= x < s.w and 0 <= y < s.h: return s.g[y][x]
        return None
    def set(s, x, y, ch, wrap=False):
        if wrap: x %= s.w; y %= s.h
        if 0 <= x < s.w and 0 <= y < s.h: s.g[y][x] = ch
    def stamp(s, x, y, rows, wrap=False, only_on=None):
        for j, row in enumerate(rows):
            for i, ch in enumerate(row):
                if ch in ' .': continue
                if only_on is not None and s.get(x + i, y + j, wrap) not in only_on: continue
                s.set(x + i, y + j, ch, wrap)
    def rect(s, x0, y0, x1, y1, ch):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1): s.set(x, y, ch)
    def rows(s): return [''.join(r) for r in s.g]

def from_rows(rows):
    c = Cv(len(rows[0]), len(rows))
    for y, r in enumerate(rows):
        assert len(r) == c.w, (r, len(r), c.w)
        for x, ch in enumerate(r): c.g[y][x] = ch
    return c

BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
def dith(x, y, level):  # level 0..16 -> True の割合
    return BAYER[y % 4][x % 4] < level

def png(path, grid_rgb, scale=1):
    h = len(grid_rgb); w = len(grid_rgb[0])
    raw = bytearray()
    for y in range(h * scale):
        raw.append(0)
        row = grid_rgb[y // scale]
        for x in range(w * scale):
            raw.extend(row[x // scale])
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w * scale, h * scale, 8, 2, 0, 0, 0)) \
        + chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b'')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'wb').write(data)

class Board:
    def __init__(s, w, h, bg=(40, 40, 52)):
        s.w, s.h = w, h; s.p = [[bg] * w for _ in range(h)]
    def put(s, x0, y0, rows):
        for j, r in enumerate(rows):
            for i, ch in enumerate(r):
                if ch == '.': continue
                x, y = x0 + i, y0 + j
                if 0 <= x < s.w and 0 <= y < s.h: s.p[y][x] = rgb(LEG[ch])
    def save(s, path, scale=1): png(path, s.p, scale)
