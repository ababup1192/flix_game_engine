#!/usr/bin/env python3
# 水晶の坑道のタイルを作る台本。出力: assets/rpg.mine.sprite.json と debug/mine/*.png
import json, math, os, struct, zlib, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_JSON = os.path.join(ROOT, "assets/rpg.mine.sprite.json")
DBG = os.path.join(ROOT, "debug/mine")
os.makedirs(DBG, exist_ok=True)

PAL = json.load(open(os.path.join(ROOT, "assets/rpg.palette.json")))
def rgb(k):
    r, g, b = PAL[k]["rgb"]
    return (round(r * 255), round(g * 255), round(b * 255))

CH = {
    "ink": "k",
    "fc00": "a", "fc10": "A", "fc2D": "g",
    "fc08": "b", "fc17": "o", "fc27": "O", "fc18": "m", "fc38": "Y", "fc28": "G",
    "fc16": "r", "fc06": "R", "fc07": "s",
    "fc0C": "n", "fc03": "v", "fc13": "c", "fc23": "C", "fc33": "p", "fc3C": "q", "fc32": "P",
    "fc02": "w", "fc12": "W", "fc21": "x", "fc31": "X", "fc30": "h", "fc04": "u", "fc1C": "t",
}

BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
def bay(x, y):
    return (BAYER[y % 4][x % 4] + 0.5) / 16.0

def ramp_pick(v, x, y, ramp):
    v = max(0.0, min(0.9999, v))
    t = v * (len(ramp) - 1)
    i = int(t)
    f = t - i
    if i >= len(ramp) - 1:
        return ramp[-1]
    return ramp[i + 1] if f > bay(x, y) else ramp[i]

def hsh(x, y, s=0):
    n = (x * 374761393 + y * 668265263 + s * 2246822519) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFF) / 65535.0

TAU = 2 * math.pi
def per(x, y, terms, n=16):
    v = 0.0
    for (a, kx, ky, ph) in terms:
        v += a * math.cos(TAU * (kx * x + ky * y) / n + ph)
    return v

def new(w, h, fill=None):
    return [[fill] * w for _ in range(h)]

def stamp(img, tmpl, ox, oy, cmap, wrap=False):
    H = len(img); W = len(img[0])
    for j, row in enumerate(tmpl):
        for i, c in enumerate(row):
            if c == "." or c == " ":
                continue
            x, y = ox + i, oy + j
            if wrap:
                x %= W; y %= H
            elif not (0 <= x < W and 0 <= y < H):
                continue
            img[y][x] = cmap[c]

def remap(img, m):
    return [[(m.get(p, p) if p is not None else None) for p in row] for row in img]

# ---------------------------------------------------------------- 材質の段
# 段は 0=墨 1=暗 2=中 3=明 で描き、場面ごとの色票へ写す。
B1_WALL = {0: "ink", 1: "fc08", 2: "fc17", 3: "fc27"}
B1_FLOOR = {0: "ink", 1: "fc08", 2: "fc18", 3: "fc38"}
B3_WALL = {0: "ink", 1: "fc0C", 2: "fc03", 3: "fc23"}
B3_TOP = {0: "ink", 1: "fc0C", 2: "fc03"}
B3_FLOOR = {0: "ink", 1: "fc03", 2: "fc2D", 3: "fc10"}

def lv(img, m):
    return [[(m[p] if isinstance(p, int) else p) for p in row] for row in img]

# ---------------------------------------------------------------- 岩（ボロノイの塊）
def voronoi_cells(centers, x, y, n=16, sx=1.0, sy=1.0):
    best = []
    for idx, (cx, cy) in enumerate(centers):
        for ox in (-n, 0, n):
            for oy in (-n, 0, n):
                dx = (x - (cx + ox)) * sx
                dy = (y - (cy + oy)) * sy
                best.append((dx * dx + dy * dy, idx, dx, dy))
    best.sort()
    return best[0], best[1]

FACE_CENTERS_A = [(3, 3), (11, 2), (7, 8), (1, 11), (14, 9), (10, 13)]
FACE_CENTERS_B = [(5, 2), (13, 4), (2, 8), (9, 9), (14, 13), (5, 14)]

def rock_face(centers, seed, glow=None):
    """壁の正面。塊ごとに左上が光る。glow=(gx,gy,r) はたいまつの照り返し。"""
    img = new(16, 16)
    for y in range(16):
        for x in range(16):
            (d0, i0, dx, dy), (d1, _, _, _) = voronoi_cells(centers, x, y, sx=0.8, sy=1.25)
            edge = math.sqrt(d1) - math.sqrt(d0)
            if edge < 1.05:
                img[y][x] = 0
                continue
            r = math.sqrt(d0) + 0.01
            # 塊の中で左上ほど明るい
            v = 0.34 - 0.07 * dx - 0.09 * dy
            v += 0.06 * (edge > 2.5)
            v -= 0.10 * (edge < 1.8)  # 割れ目の縁は暗い
            # 下へ行くほど床の影に沈む
            v -= max(0, y - 11) * 0.06
            if glow:
                gx, gy, gr = glow
                dd = math.hypot(x - gx, (y - gy) * 1.1)
                v += max(0.0, 1 - dd / gr) * 0.55
            img[y][x] = ramp_pick(v, x, y, [0, 1, 2, 3]) if v < 0.7 else (3 if v > 0.82 else ramp_pick((v-0.5)/0.4, x, y, [2, 3]))
    # 上の縁（天井側の面と正面の境の角）は光を受ける
    for x in range(16):
        top = img[0][x]
        if top != 0 and hsh(x, 0, seed) > 0.25:
            img[0][x] = 2 if img[0][x] < 2 else img[0][x]
    # 床に接する下端は墨の接地
    for x in range(16):
        img[15][x] = 0 if hsh(x, 15, seed) > 0.2 else img[15][x]
    return img

def rock_top(seed=1):
    """壁の上の暗い面。ほとんど墨で、岩の頭だけ暗い段が浮く。"""
    centers = [(4, 4), (12, 3), (8, 10), (1, 12), (14, 12)]
    img = new(16, 16)
    for y in range(16):
        for x in range(16):
            (d0, i0, dx, dy), (d1, _, _, _) = voronoi_cells(centers, x, y)
            edge = math.sqrt(d1) - math.sqrt(d0)
            if edge < 1.2:
                img[y][x] = 0
                continue
            lit = -dx - dy
            if edge > 1.8 and lit > 2.2:
                img[y][x] = 2 if lit > 5.0 else 1
            elif edge > 1.8 and lit > 0.8 and bay(x, y) < 0.3:
                img[y][x] = 1
            else:
                img[y][x] = 0
    return img

# ---------------------------------------------------------------- 床
PEB_SMALL = ["lm", "mk"]
PEB_MID = [".lm.", "lmmk", ".kk."]
PEB_FLAT = [".lmm.", "lmmmk", ".kkk."]

def floor(seed, pebbles, lit=None, shade_top=0, base=0.86):
    img = new(16, 16)
    for y in range(16):
        for x in range(16):
            v = base + per(x, y, [(0.22, 1, 1, 0.7 + seed), (0.12, 2, -1, 1.9 + seed), (0.07, 0, 2, seed * 0.5)])
            v = min(v, 1.0) if not lit else v
            if lit:
                gx, gy, gr = lit
                dd = math.hypot((x - gx) * 0.85, (y - gy) * 1.25)
                v += max(0.0, 1 - dd / gr) * 0.75
            if shade_top:
                v -= max(0, shade_top - y) * 0.16
            if v <= 1.0:
                img[y][x] = ramp_pick(v, x, y, [0, 1])
            else:
                img[y][x] = ramp_pick((v - 1.0) * 1.6, x, y, [1, 2])
    cm = {"l": 3, "m": 2, "k": 0}
    for (t, px, py) in pebbles:
        stamp(img, t, px, py, cm)
    return img

# ---------------------------------------------------------------- 書き出しの入れ物
SPR = {}
def add(name, frames, kind, note, anchor=(0, 0), names=None):
    if isinstance(frames, list) and frames and isinstance(frames[0], list) and frames and isinstance(frames[0][0], list):
        fr = frames
    else:
        fr = [frames]
    if names is None:
        names = ["base"] if len(fr) == 1 else ["f%d" % i for i in range(len(fr))]
    SPR[name] = {"kind": kind, "note": note, "anchor": anchor, "frames": dict(zip(names, fr))}

# ================================================================ B1
rf_a = rock_face(FACE_CENTERS_A, 3)
rf_b = rock_face(FACE_CENTERS_B, 7)
rf_lit = rock_face(FACE_CENTERS_A, 3, glow=(7.5, 6, 9))
rt = rock_top()

add("rock_top", lv(rt, B1_WALL), "tile", "B1 の壁の上の面。墨が地で、岩の頭だけ暗い段が浮く。")
add("rock_face", lv(rf_a, B1_WALL), "tile", "B1 の岩肌の正面。塊ごとに左上が光り、下端は床へ沈む。")
add("rock_face_b", lv(rf_b, B1_WALL), "tile", "rock_face の変種（割れ目の並びが違う）。")
add("rock_face_lit", lv(rf_lit, B1_WALL), "tile", "たいまつを掛ける壁。中央ほど照り返しで明るく、左右の端は rock_face と同じ明るさへ戻る。")

fl_a = floor(0.0, [(PEB_SMALL, 4, 5)])
fl_b = floor(1.3, [(PEB_FLAT, 9, 2), (PEB_SMALL, 2, 9), (PEB_MID, 8, 11)])
fl_lit = floor(0.0, [(PEB_MID, 2, 9), (PEB_SMALL, 12, 12)], lit=(7.5, 0, 10))
fl_sh = floor(0.6, [(PEB_SMALL, 10, 9), (PEB_MID, 3, 11)], shade_top=4)
add("floor", lv(fl_a, B1_FLOOR), "tile", "B1 の土の床。墨のディザの濃淡で暗い面を作り、小石を 2〜3 個置く。")
add("floor_b", lv(fl_b, B1_FLOOR), "tile", "floor の小石の多い変種。")
add("floor_lit", lv(fl_lit, B1_FLOOR), "tile", "たいまつの真下の床。上辺の中央ほど明るい。")
add("floor_shadow", lv(fl_sh, B1_FLOOR), "tile", "壁の正面の真下の床。上の数行が壁の影で沈む。")

# 支柱: 岩肌の上に板の柱。木と岩は同じ色票（墨 / fc08 / fc17 / fc27）を分け合い、形で分ける。
def beam_tile():
    img = [row[:] for row in rf_b]
    # 柱の左右 1px は墨の落ち影
    for y in range(16):
        for x in range(4, 12):
            img[y][x] = 0
    # 柱本体 x=5..10
    for y in range(2, 16):
        img[y][5] = 3
        img[y][6] = 2
        img[y][7] = 2 if y % 5 != 3 else 1
        img[y][8] = 2
        img[y][9] = 1
        img[y][10] = 1 if y % 2 else 0
        img[y][11] = 0
        if y >= 3:
            img[y][12] = 0 if hsh(12, y, 4) > 0.4 else img[y][12]
    # 木目
    for y in (6, 7, 11, 12):
        img[y][7] = 1
    # 頭の横木 x=3..12, y=0..2
    for x in range(3, 13):
        img[0][x] = 3 if x < 11 else 2
        img[1][x] = 2 if x not in (3,) else 3
        img[2][x] = 0
    img[1][12] = 1
    img[0][12] = 2
    img[1][3] = 3
    # 釘
    img[1][5] = 0; img[1][10] = 0
    # 根元の接地
    img[15][4] = 0; img[15][11] = 0; img[15][12] = 0
    return img
add("beam", lv(beam_tile(), B1_WALL), "tile", "壁の正面に立つ板の支柱。岩肌の上に置いた 1 枚で、柱の右に墨の落ち影。")

# レール: 床の上に枕木（fc18）と鉄（fc10）。gauge は縦横とも 5px。
RAIL_PAL = {0: "ink", 1: "fc08", 2: "fc18", 4: "fc10"}
def rail_h_tile(end=False):
    img = floor(2.1, [])
    for x in range(16):
        if x % 4 in (1, 2):
            for y in range(3, 14):
                img[y][x] = 2 if (x % 4 == 1) else 2
            img[13][x] = 0
            img[3][x] = 2
        if x % 4 == 2:
            for y in range(4, 14):
                img[y][x] = 1 if y % 3 == 0 else 2
        if x % 4 == 3:
            for y in range(4, 14):
                img[y][x] = 0
    for x in range(16):
        img[5][x] = 4; img[6][x] = 0
        img[10][x] = 4; img[11][x] = 0
    if end:
        # 車止め: 右端に木の箱と鉄の帯。レールは x=12 で切れる
        for y in range(16):
            for x in range(13, 16):
                img[y][x] = floor(2.1, [])[y][x]
        tmpl = [
            ".kkkkk",
            "kAAAAAk",
            "k22222k",
            "k21112k",
            "k22222k",
            "k12221k",
            "k22222k",
            "k21112k",
            "k22222k",
            "kAAAAAk",
            "k11111k",
            ".kkkkkk",
        ]
        tmpl = [r.replace("2", "m").replace("1", "b").replace("A", "A") for r in tmpl]
        stamp(img, tmpl, 9, 2, {"k": 0, "m": 2, "b": 1, "A": 4})
    return img

def rail_v_tile(end=False):
    img = floor(3.7, [])
    for y in range(16):
        if y % 4 in (1, 2):
            for x in range(2, 14):
                img[y][x] = 2
            img[y][14] = 0
        if y % 4 == 2:
            for x in range(3, 14):
                img[y][x] = 1 if x % 4 == 0 else 2
        if y % 4 == 3:
            for x in range(3, 15):
                img[y][x] = 0
    for y in range(16):
        img[y][5] = 4; img[y][6] = 0
        img[y][10] = 4; img[y][11] = 0
    if end:
        base = floor(3.7, [])
        for y in range(0, 3):
            for x in range(16):
                img[y][x] = base[y][x]
        tmpl = [
            ".kkkkkkkkkk.",
            "kAmmmmmmmmAk",
            "kAmbmmmmbmAk",
            "kAmmmmmmmmAk",
            "kbbbbbbbbbbk",
            ".kkkkkkkkkk.",
        ]
        stamp(img, tmpl, 2, 0, {"k": 0, "m": 2, "b": 1, "A": 4})
    return img

add("rail_h", lv(rail_h_tile(), RAIL_PAL), "tile", "横のレール。枕木は 4px おきで、左右につないで継ぎ目が出ない。")
add("rail_v", lv(rail_v_tile(), RAIL_PAL), "tile", "縦のレール。")
add("rail_end", lv(rail_h_tile(True), RAIL_PAL), "tile", "横のレールの車止め（左から来て右で止まる）。")
add("rail_end_v", lv(rail_v_tile(True), RAIL_PAL), "tile", "縦のレールの車止め（下から来て上で止まる）。")

MINECART = [
    "................",
    "................",
    "....k..kk..k....",
    "..kkAkkaAkkAkk..",
    ".kAAAAAAAAAAAAk.",
    ".kAkkakkkAkkkak.",
    ".kAAAAAAAAAAAak.",
    ".kAaaaaaaaaaaak.",
    ".kAakaaaaaakaak.",
    ".kAaaaaaaaaaaak.",
    "..kaaaaaaaaaak..",
    "..kkkkkkkkkkkk..",
    "...kAk....kAk...",
    "...kak....kak...",
    "....k......k....",
    "................",
]
add("minecart", [[{"k": "ink", "a": "fc00", "A": "fc10"}.get(c) if c != "." else None for c in r] for r in MINECART],
    "prop", "鉄のトロッコ（横向き）。rail_h の上に重ね、車輪が手前のレールに乗る。鉱石の頭が縁から覗く。")

# ================================================================ 光
TORCH = [
    [
        "................",
        "........o.......",
        ".......oo.......",
        ".......oYo......",
        "......oYYo......",
        "......oYYYo.....",
        "......oYYYo.....",
        ".......oYo......",
        "......kkkkk.....",
        "......koOok.....",
        ".......kOk......",
        ".......kOk......",
        "......kkOkk.....",
        "......k.k.k.....",
        "......kkkkk.....",
        "................",
    ],
    [
        "................",
        "................",
        ".......o........",
        "......oo.o......",
        "......oYoo......",
        ".....oYYYo......",
        "......oYYo......",
        ".......oYo......",
        "......kkkkk.....",
        "......koOok.....",
        ".......kOk......",
        ".......kOk......",
        "......kkOkk.....",
        "......k.k.k.....",
        "......kkkkk.....",
        "................",
    ],
    [
        ".........o......",
        ".........o......",
        "........oo......",
        ".......oYo......",
        ".......oYYo.....",
        "......oYYYo.....",
        "......oYYo......",
        ".......oYo......",
        "......kkkkk.....",
        "......koOok.....",
        ".......kOk......",
        ".......kOk......",
        "......kkOkk.....",
        "......k.k.k.....",
        "......kkkkk.....",
        "................",
    ],
]
TCM = {"k": "ink", "o": "fc27", "Y": "fc38", "O": "fc27"}
add("torch", [[[TCM.get(c) for c in r] for r in f] for f in TORCH], "prop",
    "壁のたいまつ（3 コマで炎が揺れる）。rock_face_lit の上に重ねる。持ち手は墨、炎の外は fc27・芯は fc38。")

# 水晶: 左の面が光る（fc33）・中（fc23）・右の影（fc13）。
CRY_S = [
    "................",
    "................",
    "................",
    "......k.........",
    ".....kpk........",
    ".....kpCk.......",
    ".....kpCk..k....",
    "....kppCck.kk...",
    "..k.kppCck.kpk..",
    ".kpkkppCckkpCk..",
    ".kpCkppCckkpCck.",
    "kppCckpCckppCck.",
    "kppCckpCckppCck.",
    ".kpCckpCckpCck..",
    "..kkkkkkkkkkk...",
    "................",
]
CCM = {"k": "ink", "p": "fc33", "C": "fc23", "c": "fc13", "h": "fc30", "q": "fc3C"}
def crys_frames(t, glints):
    f0 = [[CCM.get(c) for c in r] for r in t]
    f1 = [row[:] for row in f0]
    for (x, y, k) in glints:
        f1[y][x] = CCM[k]
    return [f0, f1]
add("crystal_s", [[CCM.get(c) for c in r] for r in CRY_S], "prop", "床から生えた小さい水晶の群れ。左の面が光る。")

CRY_L = [
    "................",
    "........k.......",
    ".......kpk......",
    ".......kpCk.....",
    "......kppCk.....",
    "......kppCck....",
    "......kppCck....",
    "......kppCck....",
    ".....kpppCck....",
    ".....kpppCck....",
    ".....kpppCck....",
    ".k...kpppCck....",
    "kpk..kpppCck....",
    "kpCk.kpppCck....",
    "kpCk.kpppCck..k.",
    "kpCck.kppCck.kpk",
    "kppCk.kppCck.kpk",
    ".kpCck.kpCck.kpCk",
    ".kpCck.kpCckkppCk",
    ".kppCckkpCckkppCk",
    "..kpCckkpCckkpCck",
    "..kppCckkpCckpCck",
    "...kpCckkpCckpCk.",
    "...kppCckpCckpCk.",
    "....kpCckpCckpCk.",
    "....kpCckpCcpCck.",
    ".kk.kpCckpCcpCck.",
    "kpCkkpCckpCcpCk..",
    "kppCkpCckpCcpCk..",
    ".kkkkkkkkkkkkkk..",
    "..kkkkkkkkkkkk...",
    "................",
]
CRY_L = [r[:16] for r in CRY_L]
f0 = [[CCM.get(c) for c in r] for r in CRY_L]
f1 = [row[:] for row in f0]
for y in range(len(f1)):
    for x in range(16):
        if f1[y][x] == "fc13":
            f1[y][x] = "fc23"
        elif f1[y][x] == "fc33" and (y in (2, 3, 4) and hsh(x, y, 9) > 0.3):
            f1[y][x] = "fc3C"
add("crystal_l", [f0, f1], "prop", "大きい水晶（16×32）。2 コマで明滅する（f1 は影の面が中の段へ上がり、尖りの芯が fc3C で光る）。anchor は下半分の左上＝足元のマス。", anchor=(0, 16))

PILLAR = [
    "......k.........",
    ".....kpk........",
    ".....kpCk.......",
    "....kppCk.......",
    "....kppCck......",
    "....kppCck......",
    "...kpppCck......",
    "...kpppCck..k...",
    "...kpppCck.kpk..",
    "...kpppCck.kpCk.",
    "...kpkpCck.kpCk.",
    "...kppkCck.kpCk.",
    "...kpppkcckkpCck",
    "...kpppCkckkpCck",
    "...kpppCckkkpCck",
    "...kpppCck.kpCck",
    "...kpppCck.kpCck",
    "..kkpppCck.kpCck",
    ".kpkpppCck.kpCck",
    ".kpkpppCck.kpCk.",
    ".kpCkppCckkppCk.",
    ".kpCkppCckkpCck.",
    ".kpCkpppkckpCck.",
    ".kpCkppCkkkpCck.",
    "kppCkppCcckpCck.",
    "kppCkppCcckpCck.",
    "kpCckppCcckpCck.",
    "kpCckppCcckpCck.",
    "kkccckkcckkkcck.",
    ".kkccckcccccckk.",
    "..kkkkkkkkkkkk..",
    "................",
]
def pillar():
    return [[CCM.get(c) for c in r] for r in PILLAR]
add("crystal_pillar", pillar(), "prop", "背の高い水晶の柱（16×32）。太い柱と細い柱が寄り添い、根元は影の面の段で沈む。anchor は下半分の左上。", anchor=(0, 16))

# ================================================================ 階段・宝箱・がれき
def stairs_down(m):
    img = floor(0.9, [])
    # 穴の枠 x=1..14, y=1..14
    for y in range(1, 15):
        for x in range(1, 15):
            img[y][x] = 0
    steps = [(2, 4, 3), (5, 7, 2), (8, 10, 2), (11, 13, 1)]
    for (y0, y1, c) in steps:
        for y in range(y0, y1):
            for x in range(3 + (y0 // 3), 13 - (y0 // 6)):
                img[y][x] = c if y == y0 else (1 if c >= 2 else 0)
        # 段の上の縁の光
        for x in range(3 + (y0 // 3), 13 - (y0 // 6)):
            img[y0][x] = c
        img[y0][3 + (y0 // 3)] = 3 if c >= 2 else 2
    # 左右の壁の面（左は光を受け、右は影）
    for y in range(2, 14):
        img[y][2] = 2 if y < 8 else 1
        img[y][13] = 0
    for x in range(1, 15):
        img[1][x] = 3 if x < 8 else 2
    img[1][1] = 0; img[1][14] = 0
    return lv(img, m)

STAIRS_UP = [
    "0000000000000000",
    "0033333333333300",
    "0032222222222100",
    "0000000000000000",
    "0033333333332100",
    "0022222222221100",
    "0000000000000000",
    "0032222222221100",
    "0021111111111000",
    "0000000000000000",
    "0022222222211000",
    "0011111111110000",
    "0000000000000000",
    "0011111111100000",
    "0010101010100000",
    "0000000000000000",
]
def stairs_up(m):
    img = floor(1.7, [])
    base = img
    out = [[int(c) for c in r] for r in STAIRS_UP]
    # 左右の 1 列は床へ戻して、周りの床と継ぐ
    for y in range(16):
        out[y][0] = base[y][0]
        out[y][15] = base[y][15]
    return lv(out, m)

add("stairs_down", stairs_down(B1_FLOOR), "tile", "下り階段。床に開いた穴の中を段が奥へ降り、深いほど墨に沈む。")
add("stairs_up", stairs_up(B1_FLOOR), "tile", "上り階段。上へ行くほど段の頭が明るい（上の階の光）。")

CHEST = [
    "................",
    "................",
    "................",
    "...kkkkkkkkkk...",
    "..kGGGooooooGk..",
    "..kGooooooooGk..",
    "..kGbbkGGkbbGk..",
    "..kkkkGGGGkkkk..",
    "..kGooGkkGooGk..",
    "..kGookGGkobGk..",
    "..kGooooooobGk..",
    "..kGooooooobGk..",
    "..kGooooooobGk..",
    "..kGbbbbbbbbGk..",
    "..kkkkkkkkkkkk..",
    "...kkkkkkkkkk...",
]
CHEST_OPEN = [
    "....kkkkkkkk....",
    "...kGooooooGk...",
    "...kGbbbbbbGk...",
    "..kGbbbbbbbbGk..",
    "..kGbbbbbbbbGk..",
    "..kkkkkkkkkkkk..",
    "..kGooooooooGk..",
    "..kkbbbbbbbbbk..",
    "..kkkbkbkbkbbk..",
    "..kkkkkkkkkkbk..",
    "..kkkkkkkkkkbk..",
    "..kGooooooooGk..",
    "..kGookGkoobGk..",
    "..kGbbbbbbbbGk..",
    "..kkkkkkkkkkkk..",
    "...kkkkkkkkkk...",
]
assert all(len(r) == 16 for r in CHEST + CHEST_OPEN)
CHM = {"k": "ink", "O": "fc28", "o": "fc17", "b": "fc08", "G": "fc28", "Y": "fc28"}
add("chest", [[CHM.get(c) for c in r] for r in CHEST], "prop", "宝箱（閉）。明るい木 fc17 の丸い蓋に、左上のつや・四隅の金具・中央の大きい錠前（金 fc28 と鍵穴の墨）。床に重ねる。")
add("chest_open", [[CHM.get(c) for c in r] for r in CHEST_OPEN], "prop", "宝箱（開・空）。蓋が後ろへ跳ね上がって箱の上に立ち（蓋の裏は暗い fc08）、蓋は奥へ傾いて上ほど細い。箱の口は 4 行の深さで、奥の内壁 fc08 から底の墨へ沈み、右の内壁だけが光を受ける。錠前の金具は前に垂れ下がる。閉じた方より暗く、背が高い。")

RUBBLE = [
    "................",
    "................",
    "................",
    "................",
    "................",
    "......kkk.......",
    ".....k322k......",
    "....k32221k.....",
    "..kkk22111kkk...",
    ".k32k2111kk22k..",
    ".k3221k1k32211k.",
    "k32211k0k22111k.",
    "k22111kk221111k.",
    ".k1111kk11110k..",
    "..kkkkkkkkkkkk..",
    "................",
]
def rubble(m):
    return [[(m[int(c)] if c.isdigit() else ("ink" if c == "k" else None)) for c in r] for r in RUBBLE]
add("rubble", rubble(B1_WALL), "prop", "崩れた岩の山。床に重ねる。岩ごとに左上が光る。")

# ================================================================ 仕掛け
# レバー: 壁の正面（rock_face）に重ねる鉄の座金と、赤い握りの付いた柄。up / down の 2 コマ。
def lever_frame(up):
    img = new(16, 16)
    for y in range(6, 14):
        for x in range(3, 13):
            edge = x in (3, 12) or y in (6, 13)
            img[y][x] = "ink" if edge else ("fc10" if (x == 4 or y == 7) else "fc00")
    for (x, y) in ((5, 9), (10, 9), (5, 12), (10, 12)):
        img[y][x] = "ink"
    ys = range(3, 10) if up else range(9, 15)
    for y in ys:
        img[y][6] = "ink"; img[y][7] = "fc10"; img[y][8] = "fc00"; img[y][9] = "ink"
    for (x, y) in ((7, 9), (8, 9), (7, 10), (8, 10)) if up else ((7, 8), (8, 8), (7, 9), (8, 9)):
        img[y][x] = "ink"
    ky = (0, 1, 2) if up else (13, 14, 15)
    for x in range(6, 10):
        img[ky[0] if up else ky[2]][x] = "ink"
    for y in (ky[1], ky[2]) if up else (ky[0], ky[1]):
        img[y][5] = "ink"; img[y][10] = "ink"
        for x in range(6, 10):
            img[y][x] = "fc16"
    return img
add("lever", [lever_frame(True), lever_frame(False)], "prop",
    "壁のレバー（up / down の 2 コマ）。rock_face の上に重ねる。鉄の座金（fc00・左上の縁 fc10）と赤い握り（fc16）。up は柄が座金の上へ立って握りが上端に、down は柄が下へ倒れて握りが座金の下に出る。",
    names=["up", "down"])

# 鉄格子: 床に重ねる。棒の間は透明で、向こうの床が見える。4px おきなので横に並べても継ぎ目が出ない。
def gate_bars():
    img = new(16, 16)
    for y in range(1, 15):
        for x in range(16):
            m = x % 4
            if m == 1:
                img[y][x] = "fc10"
            elif m == 2:
                img[y][x] = "fc00"
            elif m == 3:
                img[y][x] = "ink"
    # 棒の先の槍の穂
    for x in range(16):
        if x % 4 == 1:
            img[0][x] = "ink"; img[0][x + 1] = "ink"
            img[1][x] = "fc10"; img[1][x + 1] = "fc10"
    # 横の帯（上と下）
    for x in range(16):
        img[3][x] = "fc10"; img[4][x] = "fc00"; img[5][x] = "ink"
        img[11][x] = "fc10"; img[12][x] = "fc00"; img[13][x] = "ink"
    # 帯の鋲
    for x in range(1, 16, 4):
        img[4][x] = "ink"; img[12][x] = "ink"
    # 床への接地: 足元は墨の影
    for x in range(16):
        img[14][x] = "ink" if x % 4 in (1, 2, 3) else img[14][x]
        img[15][x] = "ink" if x % 4 in (2, 3) else None
    return img
add("gate_bars", gate_bars(), "prop",
    "鉄格子（床に重ねる・通れない）。灰の棒が 4px おきに立ち、上と下に横の帯と鋲、棒の先は槍の穂。棒の間は透明で向こうの床が見え、横に並べても継ぎ目が出ない。開いたら描かない。")

# 分岐のレール: 西から来たレールが北か南へ曲がる。rail_h（西の辺）・rail_v（北と南の辺）と同じ位置で継ぐ。
# 今つながっている側だけ鉄が光り（fc10）、もう片方は墨の溝だけが残る。
def rail_switch(to_north):
    img = floor(5.3, [])
    def curve_pts(cx, cy):
        pts = []
        for r_ in (5.5, 10.5):
            for i in range(200):
                a = (math.pi / 2) * i / 199
                x = cx + r_ * math.cos(a) * (1 if cx < 8 else 1)
                y = cy + (r_ * math.sin(a) if cy < 8 else -r_ * math.sin(a))
                pts.append((r_, int(round(x)), int(round(y))))
        return pts
    def sleepers(cx, cy):
        for k in range(1, 6):
            a = (math.pi / 2) * (k - 0.5) / 5
            for rr in [i * 0.25 for i in range(14, 49)]:
                x = int(round(cx + rr * math.cos(a)))
                y = int(round(cy + (rr * math.sin(a) if cy < 8 else -rr * math.sin(a))))
                if 0 <= x < 16 and 0 <= y < 16:
                    img[y][x] = 2
    N = (-0.5, -0.5)
    S = (-0.5, 15.5)
    on, off = (N, S) if to_north else (S, N)
    sleepers(*off)
    sleepers(*on)
    # 外れている側: 墨の溝
    for (r_, x, y) in curve_pts(*off):
        if 0 <= x < 16 and 0 <= y < 16:
            img[y][x] = 0
    # つながっている側: 鉄（fc10）と、その右下の墨の影
    for (r_, x, y) in curve_pts(*on):
        if 0 <= x < 16 and 0 <= y < 16:
            img[y][x] = 4
            if y + 1 < 16 and img[y + 1][x] != 4:
                img[y + 1][x] = 0
    # 西の辺は rail_h と同じ並び（y=5,10 が鉄・y=6,11 が墨）に合わせる
    for x in range(0, 2):
        for (yy, c) in ((5, 4 if True else 0), (6, 0), (10, 4), (11, 0)):
            img[yy][x] = c
    if not to_north:
        pass
    # 分かれ目の舌（ポイント）: 動く刃先の先に赤ではなく鉄の明るい 1px
    return img
add("rail_switch", [lv(rail_switch(True), RAIL_PAL), lv(rail_switch(False), RAIL_PAL)], "tile",
    "分岐のレール（north / south の 2 コマ）。西の辺で rail_h、北と南の辺で rail_v とつながる。今つながっている側の曲がりだけ鉄が光り（fc10）、外れている側は墨の溝だけが残る。",
    names=["north", "south"])

# 割れた床（落とし穴）: floor と同じ地に、まん中の墨の穴と、持ち上がった床の欠片。欠片の左上の縁は fc38 で光る。
CRACK = [
    "................",
    "....k......k....",
    ".....k....k.....",
    "..k..kkYYk.k....",
    "...kkYmmmkkk..k.",
    "....kYmkkkkYk.k.",
    "...kYmkkkkkkmk..",
    "..kkmkkkkkkkmbk.",
    "....kkkkkkkkbk..",
    "...kYkkkkkkkbk..",
    "..k.kmkkkkkbk.k.",
    ".k...kmmkkkk..k.",
    "....k.kbbkk.k...",
    "...k...kk...k...",
    "..k.....k.......",
    "................",
]
def floor_crack():
    img = floor(0.0, [])
    stamp(img, CRACK, 0, 0, {"k": 0, "Y": 3, "m": 2, "b": 1})
    return img
assert all(len(r) == 16 for r in CRACK)
add("floor_crack", lv(floor_crack(), B1_FLOOR), "tile",
    "割れた床（落とし穴・B1/B2 の暖色）。floor と同じ地に、まん中の墨の穴と放射に走るひび。持ち上がった欠片の左上の縁が fc38 で光り、明かりの中で「割れている」と読める。")

# 飛び石: lake_dark に重ねる。平たい灰の石の上面（fc2D・左上の縁 fc10）、側面は墨のディザで厚みを見せ、水際に fc12 のさざ波。
# 同じ形を並べると判子に見えるので、大きさ・位置・欠けの違う 3 つを作る。
def stepping_stone(cx, cy, rx, ry, notch=None, pebble=None):
    img = new(16, 16)
    def top(x, y, cx=cx, cy=cy, rx=rx, ry=ry):
        return ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1.0
    side = 2
    for y in range(16):
        for x in range(16):
            t = top(x, y)
            s = any(top(x, y - k) for k in range(1, side + 1))
            if notch and math.hypot(x - notch[0], y - notch[1]) < notch[2]:
                t = False; s = False
            if t:
                nx, ny = (x - cx) / rx, (y - cy) / ry
                lit = -nx * 0.7 - ny * 0.7
                img[y][x] = "fc10" if lit > 0.62 else "fc2D"
            elif s:
                img[y][x] = "ink" if bay(x, y) < 0.7 else "fc2D"
    # 輪郭は墨
    out = [r[:] for r in img]
    for y in range(16):
        for x in range(16):
            if img[y][x] is None:
                continue
            nb = [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
            if any(not (0 <= a < 16 and 0 <= b < 16) or img[b][a] is None for a, b in nb):
                out[y][x] = "ink"
    # 水際のさざ波（石の左右の下の端にだけ、間欠に）
    by = int(round(cy + ry + side))
    for x in range(16):
        if out[by][x] is None and by + 1 < 16:
            continue
    for dx in (-rx - 1, rx + 1):
        x0 = int(round(cx + dx))
        if not (0 <= x0 < 16 and 0 <= x0 + (1 if dx > 0 else -1) < 16):
            continue
        for k in range(2):
            xx = x0 + (k if dx > 0 else -k)
            yy = by - 1 + k
            if 0 <= xx < 16 and 0 <= yy < 16 and out[yy][xx] is None:
                out[yy][xx] = "fc12"
    if pebble:
        px, py = pebble
        stamp(out, [".k.", "kAk", "kgk"], px, py, {"k": "ink", "A": "fc10", "g": "fc2D"})
    return out

add("stepping_stone", stepping_stone(7.5, 7.0, 5.6, 3.2), "prop",
    "地底湖の飛び石（lake_dark の上に重ねる）。平たい灰の石の上面（fc2D・左上の縁 fc10）、側面は墨のディザで厚みを見せ、左右の水際に fc12 のさざ波。")
add("stepping_stone_b", stepping_stone(6.5, 6.5, 4.6, 2.8, pebble=(11, 9)), "prop",
    "stepping_stone の変種（小さめの石が左に寄り、右下に小石が 1 つ）。")
add("stepping_stone_c", stepping_stone(8.0, 7.5, 6.4, 3.4, notch=(12.5, 4.5, 2.6)), "prop",
    "stepping_stone の変種（横に長く、右上が欠けた石）。")

# 石碑: B3 の寒色。四角い頭に笠石を載せた灰の石の板が、段の付いた台座に立つ。刻み文字は水晶と同じ淡い紫（fc23）で光る。
# 光は左上から（左の縁 fc10・右の側面は墨のディザ）。tablet は 1 マスに収まる形、tablet_l は 2 マスの高さの大きい碑。
def tablet_img(h, glyph_rows, crystal):
    img = new(16, h)
    def put(x, y, c):
        if 0 <= x < 16 and 0 <= y < h:
            img[y][x] = c
    base_y = h - 3
    top_y = 2 if h == 16 else 4
    # 笠石
    for x in range(2, 14):
        put(x, top_y - 2, "ink")
        put(x, top_y - 1, "fc10" if x < 12 else "fc2D")
    put(1, top_y - 1, "ink"); put(14, top_y - 1, "ink")
    for x in range(1, 15):
        put(x, top_y, "ink")
    # 板
    for y in range(top_y + 1, base_y):
        put(2, y, "ink"); put(13, y, "ink")
        put(3, y, "fc10")
        for x in range(4, 11):
            put(x, y, "fc2D")
        put(11, y, "ink" if (x + y) % 2 else "fc2D")
        put(11, y, "fc2D" if y % 2 else "ink")
        put(12, y, "ink" if y % 2 else "fc2D")
    # 刻み文字: 光る 1 行（fc23）の下に墨の影
    for (gy, pat) in glyph_rows:
        for i, c in enumerate(pat):
            if c == "C":
                put(4 + i, gy, "fc23")
                put(4 + i, gy + 1, "ink")
    # 水晶のはめ込み（大きい碑の頭）
    if crystal:
        stamp(img, [".k.", "kpk", "kCk", ".k."], 6, top_y + 1, {"k": "ink", "p": "fc23", "C": "fc23"})
    # 台座
    for x in range(1, 15):
        put(x, base_y, "ink")
        put(x, base_y + 1, "fc10" if x < 4 else ("fc2D" if x < 13 else "ink"))
        put(x, base_y + 2, "ink")
    put(0, base_y + 1, "ink"); put(15, base_y + 1, "ink")
    return img

TAB_S_GLYPHS = [(4, "CC.CCC."), (7, "C.CC.CC"), (10, "CCC.C..")]
add("tablet", tablet_img(16, TAB_S_GLYPHS, False), "prop",
    "石碑（B3 の寒色・1 マス）。笠石を載せた四角い灰の板が台座に立ち、3 行の刻み文字が水晶と同じ淡い紫（fc23）で光る。光は左上から（左の縁 fc10・右の側面は墨のディザ）。")
TAB_L_GLYPHS = [(11, "CC.CCC."), (14, "C.CC.CC"), (17, "CCC.C.C"), (20, "C.CCC.."), (23, ".CC.CC.")]
add("tablet_l", tablet_img(32, TAB_L_GLYPHS, True), "prop",
    "大きい石碑（16×32・B3 の寒色）。笠石の下に水晶の目をはめ、5 行の刻み文字が淡い紫（fc23）で光る。anchor は下半分の左上＝足元のマス。",
    anchor=(0, 16))

# ================================================================ 押せる岩・床のスイッチ・レールの曲がり・縦のトロッコ
# 押せる岩: 丸い 1 個。がれき（ごつごつの塊の山）と分けるため、輪郭はなめらかな円、面は光の向きで 3 段に硬く割り、
# 左上に 2px のつや、足元に横長の墨の接地影。
def boulder(m):
    img = new(16, 16)
    cx, cy, r = 7.5, 7.8, 5.7
    for y in range(16):
        for x in range(16):
            dx, dy = (x - cx) / r, (y - cy) / r
            d2 = dx * dx + dy * dy
            if d2 <= 1.0:
                nz = math.sqrt(max(0.0, 1 - d2))
                lit = (-dx * 0.55 - dy * 0.65 + nz * 0.55)
                if lit > 0.78:
                    img[y][x] = 3
                elif lit > 0.32:
                    img[y][x] = 2
                else:
                    img[y][x] = 1
    out = [r_[:] for r_ in img]
    for y in range(16):
        for x in range(16):
            if img[y][x] is None:
                continue
            nb = [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
            if any(not (0 <= a < 16 and 0 <= b < 16) or img[b][a] is None for a, b in nb):
                out[y][x] = 0
    # つや
    out[5][5] = 3; out[5][6] = 3; out[6][5] = 3
    # 下の縁の照り返しを 1 段落とす（影の側は暗い段のまま）
    # 接地影（岩の下にはみ出す横長の墨）
    for x in range(3, 13):
        out[14][x] = 0
    for x in range(5, 11):
        out[15][x] = 0
    return [[(m[p] if p is not None else None) for p in row] for row in out]
add("boulder", boulder(B1_WALL), "prop",
    "押せる岩（B1/B2 の暖色）。なめらかな丸い 1 個で、面は fc08 / fc17 / fc27 の 3 段に硬く割り、左上につや、足元に横長の墨の接地影。ごつごつの塊の山の rubble と形で分かれる。")
add("boulder_deep", boulder(B3_WALL), "prop",
    "押せる岩（B3 の寒色）。boulder と同じ形を fc0C / fc03 / fc23 で塗る。")

# 床のスイッチ: up = 床から 2px 持ち上がった四角い石の板（上面・光る左上の縁・手前の厚み・右下の影）。
# down = 床と同じ高さに沈み、縁の光が消えて墨の溝だけが残る。まん中の刻みの印はどちらにも残す。
def plate(m, floor_img, up):
    img = [r_[:] for r_ in floor_img]
    x0, x1 = 1, 14
    y0, y1 = (2, 11) if up else (4, 13)
    if up:
        # 右下の落ち影
        for y in range(y0 + 1, y1 + 4):
            if y < 16:
                img[y][x1 + 1] = 0
        for x in range(x0 + 1, x1 + 2):
            if y1 + 3 < 16:
                img[y1 + 3][x] = 0
        # 手前の厚み（2 行）
        for x in range(x0, x1 + 1):
            img[y1 + 1][x] = 1
            img[y1 + 2][x] = 0
        img[y1 + 1][x0] = 0; img[y1 + 1][x1] = 0
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            edge = x in (x0, x1) or y in (y0, y1)
            if edge:
                img[y][x] = 0
            elif up and (y == y0 + 1 or x == x0 + 1):
                img[y][x] = 3
            elif not up and (y == y0 + 1 or x == x0 + 1):
                img[y][x] = 1
            else:
                img[y][x] = 2
    # 刻みの印（菱形）
    mx, my = 7, (y0 + y1) // 2
    for (dx, dy) in ((0, -2), (1, -2), (-1, -1), (2, -1), (-1, 0), (2, 0), (0, 1), (1, 1)):
        img[my + dy][mx + dx] = 0 if up else 0
    if up:
        img[my - 1][mx] = 1; img[my - 1][mx + 1] = 1
    return lv(img, m)

PLATE_FLOOR_B1 = floor(0.0, [])
PLATE_FLOOR_B3 = floor(0.4, [], base=0.17)
add("plate", [plate(B1_FLOOR, PLATE_FLOOR_B1, True), plate(B1_FLOOR, PLATE_FLOOR_B1, False)], "tile",
    "床のスイッチ（B1/B2 の暖色・up / down の 2 コマ）。up は floor から 2px 持ち上がった四角い石の板で、左上の縁が fc38 で光り、手前に厚み、右下に墨の影。down は床と同じ高さへ沈み、縁の光と厚みが消え、墨の溝の内側の上と左に暗い段の影が落ちる。まん中の菱形の刻みはどちらにも残る。岩を載せる時は boulder を重ねる。",
    names=["up", "down"])
add("plate_deep", [plate(B3_FLOOR, PLATE_FLOOR_B3, True), plate(B3_FLOOR, PLATE_FLOOR_B3, False)], "tile",
    "床のスイッチ（B3 の寒色・up / down）。plate と同じ形を floor_deep の地と fc2D / fc10 で塗る。",
    names=["up", "down"])

# レールの曲がり: 名前の 2 方向の辺で rail_h（東西の辺）・rail_v（南北の辺）と同じ位置（鉄 5 と 10）で継ぐ。
def rail_corner(dirs):
    img = floor(6.1 + len(dirs), [])
    cx = 15.5 if "e" in dirs else -0.5
    cy = -0.5 if "n" in dirs else 15.5
    sx = -1 if cx > 8 else 1
    sy = 1 if cy < 8 else -1
    # 枕木（曲がりに沿って放射に）
    for k in range(6):
        a = (math.pi / 2) * (k + 0.5) / 6
        for i in range(12, 50):
            rr = i * 0.25
            x = int(round(cx + sx * rr * math.cos(a)))
            y = int(round(cy + sy * rr * math.sin(a)))
            if 0 <= x < 16 and 0 <= y < 16:
                img[y][x] = 2
    for r_ in (5.5, 10.5):
        for i in range(240):
            a = (math.pi / 2) * i / 239
            x = int(round(cx + sx * r_ * math.cos(a)))
            y = int(round(cy + sy * r_ * math.sin(a)))
            if 0 <= x < 16 and 0 <= y < 16:
                img[y][x] = 4
    # 鉄の右下に墨の影
    out = [r_[:] for r_ in img]
    for y in range(16):
        for x in range(16):
            if img[y][x] == 4:
                for (a, b) in ((x + 1, y), (x, y + 1)):
                    if a < 16 and b < 16 and img[b][a] != 4:
                        out[b][a] = 0
    # 辺の 2px は rail_h / rail_v と同じ並びにそろえる
    if "e" in dirs or "w" in dirs:
        xs = (14, 15) if "e" in dirs else (0, 1)
        for x in xs:
            for (yy, c) in ((5, 4), (6, 0), (10, 4), (11, 0)):
                out[yy][x] = c
    if "n" in dirs or "s" in dirs:
        ys = (0, 1) if "n" in dirs else (14, 15)
        for y in ys:
            for (xx, c) in ((5, 4), (6, 0), (10, 4), (11, 0)):
                out[y][xx] = c
    return lv(out, RAIL_PAL)
for d in ("ne", "nw", "se", "sw"):
    add("rail_corner_" + d, rail_corner(d), "tile",
        "レールの曲がり角（%s と %s の辺へつながる）。辺の上では rail_h / rail_v と同じ位置で鉄が継ぐ。" %
        ({"n": "北", "s": "南"}[d[0]], {"e": "東", "w": "西"}[d[1]]))

# 縦向きのトロッコ: 手前（南）を向いた鉄の箱。上の口から鉱石が覗き、前の面に鋲、左右に車輪の縁が見える。
def minecart_v():
    img = new(16, 16)
    def put(x, y, c):
        if 0 <= x < 16 and 0 <= y < 16:
            img[y][x] = c
    # 鉱石の頭
    for x in range(6, 10):
        put(x, 1, "ink")
    put(5, 2, "ink"); put(10, 2, "ink")
    for x in range(6, 10):
        put(x, 2, "fc00")
    put(6, 2, "fc10")
    # 箱の縁（上の口）
    for x in range(3, 13):
        put(x, 3, "ink")
    for y in range(4, 7):
        put(3, y, "ink"); put(12, y, "ink")
        put(4, y, "fc10"); put(11, y, "fc00")
        for x in range(5, 11):
            put(x, y, "ink")
    put(6, 4, "fc00"); put(7, 5, "fc00"); put(9, 4, "fc00"); put(8, 5, "fc10")
    for x in range(4, 12):
        put(x, 4 - 0, img[4][x])
    for x in range(3, 13):
        put(x, 7, "fc10" if x < 12 else "ink")
    put(3, 7, "ink")
    # 前の面（下へ細る）
    for y in range(8, 13):
        inset = 0 if y < 11 else 1
        xa, xb = 3 + inset, 12 - inset
        put(xa, y, "ink"); put(xb, y, "ink")
        for x in range(xa + 1, xb):
            put(x, y, "fc10" if x == xa + 1 else "fc00")
    for (x, y) in ((5, 11), (10, 11)):
        put(x, y, "ink")
    for x in range(4, 12):
        put(x, 13, "ink")
    # 左右の車輪（縁が見える）
    for (wx, lit) in ((1, True), (13, False)):
        for y in range(9, 14):
            put(wx, y, "ink"); put(wx + 1, y, "ink")
        for y in range(10, 13):
            put(wx + (1 if lit else 0), y, "fc10" if lit else "fc00")
    put(1, 14, None); put(14, 14, None)
    for x in range(3, 13):
        put(x, 14, "ink")
    return img
add("minecart_v", minecart_v(), "prop",
    "縦向きのトロッコ（rail_v の上に重ねる）。手前を向いた鉄の箱で、上の口から鉱石が覗き、前の面に鋲、左右に車輪の縁。色は minecart と同じ墨 / fc00 / fc10。")

# ================================================================ B3
rf_d_a = rock_face(FACE_CENTERS_A, 3)
rf_d_b = rock_face(FACE_CENTERS_B, 7)
add("rock_top_deep", lv(rock_top(), B3_TOP), "tile", "B3 の壁の上の面（寒色）。")
add("rock_face_deep", lv(rf_d_a, B3_WALL), "tile", "B3 の岩肌の正面。紫の暗い段と灰で、光は水晶の照り返しの淡い紫。")
add("rock_face_b_deep", lv(rf_d_b, B3_WALL), "tile", "rock_face_deep の変種。")
fd_a = floor(0.4, [(PEB_MID, 9, 3), (PEB_SMALL, 3, 11)], base=0.17)
fd_b = floor(2.2, [(PEB_SMALL, 4, 3), (PEB_FLAT, 8, 9), (PEB_SMALL, 13, 13)], base=0.17)
add("floor_deep", lv(fd_a, B3_FLOOR), "tile", "B3 の岩の床。墨の地に紫のディザ。")
add("floor_b_deep", lv(fd_b, B3_FLOOR), "tile", "floor_deep の小石の多い変種。")
add("stairs_up_deep", stairs_up(B3_FLOOR), "tile", "B3 の上り階段。")
add("stairs_down_deep", stairs_down(B3_FLOOR), "tile", "B3 の下り階段。")
add("rubble_deep", rubble(B3_WALL), "prop", "B3 のがれき。")

# 水晶のかけらが光る床（2 コマ）。床の色票を {墨, fc03, fc23, fc33} に寄せ、小石は置かない。
def floor_crystal():
    base = floor(1.1, [], base=0.17)
    m = {0: "ink", 1: "fc03", 2: "fc03", 3: "fc23"}
    img = lv(base, m)
    shards = [
        ["..p", ".pC", "kCk"],
        ["p.", "Ck"],
        [".p.", "pCC", "kkk"],
    ]
    cm = {"p": "fc33", "C": "fc23", "k": "ink"}
    pos = [(0, 3, 2), (2, 11, 5), (1, 6, 11), (1, 13, 12)]
    # かけらのまわりは光で紫のディザが濃くなる
    for (si, sx, sy) in pos:
        for y in range(16):
            for x in range(16):
                d = math.hypot(x - sx - 1, y - sy - 1)
                if d < 3.2 and img[y][x] == "ink" and bay(x, y) < 0.55:
                    img[y][x] = "fc03"
    f0 = [r[:] for r in img]
    for (si, sx, sy) in pos:
        stamp(f0, shards[si], sx, sy, cm)
    f1 = [r[:] for r in f0]
    # f1: 光る点が隣のかけらへ移る
    for (si, sx, sy) in pos:
        for y in range(16):
            for x in range(16):
                pass
    f1[3][4] = "fc23"; f1[4][3] = "fc33"
    f1[12][7] = "fc33"; f1[11][7] = "fc23"
    f1[12][14] = "fc23"; f1[13][13] = "fc33"
    f1[5][13] = "fc23"; f1[6][12] = "fc33"
    return [f0, f1]
add("floor_crystal", floor_crystal(), "tile", "水晶のかけらが光る床（2 コマ）。かけらのまわりだけ紫が濃く、f1 で光る点が移る。")

# ---------------------------------------------------------------- 地底湖
# 水の色票 {墨, fc02, fc12, fc21}。岸の土地は {墨, fc03} だけ（floor_deep と同じディザの式）。
WATER_RAMP = ["ink", "fc02"]
def water_px(x, y, fr):
    v = 0.42 + per(x, y, [(0.22, 1, 0, 0.3), (0.12, 1, 2, 2.1), (0.08, 2, 1, 4.0)])
    return ramp_pick(v, x, y, WATER_RAMP)

RIPPLES = [  # (x, y, len) は f0。f1 は x+2
    (2, 3, 3), (10, 7, 4), (5, 12, 2),
]
GLINTS = [(10, 2), (3, 6), (13, 9)]

def lake_base(fr, glints=True, ripples=None):
    img = new(16, 16)
    for y in range(16):
        for x in range(16):
            img[y][x] = water_px(x, y, fr)
    for (x, y, L) in (ripples or RIPPLES):
        sx = (x + 2 * fr) % 16
        for i in range(L):
            img[y][(sx + i) % 16] = "fc12"
        img[(y + 1) % 16][(sx + 1) % 16] = "ink" if L > 2 else img[(y + 1) % 16][(sx + 1) % 16]
    for i, (x, y) in enumerate(GLINTS if glints else []):
        if (i + fr) % 2 == 0:
            img[y][x] = "fc21"
        else:
            img[y][(x + 1) % 16] = "fc12"
    return img

def land_px(x, y):
    p = fd_a  # floor_deep と同じ式
    v = floor(0.4, [])[y][x]
    return {0: "ink", 1: "fc03", 2: "fc03", 3: "fc03"}[v]

LAND = floor(0.4, [], base=0.17)
def landc(x, y):
    return "ink" if LAND[y][x] == 0 else "fc03"

def shore(fr, n=False, s=False, e=False, w=False, inner=None):
    img = lake_base(fr, glints=False)
    # 岸の土地の幅
    LN, LS, LE, LW = 3, 2, 3, 3
    def is_land(x, y):
        if n and y < LN + (1 if (x * 7) % 5 == 0 else 0): return True
        if s and y >= 16 - LS - (1 if (x * 5) % 7 == 0 else 0): return True
        if e and x >= 16 - LE - (1 if (y * 3) % 5 == 0 else 0): return True
        if w and x < LW + (1 if (y * 7) % 6 == 0 else 0): return True
        if inner:
            cx = {"ne": 16, "nw": -1, "se": 16, "sw": -1}[inner]
            cy = {"ne": -1, "nw": -1, "se": 16, "sw": 16}[inner]
            if math.hypot(x - cx, y - cy) < 4.6: return True
        return False
    land = [[is_land(x, y) for x in range(16)] for y in range(16)]
    for y in range(16):
        for x in range(16):
            if land[y][x]:
                img[y][x] = landc(x, y)
    # 岸の縁: 土地のすぐ外の 1px は墨（岸の切り立ち）。北と西の岸は切り立ちの面（fc03）も見せる。
    out = [r[:] for r in img]
    for y in range(16):
        for x in range(16):
            if land[y][x]:
                continue
            up = y > 0 and land[y - 1][x]
            dn = y < 15 and land[y + 1][x]
            lf = x > 0 and land[y][x - 1]
            rt = x < 15 and land[y][x + 1]
            if up:
                out[y][x] = "fc03"   # 北岸の切り立ちの面（光の側）
                if y + 1 < 16 and not land[y + 1][x]:
                    out[y + 1][x] = "ink"
                if y + 2 < 16 and not land[y + 2][x] and bay(x, y + 2) < 0.5:
                    out[y + 2][x] = "ink"
            elif dn:
                out[y][x] = "fc12" if bay(x, y) < 0.75 - 0.25 * fr else "fc02"  # 南岸に寄せる波
            elif lf:
                out[y][x] = "fc03" if y % 3 else "ink"
                if x + 1 < 16 and not land[y][x + 1]:
                    out[y][x + 1] = "ink" if bay(x + 1, y) < 0.5 else out[y][x + 1]
            elif rt:
                out[y][x] = "ink"
    # 土地の縁取り（水に面した土地の 1px は墨）
    for y in range(16):
        for x in range(16):
            if not land[y][x]:
                continue
            nb = [(x, y - 1), (x, y + 1), (x - 1, y), (x + 1, y)]
            if any(0 <= a < 16 and 0 <= b < 16 and not land[b][a] for a, b in nb):
                # 南岸の土地の上端は光を受ける縁
                if s and y < 15 and not land[y - 1][x] if y > 0 else False:
                    out[y][x] = "fc03"
                else:
                    out[y][x] = "ink"
    return out

def lake_set():
    names = {
        "lake_dark": {},
        "lake_dark_n": {"n": True}, "lake_dark_s": {"s": True},
        "lake_dark_e": {"e": True}, "lake_dark_w": {"w": True},
        "lake_dark_ne": {"n": True, "e": True}, "lake_dark_nw": {"n": True, "w": True},
        "lake_dark_se": {"s": True, "e": True}, "lake_dark_sw": {"s": True, "w": True},
        "lake_dark_in_ne": {"inner": "ne"}, "lake_dark_in_nw": {"inner": "nw"},
        "lake_dark_in_se": {"inner": "se"}, "lake_dark_in_sw": {"inner": "sw"},
    }
    notes = {
        "lake_dark": "地底湖の水（2 コマ）。墨と fc02 のディザの深み、fc12 のさざ波が f1 で 2px 流れ、fc21 の光が瞬く。",
        "lake_dark_n": "北が岸の水。岸の切り立ちが見え、その下に影の帯。",
        "lake_dark_s": "南が岸の水。岸に寄せる波が fc12 で光る。",
        "lake_dark_e": "東が岸の水。", "lake_dark_w": "西が岸の水。",
        "lake_dark_ne": "外角（北と東が岸）。", "lake_dark_nw": "外角（北と西が岸）。",
        "lake_dark_se": "外角（南と東が岸）。", "lake_dark_sw": "外角（南と西が岸）。",
        "lake_dark_in_ne": "内角（北東の角だけ岸）。", "lake_dark_in_nw": "内角（北西の角だけ岸）。",
        "lake_dark_in_se": "内角（南東の角だけ岸）。", "lake_dark_in_sw": "内角（南西の角だけ岸）。",
    }
    for nm, kw in names.items():
        frs = [shore(f, **kw) if kw else lake_base(f) for f in (0, 1)]
        add(nm, frs, "tile", notes[nm])
lake_set()
RIPPLES_B = [(7, 1, 2), (0, 6, 3), (11, 10, 3), (3, 14, 4)]
add("lake_dark_b", [lake_base(f, ripples=RIPPLES_B) for f in (0, 1)], "tile", "lake_dark の変種（さざ波の並びが違う）。広い湖で交互に置くと格子が消える。")

# ---------------------------------------------------------------- ボスの扉 48x48
def boss_door():
    W = H = 48
    img = new(W, H)
    cx, cy = 23.5, 22.0
    Ro, Ri = 23.5, 15.5
    for y in range(H):
        for x in range(W):
            dx, dy = x - cx, y - cy
            if y <= cy:
                r = math.hypot(dx, dy)
                inside_outer = r <= Ro
                inside_inner = r <= Ri
            else:
                inside_outer = abs(dx) <= Ro
                inside_inner = abs(dx) <= Ri
            if inside_outer and not inside_inner:
                img[y][x] = "frame"
            elif inside_inner:
                img[y][x] = "door"
    out = new(W, H)
    # 枠の石組み
    for y in range(H):
        for x in range(W):
            t = img[y][x]
            if t is None:
                continue
            dx, dy = x - cx, y - cy
            if t == "frame":
                if y <= cy:
                    ang = math.atan2(-dy, dx)  # 0..pi
                    r = math.hypot(dx, dy)
                    seg = int(ang / (math.pi / 9))
                    fa = (ang / (math.pi / 9)) - seg
                    rr = (r - Ri) / (Ro - Ri)
                    if fa < 0.09 or rr < 0.06 or rr > 0.94:
                        out[y][x] = "ink"
                    else:
                        # 左上ほど光る
                        v = 0.55 - 0.45 * (dx / Ro) * 0.5 + 0.35 * (-dy / Ro) * 0.5 + (0.25 if rr < 0.4 else 0) - (0.25 if fa > 0.8 else 0)
                        out[y][x] = ramp_pick(v, x, y, ["fc2D", "fc00", "fc10"])
                else:
                    side = -1 if dx < 0 else 1
                    lx = abs(dx) - Ri
                    blk = int((y - cy + (3 if side > 0 else 0)) // 7)
                    fy = (y - cy + (3 if side > 0 else 0)) % 7
                    if fy < 1 or lx < 0.6 or lx > Ro - Ri - 0.6:
                        out[y][x] = "ink"
                    else:
                        v = 0.62 - 0.08 * fy - (0.2 if side > 0 else 0) + (0.2 if lx < 3 and side < 0 else 0) - max(0, y - 42) * 0.05
                        out[y][x] = ramp_pick(v, x, y, ["fc2D", "fc00", "fc10"])
            else:
                # 扉: 2 枚の石の扉。中央の合わせ目と横の帯。
                if abs(dx) < 0.6:
                    out[y][x] = "ink"
                    continue
                lx = int(abs(dx))
                if y in (31, 41):
                    out[y][x] = "ink"
                elif y in (30, 40):
                    out[y][x] = "fc00"
                elif lx % 5 == 0:
                    out[y][x] = "ink"
                elif lx % 5 == 1 and dx < 0 or lx % 5 == 4 and dx > 0:
                    out[y][x] = "fc00"
                else:
                    out[y][x] = "fc2D"
    # 帯の鋲
    for yy in (30, 40):
        for xx in (11, 17, 30, 36):
            out[yy][xx] = "fc10"; out[yy + 1][xx] = "ink"
    # 内枠の影（扉が奥へ引っ込んでいる）
    for y in range(H):
        for x in range(W):
            if img[y][x] == "door":
                nb = [(x - 1, y), (x, y - 1)]
                if any(0 <= a < W and 0 <= b < H and img[b][a] == "frame" for a, b in nb):
                    out[y][x] = "ink"
                    if x + 1 < W and img[y][x + 1] == "door" and abs(x + 1 - cx) > 0.6:
                        out[y][x + 1] = "ink" if bay(x + 1, y) < 0.5 else out[y][x + 1]
    # 水晶の封印: 合わせ目にかぶさる水晶の群れと、扉を這う水晶の筋
    seal = [
        "...........k...........",
        "..........kpk..........",
        ".........kppCk.........",
        "....k....kppCk....k....",
        "...kpk..kpppCck..kpk...",
        "...kpCk.kpphCck.kpCk...",
        "..kppCckkppqCckkppCck..",
        "..kppCckkppqCckkppCck..",
        ".kpppCckkppCCckkpppCck.",
        "kppppCcckppCCckkppCCck.",
        "kpppCCcckppCCcckpppCcck",
        ".kppCCcckpppCcckppCCck.",
        "..kpCCcckpppCcckpCCck..",
        "...kkkkkkkkkkkkkkkkk...",
    ]
    stamp(out, seal, 13, 22, {"k": "ink", "p": "fc33", "C": "fc23", "c": "fc13", "h": "fc33", "q": "fc33"})
    # 水晶の筋（扉の上を這う）
    veins = [(10, 27), (9, 26), (8, 25), (8, 24), (7, 23), (37, 27), (38, 26), (39, 25), (39, 24), (40, 23),
             (12, 36), (11, 37), (10, 38), (35, 36), (36, 37), (37, 38), (23, 18), (24, 17), (24, 16), (23, 15)]
    for (x, y) in veins:
        if out[y][x] not in (None,):
            out[y][x] = "fc13"
    for (x, y) in [(7, 22), (40, 22), (23, 14), (10, 39), (37, 39)]:
        out[y][x] = "fc23"
    # 要石: アーチの頂に水晶の目
    ks = ["kkkkk", "kCpCk", "kpqck", "kCcCk", "kkkkk"]
    stamp(out, ks, 21, 0, {"k": "ink", "p": "fc33", "C": "fc23", "c": "fc13", "q": "fc33"})
    # 足元の敷居
    for x in range(W):
        if out[47][x] is not None:
            out[47][x] = "ink"
        if out[46][x] is not None and img[46][x] == "door":
            out[46][x] = "fc2D" if x % 2 else "ink"
    return out
add("boss_door", boss_door(), "prop", "水晶で封じられたボスの間の扉（48×48）。灰の石のアーチに 2 枚の石の扉、合わせ目を水晶の群れがふさぐ。anchor は左上（3×3 マスの左上）。四隅の外は透明で、後ろの rock_top が見える。")

# ================================================================ 書き出し
def to_rows(img):
    rows = []
    for r in img:
        s = ""
        for p in r:
            s += "." if p is None else CH[p]
        rows.append(s)
    return rows

used = set()
for nm, sp in SPR.items():
    for fn, fr in sp["frames"].items():
        for r in fr:
            for p in r:
                if p is not None:
                    used.add(p)
legend = {CH[k]: k for k in sorted(used)}

doc = {
    "version": 1,
    "title": "水晶の坑道のタイル",
    "note": "坑道 B1（板で補強した坑道・レール・たいまつ。土と木の暖色）と B3（水晶が光る地底湖・封じられたボスの扉。青紫の寒色）のタイルと小物。B3 で色を変えた物は名前の末尾が _deep。光は左上から、坑道の中ではたいまつと水晶が光源。1 枚のタイルは墨＋3 色まで。台本は art/rpg.mine.gen.py（描き直すときは台本を直し、DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 art/rpg.mine.gen.py で流す）。",
    "paletteFile": "assets/rpg.palette.json",
    "entityId": "rpg.mine.sprites",
    "legend": legend,
    "sprites": {},
}
for nm, sp in SPR.items():
    doc["sprites"][nm] = {
        "note": sp["note"],
        "kind": sp["kind"],
        "anchor": {"x": float(sp["anchor"][0]), "y": float(sp["anchor"][1])},
        "frames": {fn: to_rows(fr) for fn, fr in sp["frames"].items()},
    }
with open(OUT_JSON, "w") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
    f.write("\n")

# ================================================================ 確かめの PNG
def write_png(path, grid):
    h = len(grid); w = len(grid[0])
    raw = b""
    for row in grid:
        raw += b"\x00" + b"".join(bytes(c) for c in row)
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)

def scale(grid, k):
    out = []
    for r in grid:
        rr = []
        for c in r:
            rr += [c] * k
        for _ in range(k):
            out.append(rr[:])
    return out

BGC = (40, 44, 52)
def canvas(w, h, c=BGC):
    return [[c] * w for _ in range(h)]

def blit(cv, img, ox, oy):
    for j, r in enumerate(img):
        for i, p in enumerate(r):
            if p is None:
                continue
            y, x = oy + j, ox + i
            if 0 <= y < len(cv) and 0 <= x < len(cv[0]):
                cv[y][x] = rgb(p)

def fr(nm, f=None):
    frs = SPR[nm]["frames"]
    return frs[f] if f else list(frs.values())[0]

# 一覧
names = list(SPR.keys())
cols = 10
cellw, cellh = 52, 52
rowsN = (sum(len(SPR[n]["frames"]) for n in names) + cols - 1) // cols
cv = canvas(cols * cellw, rowsN * cellh)
i = 0
for n in names:
    for f in SPR[n]["frames"].values():
        cx, cy = (i % cols) * cellw + 2, (i // cols) * cellh + 2
        blit(cv, f, cx, cy)
        i += 1
write_png(os.path.join(DBG, "sheet_1x.png"), cv)
write_png(os.path.join(DBG, "sheet_4x.png"), scale(cv, 4))
def zoom_sheet(path, nms, k=6, cols=8):
    items = [(n, f) for n in nms for f in SPR[n]["frames"].values()]
    cw, chh = 50, 50
    rr = (len(items) + cols - 1) // cols
    cv2 = canvas(cols * cw, rr * chh)
    for i, (n, f) in enumerate(items):
        blit(cv2, f, (i % cols) * cw + 1, (i // cols) * chh + 1)
    write_png(path, scale(cv2, k))
allnm = list(SPR.keys())
b1n = [n for n in allnm if not n.endswith("_deep") and not n.startswith("lake") and "crystal" not in n and n != "boss_door"]
zoom_sheet(os.path.join(DBG, "zoom_b1.png"), b1n)
zoom_sheet(os.path.join(DBG, "zoom_b3.png"), [n for n in allnm if n not in b1n and not n.startswith("lake")])
zoom_sheet(os.path.join(DBG, "zoom_lake.png"), [n for n in allnm if n.startswith("lake")], k=5, cols=8)

# 3x3 の継ぎ目
def tile3(nm, f=None):
    t = fr(nm, f)
    cv = canvas(48, 48)
    for a in range(3):
        for b in range(3):
            blit(cv, t, a * 16, b * 16)
    return cv
seam_names = ["rock_top", "rock_face", "floor", "floor_b", "rail_h", "rail_v", "lake_dark", "floor_deep", "rock_face_deep", "floor_crystal", "rock_top_deep"]
cv = canvas(len(seam_names) * 52, 52)
for k, n in enumerate(seam_names):
    blit_src = tile3(n)
    for y in range(48):
        for x in range(48):
            cv[y + 2][k * 52 + 2 + x] = blit_src[y][x]
write_png(os.path.join(DBG, "seams_4x.png"), scale(cv, 4))

# ---------------------------------------------------------------- 試し組み
def compose(rows, legend_map, overlays, frame=0, path=None):
    H = len(rows); W = len(rows[0])
    cv = canvas(W * 16, H * 16)
    # 1: 地
    walls = set("#")
    def is_wall(x, y):
        if not (0 <= x < W and 0 <= y < H):
            return True
        return rows[y][x] in walls
    for y in range(H):
        for x in range(W):
            c = rows[y][x]
            nm = legend_map(c, x, y, is_wall)
            if isinstance(nm, tuple):
                n, f = nm
            else:
                n, f = nm, None
            frs = list(SPR[n]["frames"].values())
            t = frs[frame % len(frs)] if f is None else SPR[n]["frames"][f]
            blit(cv, t, x * 16, y * 16)
    # 2: 物
    for (n, tx, ty) in sorted(overlays, key=lambda o: o[2]):
        frs = list(SPR[n]["frames"].values())
        t = frs[frame % len(frs)]
        ax, ay = SPR[n]["anchor"]
        blit(cv, t, tx * 16 - int(ax), ty * 16 - int(ay))
    if path:
        write_png(path + "_1x.png", cv)
        write_png(path + "_3x.png", scale(cv, 3))
    return cv

# B1: # 壁 . 床 , 床の変種 = 横レール | 縦レール E 車止め T たいまつ(壁) > 下り階段 L 明るい床
B1 = [
    "################",
    "################",
    "##T#B##B##T#B###",
    "##.....#....,###",
    "##.,...#.....###",
    "##..####...=====",
    "##..#..#...|##.#",
    "###.#..T...|#..#",
    "#...#,.....|#..#",
    "#.,.###....|...#",
    "#....BT.B..|.>.#",
    "##..,...,..E...#",
    "###.....########",
    "################",
    "################",
]
def b1_map(c, x, y, is_wall):
    below_floor = not is_wall(x, y + 1)
    if c in "#TB":
        if below_floor:
            if c == "T":
                return "rock_face_lit"
            if c == "B":
                return "beam"
            return "rock_face" if (x * 3 + y) % 4 else "rock_face_b"
        return "rock_top"
    under_wall = is_wall(x, y - 1)
    lit = y > 0 and B1[y - 1][x] == "T"
    if c == "=":
        return "rail_h"
    if c == "|":
        return "rail_v"
    if c == "E":
        return "rail_end_v"
    if c == ">":
        return "stairs_down"
    if lit:
        return "floor_lit"
    if under_wall:
        return "floor_shadow"
    if c == "," or hsh(x, y, 5) > 0.75:
        return "floor_b"
    return "floor"
b1_over = [("torch", 2, 2), ("torch", 10, 2), ("torch", 7, 7), ("torch", 6, 10),
           ("chest", 2, 10), ("rubble", 9, 3), ("minecart", 13, 5), ("chest_open", 14, 8), ("rubble", 5, 12)]
# T と B の位置の補正（壁の正面にだけ置く）
compose(B1, b1_map, b1_over, 0, os.path.join(DBG, "b1_layout"))

# B3: ~ 湖  * 水晶の床  D 扉(3x3 の左上)  < 上り階段
B3 = [
    "################",
    "######DDD#######",
    "######DDD#######",
    "##....DDD.....##",
    "#.............*#",
    "#..*~~~~~~~...##",
    "#..~~~~~~~~~...#",
    "#.~~~~~~~~~~~..#",
    "#.~~~~~~~~~~~*.#",
    "#..~~~~~~~~~...#",
    "#*..~~~~~~~..<.#",
    "##.....*.......#",
    "###....#####...#",
    "################",
    "################",
]
def b3_map(c, x, y, is_wall):
    if c in "#D":
        if c == "D":
            return "rock_top_deep"
        if not is_wall(x, y + 1) and B3[y + 1][x] != "D":
            return "rock_face_deep" if (x * 5 + y) % 3 else "rock_face_b_deep"
        return "rock_top_deep"
    if c == "~":
        def wt(a, b):
            return 0 <= b < len(B3) and 0 <= a < len(B3[0]) and B3[b][a] == "~"
        n, s, e, w = not wt(x, y - 1), not wt(x, y + 1), not wt(x + 1, y), not wt(x - 1, y)
        key = ("n" if n else "") + ("s" if s else "")
        key2 = ("e" if e else "") + ("w" if w else "")
        if n and e: return "lake_dark_ne"
        if n and w: return "lake_dark_nw"
        if s and e: return "lake_dark_se"
        if s and w: return "lake_dark_sw"
        if n: return "lake_dark_n"
        if s: return "lake_dark_s"
        if e: return "lake_dark_e"
        if w: return "lake_dark_w"
        if not wt(x + 1, y - 1): return "lake_dark_in_ne"
        if not wt(x - 1, y - 1): return "lake_dark_in_nw"
        if not wt(x + 1, y + 1): return "lake_dark_in_se"
        if not wt(x - 1, y + 1): return "lake_dark_in_sw"
        return "lake_dark_b" if (x + y * 2) % 3 == 0 else "lake_dark"
    if c == "*":
        return "floor_crystal"
    if c == "<":
        return "stairs_up_deep"
    return "floor_b_deep" if (x * 7 + y * 3) % 5 == 0 else "floor_deep"
b3_over = [("boss_door", 6, 1), ("crystal_l", 2, 4), ("crystal_pillar", 13, 7), ("crystal_pillar", 1, 9),
           ("crystal_s", 9, 11), ("crystal_s", 14, 4), ("crystal_l", 12, 11), ("rubble_deep", 3, 11), ("crystal_s", 5, 3)]
compose(B3, b3_map, b3_over, 0, os.path.join(DBG, "b3_layout"))
compose(B3, b3_map, b3_over, 1, os.path.join(DBG, "b3_layout_f1"))


# ---------------------------------------------------------------- 仕掛けの試し組み
B1G = [
    "################",
    "################",
    "######.|.#######",
    "######.|.#######",
    "###L##.|.##T####",
    "#......|.......#",
    "#......|.......#",
    "#======S.......#",
    "#......|.......#",
    "#......|.......#",
    "######.|.#######",
    "######.|.#######",
    "######.|.#######",
    "################",
    "################",
]
def b1g_map(c, x, y, is_wall):
    if c in "#LT":
        if not is_wall(x, y + 1):
            if c == "T":
                return "rock_face_lit"
            return "rock_face" if (x * 3 + y) % 4 else "rock_face_b"
        return "rock_top"
    if c == "S":
        return ("rail_switch", "north")
    if c == "=":
        return "rail_h"
    if c == "|":
        return "rail_v"
    if B1G[y - 1][x] == "T":
        return "floor_lit"
    if is_wall(x, y - 1):
        return "floor_shadow"
    return "floor_b" if hsh(x, y, 5) > 0.75 else "floor"
b1g_over = [("lever", 3, 4), ("torch", 11, 4), ("minecart", 3, 7),
            ("gate_bars", 6, 10), ("gate_bars", 7, 10), ("gate_bars", 8, 10)]
compose(B1G, b1g_map, b1g_over, 0, os.path.join(DBG, "gimmick_b1"))
# レバーを下ろして分岐が南へ切り替わった後（北の格子が閉じ、南が開く）
def b1g_map_s(c, x, y, is_wall):
    r = b1g_map(c, x, y, is_wall)
    return ("rail_switch", "south") if r == ("rail_switch", "north") else r
b1g_over_s = [("lever", 3, 4), ("torch", 11, 4), ("minecart", 3, 7),
              ("gate_bars", 6, 4), ("gate_bars", 7, 4), ("gate_bars", 8, 4)]
cv_s = compose(B1G, b1g_map_s, b1g_over_s, 0, None)
# lever の down コマで上書き
blit(cv_s, fr("rock_face", None), 3 * 16, 4 * 16)
blit(cv_s, SPR["lever"]["frames"]["down"], 3 * 16, 4 * 16)
write_png(os.path.join(DBG, "gimmick_b1_south_1x.png"), cv_s)
write_png(os.path.join(DBG, "gimmick_b1_south_3x.png"), scale(cv_s, 3))

B2G = [
    "################",
    "#......#.......#",
    "#.####.#.#####.#",
    "#.#....X.#.....#",
    "#.#.####.#.###.#",
    "#...#....X...#.#",
    "###.#.##.###.#.#",
    "#...#..X.....#.#",
    "#.###.####.#.#.#",
    "#.....#....#...#",
    "#.###.#.####.###",
    "#...#.X......#.#",
    "###.#.#####..#.#",
    "#.....#........#",
    "################",
]
def b2g_map(c, x, y, is_wall):
    if c == "#":
        return "rock_face" if not is_wall(x, y + 1) else "rock_top"
    if c == "X":
        return "floor_crack"
    if is_wall(x, y - 1):
        return "floor_shadow"
    return "floor_b" if hsh(x, y, 8) > 0.8 else "floor"
cv2 = compose(B2G, b2g_map, [], 0, None)
# たいまつの明かり: 先頭（8,7 のマス）のまわり 3 マスだけ見え、外は墨。境はディザでぼかす。
INK = rgb("ink")
lcx, lcy = 8 * 16 + 8, 7 * 16 + 8
for y in range(len(cv2)):
    for x in range(len(cv2[0])):
        d = math.hypot(x - lcx, y - lcy) / 16.0
        v = (3.5 - d) / 0.9
        if v <= bay(x, y):
            cv2[y][x] = INK
write_png(os.path.join(DBG, "gimmick_b2_1x.png"), cv2)
write_png(os.path.join(DBG, "gimmick_b2_3x.png"), scale(cv2, 3))

B3G = [r for r in B3]
_b3_keep = B3
b3g_over = [("boss_door", 6, 1), ("crystal_l", 2, 4), ("crystal_pillar", 1, 9), ("crystal_l", 13, 6),
            ("tablet", 11, 4), ("crystal_s", 9, 11), ("rubble_deep", 3, 11)]
b3g_over += [("stepping_stone", 7, y) for y in range(5, 11)]
compose(B3G, b3_map, b3g_over, 0, os.path.join(DBG, "gimmick_b3"))

zoom_sheet(os.path.join(DBG, "zoom_gimmick.png"), ["lever", "gate_bars", "rail_switch", "floor_crack", "stepping_stone", "tablet"], k=6, cols=8)


# 岩とスイッチの部屋・曲がったレールの輪（B1 の暖色）
B1P = [
    "################",
    "################",
    "#..............#",
    "#.F====G...e...#",
    "#.|....|...|...#",
    "#.|....H===S...#",
    "#.|........|...#",
    "#.J========L...#",
    "#..............#",
    "#..............#",
    "#..............#",
    "#..............#",
    "#..............#",
    "################",
    "################",
]
B1P_RAIL = {"F": "rail_corner_se", "G": "rail_corner_sw", "H": "rail_corner_ne", "J": "rail_corner_ne",
            "L": "rail_corner_nw", "=": "rail_h", "|": "rail_v", "e": "rail_end_v"}
def b1p_map(c, x, y, is_wall):
    if c == "#":
        return ("rock_face" if (x * 3 + y) % 4 else "rock_face_b") if not is_wall(x, y + 1) else "rock_top"
    if c == "S":
        return ("rail_switch", "south")
    if c in B1P_RAIL:
        return B1P_RAIL[c]
    if is_wall(x, y - 1):
        return "floor_shadow"
    return "floor_b" if hsh(x, y, 5) > 0.75 else "floor"
def plate_ov(name, fname, tx, ty):
    return (name + "@" + fname, tx, ty)
cvp = compose(B1P, b1p_map, [("minecart", 6, 7), ("minecart_v", 2, 5), ("rubble", 13, 11)], 0, None)
blit(cvp, SPR["plate"]["frames"]["up"], 4 * 16, 10 * 16)
blit(cvp, SPR["plate"]["frames"]["down"], 9 * 16, 10 * 16)
blit(cvp, SPR["boulder"]["frames"]["base"], 5 * 16, 10 * 16)
blit(cvp, SPR["boulder"]["frames"]["base"], 9 * 16, 10 * 16)
blit(cvp, SPR["boulder"]["frames"]["base"], 3 * 16, 12 * 16)
blit(cvp, SPR["rubble"]["frames"]["base"], 13 * 16, 11 * 16)
write_png(os.path.join(DBG, "push_b1_1x.png"), cvp)
write_png(os.path.join(DBG, "push_b1_3x.png"), scale(cvp, 3))

# B3: 寒色の岩とスイッチ・飛び石の変種・大小の石碑
cvq = compose(B3, b3_map, [("boss_door", 6, 1), ("crystal_l", 2, 4), ("crystal_pillar", 1, 9),
                           ("tablet_l", 11, 4), ("tablet", 4, 11), ("rubble_deep", 13, 11)], 0, None)
for i, y in enumerate(range(5, 11)):
    nm = ["stepping_stone", "stepping_stone_b", "stepping_stone_c"][(i * 2) % 3]
    blit(cvq, SPR[nm]["frames"]["base"], 7 * 16, y * 16)
blit(cvq, SPR["plate_deep"]["frames"]["up"], 9 * 16, 11 * 16)
blit(cvq, SPR["plate_deep"]["frames"]["down"], 11 * 16, 11 * 16)
blit(cvq, SPR["boulder_deep"]["frames"]["base"], 11 * 16, 11 * 16)
blit(cvq, SPR["boulder_deep"]["frames"]["base"], 8 * 16, 12 * 16)
write_png(os.path.join(DBG, "push_b3_1x.png"), cvq)
write_png(os.path.join(DBG, "push_b3_3x.png"), scale(cvq, 3))
zoom_sheet(os.path.join(DBG, "zoom_push.png"), ["boulder", "boulder_deep", "plate", "plate_deep", "rail_corner_ne", "rail_corner_nw",
           "rail_corner_se", "rail_corner_sw", "minecart_v", "stepping_stone", "stepping_stone_b", "stepping_stone_c", "tablet", "tablet_l"], k=6, cols=8)

# 宝箱の見分け（B1 と B3 の床の上）
cvc = canvas(16 * 6, 16 * 2)
for row, fl in enumerate(["floor", "floor_deep"]):
    for col in range(6):
        blit(cvc, fr(fl), col * 16, row * 16)
    blit(cvc, fr("chest"), 1 * 16, row * 16)
    blit(cvc, fr("chest_open"), 2 * 16, row * 16)
    blit(cvc, fr("chest"), 4 * 16, row * 16)
    blit(cvc, fr("chest_open"), 5 * 16, row * 16)
write_png(os.path.join(DBG, "chest_check_1x.png"), cvc)
write_png(os.path.join(DBG, "chest_check_6x.png"), scale(cvc, 6))

# 色数の検査（1 タイル = 墨 + 3 色まで / 大物は 16x16 の升目ごと）
for nm, sp in SPR.items():
    for fn, frm in sp["frames"].items():
        h = len(frm); w = len(frm[0])
        for by in range(0, h, 16):
            for bx in range(0, w, 16):
                cs = set()
                for y in range(by, min(h, by + 16)):
                    for x in range(bx, min(w, bx + 16)):
                        p = frm[y][x]
                        if p is not None and p != "ink":
                            cs.add(p)
                if len(cs) > 3:
                    print("色が多い: %s/%s (%d,%d) %s" % (nm, fn, bx, by, sorted(cs)))
print("sprites:", len(SPR))
