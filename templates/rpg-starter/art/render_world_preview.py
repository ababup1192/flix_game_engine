import json, sys, zlib, struct, os

SPR, PAL, OUTDIR = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(OUTDIR, exist_ok=True)
doc = json.load(open(SPR))
pal = json.load(open(PAL))
col = {}
for ch, key in doc["legend"].items():
    r, g, b = pal[key]["rgb"]
    col[ch] = (int(r * 255 + 0.5), int(g * 255 + 0.5), int(b * 255 + 0.5))
BG = (40, 40, 48)


def png(path, w, h, px):
    raw = b"".join(b"\x00" + bytes(c for p in px[y] for c in p) for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)


def canvas(w, h):
    return [[BG] * w for _ in range(h)]


def blit(c, rows, ox, oy):
    for y, r in enumerate(rows):
        for x, ch in enumerate(r):
            if ch in col:
                c[oy + y][ox + x] = col[ch]


def scale(c, s):
    out = []
    for r in c:
        rr = [p for p in r for _ in range(s)]
        for _ in range(s):
            out.append(rr)
    return out


def frame(name, f):
    fr = doc["sprites"][name]["frames"]
    keys = list(fr.keys())
    return fr[keys[min(f, len(keys) - 1)]]


names = list(doc["sprites"].keys())
# 1) 一覧: 1 枚ずつ（全コマ）を 2px 間隔で
cols = 8
items = [(n, k) for n in names for k in doc["sprites"][n]["frames"]]
rowsn = (len(items) + cols - 1) // cols
c = canvas(cols * 18, rowsn * 18)
for i, (n, k) in enumerate(items):
    blit(c, doc["sprites"][n]["frames"][k], (i % cols) * 18 + 1, (i // cols) * 18 + 1)
png(f"{OUTDIR}/sheet_1x.png", cols * 18, rowsn * 18, c)
png(f"{OUTDIR}/sheet_6x.png", cols * 18 * 6, rowsn * 18 * 6, scale(c, 6))
print("sheet order:", [f"{n}:{k}" for n, k in items])

# 2) 3x3 敷き詰め（継ぎ目を見る）
tiled = [n for n in names if n in ("sea", "plains", "plains_b", "forest", "hills", "mountain", "mountain_b", "mountain_snow", "road")]
c = canvas(len(tiled) * 50, 50)
for i, n in enumerate(tiled):
    for ty in range(3):
        for tx in range(3):
            blit(c, frame(n, 0), i * 50 + 1 + tx * 16, 1 + ty * 16)
png(f"{OUTDIR}/tile3x3_4x.png", len(tiled) * 50 * 4, 50 * 4, scale(c, 4))

# 3) 試し組み 16x15
MAP = [
    "~~~~~MmAmM~~~~~~",
    "~~~~mMmAMmM~~~~~",
    "~~~h.mMXMm.h~~~~",
    "~~..,..=...FF.~~",
    "~~.FF..=..FFFF.~",
    "~..FFF.=..FFFF.~",
    "~..FFF.=,..FF,.~",
    "~~.....=......~~",
    "~~~..~~B~~~...~~",
    "~~~.~~~B~~~,..~~",
    "~~..~~~B~~...H.~",
    "~~.h.,.=..FF.~~~",
    "~~~.T===..FF.~~~",
    "~~~~...~~~..~~~~",
    "~~~~~~~~~~~~~~~~",
]
if len(sys.argv) > 4:
    MAP = [l.rstrip("\n") for l in open(sys.argv[4]) if l.strip()]
H, W = len(MAP), len(MAP[0])
SIMPLE = {".": "plains", ",": "plains_b", "M": "mountain", "m": "mountain_b", "A": "mountain_snow", "h": "hills", "=": "road", "T": "town", "X": "mine", "H": "shrine"}


def at(x, y):
    if 0 <= x < W and 0 <= y < H:
        return MAP[y][x]
    return "~"


def waterish(ch):
    return ch in "~B"


def pick(x, y):
    ch = MAP[y][x]
    if ch in SIMPLE:
        return SIMPLE[ch]
    if ch == "F":
        n, s_, e, w = at(x, y - 1) != "F", at(x, y + 1) != "F", at(x + 1, y) != "F", at(x - 1, y) != "F"
        if (n and s_) or (e and w):
            print("warn: thin forest at", x, y)
        v = ("n" if n else "s" if s_ else "") + ("e" if e else "w" if w else "")
        if len(v) == 2:
            return "forest_" + v
        if v:
            return "forest_edge_" + v
        for (dx, dy, nm) in ((1, -1, "ne"), (-1, -1, "nw"), (1, 1, "se"), (-1, 1, "sw")):
            if at(x + dx, y + dy) != "F":
                return "forest_in_" + nm
        return "forest"
    if ch == "B":
        return "bridge_v" if at(x, y - 1) != "~" or at(x, y + 1) != "~" else "bridge_h"
    n, s, e, w = (not waterish(at(x, y - 1)), not waterish(at(x, y + 1)), not waterish(at(x + 1, y)), not waterish(at(x - 1, y)))
    key = ("n" if n else "") + ("s" if s else "")
    key2 = ("e" if e else "") + ("w" if w else "")
    if (n and s) or (e and w):
        print("warn: narrow water at", x, y)
    if key and key2:
        return "sea_" + key[0] + key2[0]
    if key:
        return "sea_" + key[0]
    if key2:
        return "sea_" + key2[0]
    for (dx, dy, nm) in ((1, -1, "in_ne"), (-1, -1, "in_nw"), (1, 1, "in_se"), (-1, 1, "in_sw")):
        if not waterish(at(x + dx, y + dy)):
            return "sea_" + nm
    return "sea"


for f in (0, 1):
    c = [[BG] * (W * 16) for _ in range(H * 16)]
    for y in range(H):
        for x in range(W):
            blit(c, frame(pick(x, y), f), x * 16, y * 16)
    png(f"{OUTDIR}/compose_f{f}_1x.png", W * 16, H * 16, c)
    png(f"{OUTDIR}/compose_f{f}_3x.png", W * 48, H * 48, scale(c, 3))
print("done")
