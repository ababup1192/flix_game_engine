import json, os

# 部品ごとに 1 字 = 1 画素で打った格子を (x, y) に置く。'.' は下を残す。
W, H = 64, 48
here = os.path.dirname(os.path.abspath(__file__))

WALL_ROW = "VVVVVvVVVVVVvVVVVVVvVVVVVVvVVVVVVVvVVVVVvVVVVVVVVvVVVVVVvVVVVVVV"

def base():
    rows = []
    for y in range(H):
        if y < 10:
            rows.append("N" * W)
        elif y == 10:
            rows.append("i" * W)
        elif y == 11:
            rows.append("J" * W)
        elif y < 34:
            rows.append(WALL_ROW)
        elif y == 34:
            rows.append("v" * W)
        elif y == 35:
            rows.append("J" * W)
        else:
            rows.append("n" * W)
    return [list(r) for r in rows]

def put(img, x, y, block):
    for dy, line in enumerate(block):
        for dx, ch in enumerate(line):
            if ch != ".":
                img[y + dy][x + dx] = ch

GROUND_SPECKS = [
    (3, 38, ["vv"]), (14, 37, ["vvv"]), (33, 39, ["vv", ".v"]), (52, 37, ["vvv"]),
    (6, 43, ["vv"]), (28, 45, ["vvv"]), (47, 44, ["vv"]), (58, 42, ["v", "vv"]),
    (39, 47, ["vvv"]), (1, 47, ["vv"]), (60, 46, ["vv"]),
]

# 提灯に照らされる塀の範囲。x の所の板を 1 段明るい暖色に、板の継ぎ目を暖色の暗い段に替える。
# 光の色で上塗りしないのは、塗ると板の継ぎ目が消えて光の形だけが板のように浮くから。
LIT_WALL = [
    ".....xxxxx.....",
    "...xxxxxxxxx...",
    "..xxxxxxxxxxx..",
    ".xxxxxxxxxxxxx.",
    ".xxxxxxxxxxxxx.",
    "xxxxxxxxxxxxxxx",
    "xxxxxxxxxxxxxxx",
    "xxxxxxxxxxxxxxx",
    "xxxxxxxxxxxxxxx",
    "xxxxxxxxxxxxxxx",
    ".xxxxxxxxxxxxx.",
    ".xxxxxxxxxxxxx.",
    "..xxxxxxxxxxx..",
    "...xxxxxxxxx...",
    ".....xxxxx.....",
]
LIT_SWAP = {"V": "w", "v": "b"}

def put_lit(img, x, y, mask):
    for dy, line in enumerate(mask):
        for dx, ch in enumerate(line):
            if ch == "x":
                img[y + dy][x + dx] = LIT_SWAP.get(img[y + dy][x + dx], img[y + dy][x + dx])

# 提灯の真下の天板
LIT_TOP = [
    ".PPPPPPPPP.",
    "AAAAAAAAAAA",
]

CHIMNEY = ["IIIIi", "iiiiJ"] + [".IiJ."] * 11

STOVE = [
    "IIIIIIIIIIIIIIIIIi",
    "IiiiiiiiiiiiiiiiiJ",
    "IiJJJJJJiiiiiiiiiJ",
    "IiJqQQqJiiiiiiiiiJ",
    "IiJQPPQJiiiiiiiiiJ",
    "IiJqQQqJiiiiiiiiiJ",
    "IiJJJJJJiiiiiiiiiJ",
    "IiiiiiiiiiiiiiiiiJ",
    "iJJJJJJJJJJJJJJJJJ",
    "JJJJJJJJJJJJJJJJJJ",
]

POLE = ["BBBBBZ"] + ["....BZ"] * 15

LANTERN = [
    "..JJJ..",
    ".XqqqX.",
    "XqQQQqX",
    "qQPPPQq",
    "XqQPQqX",
    "qQPPPQq",
    "XqQQQqX",
    ".XqqqX.",
    "..JJJ..",
    "...q...",
]

IMO = [
    "..UUu.UUu...",
    ".UUuuUUuuUu.",
    "AAAAAAAAAAAA",
    "bbbbbbbbbbbb",
]

BED = [
    "A" * 42,
    "B" * 42,
    "BbBBBBBBBBBBBBbBBBBBBBBBBBBBbBBBBBBBBBBBbB",
    "b" * 42,
    "B" * 42,
    "Z" * 42,
]

HANDLE = [
    "...........BZ",
    "...........BZ",
    "AAAAAAAAAAABZ",
    "ZZZZZZZZZZZBZ",
    "...........BZ",
    "...........BZ",
]

LEG = ["bZ"] * 8 + ["ZZ"]

SHADOW = ["N" * 40, "N" * 40]

SPILL = [
    "..w.wwwwwwwwwwwwwww.w...",
    "...w.w.wwwwwwwwwww.w.w..",
    ".....w.w.w.w.w.w.w.w....",
    "........w...w...w.......",
]

WHEEL = [
    "....BBBBB....",
    "..BB..b..ZZ..",
    ".B.b..b..b.Z.",
    ".B..b.b.b..Z.",
    "B....bbb....Z",
    "B....bAb....Z",
    "BbbbbbAbbbbbZ",
    "Z....bAb....Z",
    "Z....bbb....Z",
    ".Z..b.b.b..Z.",
    ".Z.b..b..b.Z.",
    "..ZZ..b..ZZ..",
    "....ZZZZZ....",
]

STEAM = [
    [".............." , ".............." , "....122......." , "...21122......" , ".............." , ".............." , "....121......."],
    [".............." , ".....232......" , "....22322....." , ".............." , ".............." , "....1121......" , ".............."],
    ["......3.3....." , ".....3.3......" , ".............." , "......11......" , ".....2112....." , ".............." , ".............."],
    [".............." , ".............." , "......212....." , ".....22112...." , ".............." , ".............." , "....212......."],
    [".............." , "........223..." , ".......2322..." , ".............." , ".............." , "...1211......." , ".............."],
    ["..........3.33" , ".........3..3." , ".............." , "....11........" , "...2112......." , ".............." , ".............."],
]

def scene_base():
    img = base()
    for x, y, b in GROUND_SPECKS:
        put(img, x, y, b)
    put_lit(img, 33, 12, LIT_WALL)
    put(img, 23, 7, CHIMNEY)
    put(img, 15, 20, STOVE)
    put(img, 40, 14, POLE)
    put(img, 37, 15, LANTERN)
    put(img, 34, 26, IMO)
    put(img, 8, 45, SHADOW)
    put(img, 40, 36, SPILL)
    put(img, 6, 30, BED)
    put(img, 35, 30, LIT_TOP)
    put(img, 48, 29, HANDLE)
    put(img, 42, 36, LEG)
    put(img, 14, 34, WHEEL)
    return img

frames = {}
for k, st in enumerate(STEAM):
    img = scene_base()
    put(img, 20, 0, st)
    rows = ["".join(r) for r in img]
    assert len(rows) == H and all(len(r) == W for r in rows)
    frames[f"f{k}"] = rows

legend = {
    "N": "night1", "n": "night0",
    "W": "wall0", "V": "wall1", "v": "wall2",
    "A": "wood0", "B": "wood1", "b": "wood2", "Z": "wood3",
    "P": "lamp0", "Q": "lamp1", "q": "lamp2", "X": "lamp3",
    "I": "iron0", "i": "iron1", "J": "iron2",
    "1": "steam0", "2": "steam1", "3": "steam2",
    "U": "imo0", "u": "imo1", "w": "litwall0",
}
doc = {
    "version": 1,
    "title": "夜の路地の焼き芋の屋台",
    "note": "64×48・正面から少し見下ろし。灯りは提灯 1 つ。動くのは煙突の湯気だけ（0〜6 行・20〜33 列）。",
    "paletteFile": "assets/palette.json",
    "legend": legend,
    "sprites": {"scene": {"kind": "background", "delayMs": 180, "frames": frames}},
}
json.dump(doc, open(os.path.join(here, "..", "assets", "c_scene.sprite.json"), "w"), indent=2, ensure_ascii=False)
print("ok")
