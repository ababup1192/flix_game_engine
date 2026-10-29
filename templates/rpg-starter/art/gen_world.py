import json, math, sys

OUT = sys.argv[1]
N = 16

LEGEND = {
    "k": "ink",
    "g": "fc1A", "G": "fc2A", "d": "fc0A",
    "w": "fc12", "W": "fc21",
    "r": "fc00", "R": "fc10", "S": "fc20",
    "e": "fc18", "E": "fc38", "b": "fc08",
    "o": "fc17", "O": "fc27",
    "h": "fc16", "c": "fc37",
    "y": "fc28",
}


def grid(fill):
    return [[fill] * N for _ in range(N)]


def rows(g):
    return ["".join(r) for r in g]


def bayer4(x, y):
    m = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
    return (m[y % 4][x % 4] + 0.5) / 16.0


# ---------------------------------------------------------------- sea
# 波の印。f0 と f1 で 1px 横へずれ、形も少し変わる（上下に揺れて見える）。
WAVE_F0 = [
    (2, 3, [".WW..", "W..WW"]),
    (9, 10, [".WWW.", "W...W"]),
    (11, 1, ["WW"]),
    (3, 12, ["WW"]),
]
WAVE_F1 = [
    (3, 3, ["WWW..", "...WW"]),
    (8, 10, ["WW.WW", "..W.."]),
    (12, 1, ["WW"]),
    (4, 12, ["W"]),
]


def land_mask(kind):
    """True = 陸。辺の深さは端で 4（隣の岸と継ぎ目がそろう）。"""
    wob = [0, 0, 0, 0, 1, 1, 1, 0, 0, 0, -1, -1, 0, 0, 0, 0]
    D = 4
    m = [[False] * N for _ in range(N)]
    for y in range(N):
        for x in range(N):
            v = False
            if kind == "n":
                v = y < D + wob[x]
            elif kind == "s":
                v = y > N - 1 - (D + wob[N - 1 - x])
            elif kind == "w":
                v = x < D + wob[(y + 5) % N] if 2 < y < 13 else x < D
            elif kind == "e":
                v = x > N - 1 - (D + (wob[(y + 9) % N] if 2 < y < 13 else 0))
            elif kind in ("ne", "nw", "se", "sw"):
                # 2 辺が陸。水の側の角を丸める
                ny = kind[0] == "n"
                ex = kind[1] == "e"
                xx = (N - 1 - x) if ex else x  # 陸の辺からの距離（横）
                yy = y if ny else (N - 1 - y)
                r = 3.5
                cx, cy = D + r - 0.5, D + r - 0.5
                if yy < D or xx < D:
                    v = True
                elif xx < cx and yy < cy:
                    v = (xx - cx) ** 2 + (yy - cy) ** 2 > r * r
            elif kind.startswith("in_"):
                c = kind[3:]
                ex = c[1] == "e"
                ny = c[0] == "n"
                xx = (N - 1 - x) if ex else x
                yy = y if ny else (N - 1 - y)
                v = (xx + 0.5) ** 2 + (yy + 0.5) ** 2 < 4.6 ** 2
            m[y][x] = v
    return m


def sea_tile(kind, frame):
    g = grid("w")
    land = land_mask(kind) if kind else [[False] * N for _ in range(N)]
    # 陸と輪郭
    for y in range(N):
        for x in range(N):
            if land[y][x]:
                g[y][x] = "g"

    def is_land(x, y):
        if 0 <= x < N and 0 <= y < N:
            return land[y][x]
        return None  # タイルの外は分からない

    for y in range(N):
        for x in range(N):
            if not land[y][x]:
                continue
            nb = [is_land(x + dx, y + dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))]
            if False in nb:
                g[y][x] = "k"
            # 南が水なら崖の影で 2px（光は左上から）
            if is_land(x, y + 2) is False and is_land(x, y + 1) is True:
                g[y][x] = "k"
    # 波打ち際の泡（間欠）
    for y in range(N):
        for x in range(N):
            if land[y][x]:
                continue
            nb = [is_land(x + dx, y + dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))]
            if True in nb:
                if (x + y + 2 * frame) % 4 != 3:
                    g[y][x] = "W"
    # 波の印（陸と泡から 1px 離れて全部入る所だけ）
    for (wx, wy, shape) in (WAVE_F0 if frame == 0 else WAVE_F1):
        cells = []
        ok = True
        for dy, line in enumerate(shape):
            for dx, ch in enumerate(line):
                x, y = wx + dx, wy + dy
                for ax in (-1, 0, 1):
                    for ay in (-1, 0, 1):
                        xx, yy = x + ax, y + ay
                        if 0 <= xx < N and 0 <= yy < N and (land[yy][xx] or g[yy][xx] == "W" and (xx, yy) not in cells):
                            if land[yy][xx]:
                                ok = False
                if ch == "W":
                    cells.append((x, y))
        if ok:
            for (x, y) in cells:
                g[y][x] = "W"
    return rows(g)


# ---------------------------------------------------------------- plains
def plains(variant):
    g = grid("g")
    # 明るさの場: タイルに 1 つだけ濃い所を作る（壁紙にしない）
    cx, cy = (5, 4) if variant == 0 else (11, 10)
    for y in range(N):
        for x in range(N):
            dx = min(abs(x - cx), N - abs(x - cx))
            dy = min(abs(y - cy), N - abs(y - cy))
            v = max(0.0, 1.0 - math.hypot(dx * 0.8, dy * 1.6) / 6.5) * 0.24
            if v > bayer4(x, y):
                g[y][x] = "G"
    tufts = [(10, 3), (2, 11), (13, 13)] if variant == 0 else [(3, 2), (6, 7), (13, 4), (1, 13)]
    for (tx, ty) in tufts:
        # 草の房: 明るい葉先 2 本と根元の影
        for (x, y, c) in ((tx, ty, "G"), (tx + 2, ty, "G"), (tx + 1, ty + 1, "G"), (tx, ty + 1, "d"), (tx + 1, ty + 2, "d"), (tx + 2, ty + 1, "d")):
            g[y % N][x % N] = c
    if variant == 1:
        # 小石（墨の点 + 影）
        for (x, y, c) in ((9, 12, "d"), (10, 12, "d"), (9, 13, "k"), (10, 13, "k"), (8, 13, "d")):
            g[y][x] = c
    return rows(g)


# ---------------------------------------------------------------- hills
def hills():
    g = [list(r) for r in plains(0)]
    for y in range(N):
        for x in range(N):
            g[y][x] = "g" if g[y][x] != "d" else "g"
    mounds = [(6.0, 9.5, 5.6, 4.6), (12.0, 12.5, 3.6, 3.0)]
    for (cx, cy, rx, ry) in mounds:
        for y in range(N):
            for x in range(N):
                if y > cy + 1.5:
                    continue
                nx, ny = (x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry
                d = nx * nx + ny * ny
                if d < 1.0:
                    lit = -nx * 0.7 - ny * 0.6
                    if d > 0.72 and (nx > -0.2 or ny > 0.3):
                        c = "k"
                    elif lit > 0.35:
                        c = "G"
                    elif lit > 0.05:
                        c = "G" if bayer4(x, y) < (lit - 0.05) / 0.3 else "g"
                    elif lit < -0.35:
                        c = "d"
                    elif lit < -0.1:
                        c = "d" if bayer4(x, y) < (-0.1 - lit) / 0.25 else "g"
                    else:
                        c = "g"
                    g[y][x] = c
        # 裾の影
        by = int(cy + 2)
        for x in range(int(cx - rx + 1), int(cx + rx)):
            if 0 <= x < N and 0 <= by < N and g[by][x] in "gG":
                g[by][x] = "d"
    # 裾は平らに切る: 下端の輪郭
    for (cx, cy, rx, ry) in mounds:
        y = int(cy + 1.5)
        for x in range(int(cx - rx + 0.5), int(cx + rx + 0.5)):
            if 0 <= x < N and 0 <= y < N:
                g[y][x] = "k"
    return rows(g)


# ---------------------------------------------------------------- forest
def crowns(edge):
    cs = []
    rowsy = [-8, 0, 8, 16] if not edge else [-8, 0, 7]
    for ry in rowsy:
        if edge and ry == 7:
            xs = [4, 12]
        else:
            xs = [-8, 0, 8, 16, 24] if ry % 16 == 0 else [-4, 4, 12, 20]
        for cx in xs:
            # 位置で決まる揺らぎ（乱数にしない）
            k = (cx * 7 + ry * 3) % 5
            r = 4.9 + (k - 2) * 0.25
            if edge and ry == 7:
                r = 4.6
            cs.append((cx + (k % 2), ry, r))
    return cs


def forest(edge):
    g = grid("k")
    cs = sorted(crowns(edge), key=lambda c: c[1])
    owner = [[None] * N for _ in range(N)]
    for i, (cx, cy, r) in enumerate(cs):
        for y in range(N):
            for x in range(N):
                dx, dy = x + 0.5 - cx, y + 0.5 - cy
                d = math.hypot(dx, dy * 1.1)
                if d < r:
                    owner[y][x] = i
    for y in range(N):
        for x in range(N):
            i = owner[y][x]
            if i is None:
                g[y][x] = "d" if (x + y) % 2 == 0 else "k"
                continue
            cx, cy, r = cs[i]
            dx, dy = (x + 0.5 - cx) / r, (y + 0.5 - cy) / r
            d = math.hypot(dx, dy * 1.1)
            lit = -dx * 0.75 - dy * 0.65
            # 輪郭: 下と右の縁だけ墨
            if d > 0.8 and (dx + dy) > 0.1:
                c = "k"
            elif d > 0.8:
                c = "d"
            elif lit > 0.45:
                c = "G"
            elif lit > 0.15:
                c = "G" if bayer4(x, y) < (lit - 0.15) / 0.3 else "g"
            elif lit < -0.35:
                c = "d"
            elif lit < -0.1:
                c = "d" if bayer4(x, y) < (-0.1 - lit) / 0.25 else "g"
            else:
                c = "g"
            g[y][x] = c
    if edge:
        # 南の縁: 幹と草地。冠の下（y>=12）は地面
        for y in range(N):
            for x in range(N):
                if owner[y][x] is None and y >= 9:
                    g[y][x] = "g"
        for (tx) in (3, 4, 11, 12):
            for y in range(11, 14):
                if owner[y][tx] is None or y >= 11:
                    if owner[y][tx] is None:
                        g[y][tx] = "k" if tx in (4, 12) else "d"
        # 足元の影（左上からの光で右下へ）
        for (sx, sy, ln) in ((2, 14, 5), (10, 14, 5)):
            for x in range(sx, sx + ln):
                if g[sy][x] == "g":
                    g[sy][x] = "d"
        for (sx, sy) in ((7, 12), (15, 12), (0, 13), (8, 13)):
            if g[sy][sx] == "g":
                g[sy][sx] = "d"
        # 草の房 1 つ
        for (x, y, c) in ((7, 14, "G"), (8, 15, "d")):
            g[y][x] = c
    return rows(g)


# ---------------------------------------------------------------- mountains
def mountain_shape(apexes):
    """apex: (ax, ay, halfwidth_at_bottom)。左の面が受光。"""
    g = grid("g")
    own = [[None] * N for _ in range(N)]
    for i, (ax, ay, hw, by) in enumerate(apexes):
        for y in range(N):
            if y < ay or y > by:
                continue
            t = (y - ay + 0.5) / (by - ay + 1)
            half = 0.5 + t * hw
            for x in range(N):
                if abs(x + 0.5 - ax) <= half:
                    own[y][x] = (i, x + 0.5 - ax, half, t)
    return g, own


def mountain(variant):
    if variant == "a":
        peaks = [(7.5, 0, 9.0, 15)]
        pal = ("R", "r", "k")
    elif variant == "b":
        peaks = [(12.5, 4, 5.5, 15), (5.0, 1, 7.0, 15)]
        pal = ("R", "r", "k")
    g, own = mountain_shape(peaks)
    # 稜線の揺らぎ: 受光と陰の境（頂から少し右へ寄って下る）
    for y in range(N):
        for x in range(N):
            o = own[y][x]
            if o is None:
                continue
            i, dx, half, t = o
            ridge = 0.6 * t * (1 if (y // 3) % 2 == 0 else 0) + 0.5
            edge = abs(dx) > half - 1.0
            if edge:
                c = "k"
            elif dx < ridge - 0.5:
                c = "R"
            else:
                c = "r"
            g[y][x] = c
    # 岩の筋（受光面に中間色・陰の面に墨の短い斜線）
    for (i, (ax, ay, hw, by)) in enumerate(peaks):
        for (fx, fy, ln, c, side) in (
            (-0.35, 0.40, 2, "r", -1), (-0.55, 0.62, 3, "r", -1), (-0.2, 0.75, 2, "r", -1),
            (0.45, 0.35, 2, "k", 1), (0.35, 0.60, 3, "k", 1), (0.6, 0.80, 2, "k", 1),
        ):
            y0 = int(ay + fy * (by - ay))
            half = 0.5 + ((y0 - ay + 0.5) / (by - ay + 1)) * hw
            x0 = int(ax + fx * half)
            for j in range(ln):
                x, y = x0 + (j if side < 0 else -j) * 0 + j * side * -1 * -1, y0 + j
                x = x0 - j if side < 0 else x0 + j
                if 0 <= x < N and 0 <= y < N and own[y][x] is not None and own[y][x][0] == i and g[y][x] not in "k":
                    if c == "k" and g[y][x] == "R":
                        continue
                    g[y][x] = c
    # 前の山が後ろの山に重なる所の輪郭: own は後勝ちなので境目に墨
    for y in range(N):
        for x in range(1, N):
            a, b = own[y][x - 1], own[y][x]
            if a and b and a[0] != b[0]:
                g[y][x if b[0] > a[0] else x - 1] = "k"
    # 雪の名残と草
    # 受光面の頂近くに明るい点を残す
    return rows(g)


def mountain_snow():
    peaks = [(7.5, 0, 9.0, 15)]
    g, own = mountain_shape(peaks)
    for y in range(N):
        for x in range(N):
            o = own[y][x]
            if o is None:
                continue
            i, dx, half, t = o
            ridge = 0.5 + (0.6 * t if (y // 3) % 2 == 0 else 0)
            edge = abs(dx) > half - 1.0
            snowline = 6 + (1 if x in (2, 3, 9, 10) else 0) - (1 if x in (5, 6, 12) else 0)
            lit = dx < ridge - 0.5
            if edge:
                c = "k"
            elif y <= snowline:
                c = "S" if lit else "R"
            else:
                # 雪の下の岩: 受光は R、陰は墨の上に R の間引き
                if lit:
                    c = "R"
                else:
                    c = "R" if bayer4(x, y) < 0.25 else "k"
            g[y][x] = c
    # 雪の縁の垂れ（受光面に墨の小さな影で段差）
    for x in range(N):
        sl = 6 + (1 if x in (2, 3, 9, 10) else 0) - (1 if x in (5, 6, 12) else 0)
        y = sl + 1
        if 0 <= y < N and own[y][x] is not None and g[y][x] == "R" and own[y][x][1] < 0:
            if x % 3 != 0:
                g[y][x] = "k"
    # 岩の筋（受光面）
    for (x, y) in ((4, 10), (3, 11), (5, 13), (4, 14), (2, 14)):
        if own[y][x] is not None and g[y][x] == "R":
            g[y][x] = "k"
    return rows(g)


# ---------------------------------------------------------------- road
def road():
    g = grid("e")
    for y in range(N):
        for x in range(N):
            dx = min(abs(x - 4), N - abs(x - 4))
            dy = min(abs(y - 11), N - abs(y - 11))
            v = max(0.0, 1.0 - math.hypot(dx * 0.7, dy * 1.5) / 7.0) * 0.3
            if v > bayer4(x, y):
                g[y][x] = "E"
    # 小石（明るい頭 + 暗い影）と轍の暗い点
    for (px, py) in ((11, 3), (2, 7), (13, 12)):
        g[py][px] = "E"
        g[py][(px + 1) % N] = "E"
        g[(py + 1) % N][(px + 1) % N] = "b"
        g[(py + 1) % N][(px + 2) % N] = "b"
    for (px, py) in ((6, 2), (9, 8), (0, 14), (7, 13)):
        g[py][px] = "b"
    return rows(g)


# ---------------------------------------------------------------- bridges
def bridge(horizontal):
    g = grid("w")
    for y in range(N):
        for x in range(N):
            a, b = (x, y) if horizontal else (y, x)  # a = 渡る向き, b = 横切る向き
            if 3 <= b <= 12:
                if b in (3, 12):
                    c = "k"
                elif b == 4:
                    c = "O"
                elif b == 11:
                    c = "o"
                else:
                    # 板: 3px ごとに墨の目地、板の受光側の端は明るく
                    m = a % 4
                    if m == 3:
                        c = "k"
                    elif m == 0:
                        c = "O"
                    else:
                        c = "o"
                    if b == 10 and m != 3:
                        c = "o" if m == 0 else "o"
                g[y][x] = c
            elif b == 13:
                g[y][x] = "k" if a % 4 != 1 else "w"  # 橋の落とす影
            elif b == 2 and a % 8 in (2, 3, 4):
                g[y][x] = "w"
    # 欄干の柱
    for a in (1, 9):
        for b in (3, 12):
            x, y = (a, b) if horizontal else (b, a)
            g[y][x] = "O"
    return rows(g)


# ---------------------------------------------------------------- town
def house(g, x0, y0, w, roof_h, wall_h, door_x):
    # 屋根: 台形。横の段は墨の目地、右の端は陰
    for j in range(roof_h):
        inset = max(0, roof_h - 1 - j) // 2
        for i in range(-1, w + 1):
            x, y = x0 + i, y0 + j
            if not (0 <= x < N and 0 <= y < N):
                continue
            if i < inset - 1 or i > w - inset:
                continue
            if i == inset - 1 or i == w - inset or j == 0:
                c = "k"
            elif j == roof_h - 1:
                c = "k"
            elif j % 2 == 0:
                c = "h" if (i + j) % 3 else "k"
            else:
                c = "h"
            if i >= w - inset - 1 and c == "h" and j > 0:
                c = "k" if (x + y) % 2 == 0 else "h"
            g[y][x] = c
    # 屋根の受光（左上の段に漆喰色の光）
    for i in range(1, 3):
        x, y = x0 + (roof_h - 2) // 2 + i, y0 + 1
        if 0 <= x < N and 0 <= y < N and g[y][x] == "h":
            g[y][x] = "c"
    for j in range(wall_h):
        for i in range(w):
            x, y = x0 + i, y0 + roof_h + j
            if not (0 <= x < N and 0 <= y < N):
                continue
            if i == 0 or i == w - 1 or j == wall_h - 1:
                c = "k"
            elif i == w - 2:
                c = "k" if (x + y) % 2 == 0 else "c"
            else:
                c = "c"
            if i in (door_x,) and j >= 1:
                c = "k"
            g[y][x] = c
    # 接地の影（右下へ）
    y = y0 + roof_h + wall_h
    for i in range(1, w + 1):
        x = x0 + i
        if 0 <= x < N and 0 <= y < N and g[y][x] == "g":
            g[y][x] = "k" if i == w else ("k" if (x + y) % 2 == 0 else "g")


def town():
    g = grid("g")
    # 道（家の間を抜ける土の道は使わず、草地に小さな路地の影）
    house(g, 0, 1, 7, 4, 3, 2)
    house(g, 9, 0, 6, 4, 3, 3)
    house(g, 4, 7, 8, 4, 3, 5)
    # 井戸の代わりに小さな木（村の目印）
    return rows(g)


# ---------------------------------------------------------------- mine
def mine():
    g = grid("r")
    # 岩肌: 左上の受光、段々の筋
    for y in range(N):
        for x in range(N):
            v = 1.0 - (x * 0.6 + y * 0.8) / 14.0
            c = "R" if v > 0.45 else ("R" if v > 0.15 and bayer4(x, y) < (v - 0.15) / 0.3 else "r")
            g[y][x] = c
    # 岩の割れ目
    for (x, y) in ((2, 2), (3, 3), (12, 1), (13, 2), (14, 2), (1, 9), (2, 10), (14, 8), (15, 9), (13, 12)):
        g[y][x] = "k"
    # 坑道の口と板の枠
    for y in range(4, 16):
        for x in range(3, 13):
            in_frame = 3 <= x <= 12 and y >= 4
            if not in_frame:
                continue
            if y == 4 or y == 5:
                c = "o" if y == 5 else "k"
                if x in (3, 12):
                    c = "k"
            elif x in (4, 11):
                c = "o"
            elif x in (3, 12):
                c = "k"
            elif x in (5, 10) and y >= 6:
                c = "k"
            else:
                c = "k"
            g[y][x] = c
    # 梁の木目・受光
    for x in range(4, 12):
        g[5][x] = "o" if x % 3 else "k"
    for x in (5, 6, 8, 9):
        g[4][x] = "o"
    g[4][4] = "k"
    g[4][11] = "k"
    for y in range(6, 15):
        g[y][4] = "o"
        g[y][11] = "o" if y % 3 else "k"
    # 口の奥の暗がりにレールの気配
    for y in range(11, 15):
        g[y][6] = "r" if y % 2 else "k"
        g[y][9] = "r" if y % 2 else "k"
    g[14][7] = "r"
    g[14][8] = "r"
    # 足元の土台（ズリ）
    for x in range(N):
        if g[15][x] not in ("o",):
            g[15][x] = "k" if x in (0, 1, 3, 12, 14, 15) or x < 3 or x > 12 else "k"
    for (x, y) in ((0, 14), (1, 14), (14, 14), (15, 14), (13, 14), (2, 13)):
        g[y][x] = "r"
    for (x, y) in ((1, 13), (14, 13), (0, 12)):
        g[y][x] = "R"
    return rows(g)


# ---------------------------------------------------------------- shrine
def shrine():
    g = grid("g")
    # 石の台（2 段）
    for (y, x0, x1) in ((13, 2, 13), (12, 3, 12)):
        for x in range(x0, x1 + 1):
            g[y][x] = "R"
        g[y][x0] = "k"
        g[y][x1] = "k"
    for x in range(2, 14):
        g[14][x] = "k"
    for x in range(3, 13):
        g[12][x] = "R" if x < 10 else ("k" if x % 2 == 0 else "R")
    # 柱と屋根
    for y in range(6, 12):
        g[y][4] = "R"
        g[y][5] = "k"
        g[y][10] = "R"
        g[y][11] = "k"
    for y in range(6, 12):
        for x in range(6, 10):
            g[y][x] = "k"
    for (y, x0, x1) in ((2, 7, 8), (3, 5, 10), (4, 3, 12), (5, 2, 13)):
        for x in range(x0, x1 + 1):
            g[y][x] = "R"
    for x in range(2, 14):
        g[5][x] = "k" if x in (2, 13) or x % 2 == 0 else "R"
    g[2][6] = "k"; g[2][9] = "k"
    g[3][4] = "k"; g[3][11] = "k"
    g[4][2] = "k"; g[4][13] = "k"
    for (x, y) in ((10, 3), (11, 4), (12, 4), (9, 2)):
        g[y][x] = "k" if (x + y) % 2 else "R"
    # 屋根の頂の飾り（金）
    g[1][7] = "y"; g[1][8] = "y"; g[0][7] = "k"; g[0][8] = "k"
    # 奥に灯る玉（金）
    g[8][7] = "y"; g[8][8] = "y"; g[9][7] = "y"; g[9][8] = "k"
    g[7][7] = "k"
    # 接地の影
    for x in range(4, 15):
        if g[15][x] == "g":
            g[15][x] = "k" if (x % 2 == 0) else "g"
    g[14][14] = "k"
    return rows(g)




# ---------------------------------------------------------------- forest v2（縁と角）
def crowns2(open_sides, corner):
    cs = []
    s_open = "s" in open_sides
    for ry in ([-8, 0, 7] if s_open else [-8, 0, 8, 16]):
        if ry == 7:
            xs = [4, 12]
        else:
            xs = [-8, 0, 8, 16, 24] if ry % 16 == 0 else [-4, 4, 12, 20]
        for cx in xs:
            k = (cx * 7 + ry * 3) % 5
            r = 4.9 + (k - 2) * 0.25
            if ry == 7:
                r = 4.6
            if "n" in open_sides and ry <= 0:
                continue
            if "e" in open_sides and cx >= 16:
                continue
            if "w" in open_sides and cx <= 0:
                continue
            if corner == "ne" and cx >= 16 and ry <= 0:
                continue
            if corner == "nw" and cx <= 0 and ry <= 0:
                continue
            if corner == "se" and cx >= 16 and ry >= 16:
                continue
            if corner == "sw" and cx <= 0 and ry >= 16:
                continue
            x = cx + (k % 2)
            # 開いた辺へははみ出さない（冠の丸みを辺の手前で閉じる）
            if "e" in open_sides and x + r > 14.6:
                x = 14.6 - r
            if "w" in open_sides and x - r < 1.4:
                x = 1.4 + r
            cs.append((x, ry, r))
    return sorted(cs, key=lambda c: c[1])


def forest_tile(open_sides=(), corner=None):
    open_sides = set(open_sides)
    cs = crowns2(open_sides, corner)
    owner = [[None] * N for _ in range(N)]
    for i, (cx, cy, r) in enumerate(cs):
        for y in range(N):
            for x in range(N):
                if math.hypot(x + 0.5 - cx, (y + 0.5 - cy) * 1.1) < r:
                    owner[y][x] = i
    # 草になる隙間: 開いた辺（か角）から、冠に当たらずにたどれる所
    def near_open(x, y):
        if "n" in open_sides and y <= 6:
            return True
        if "s" in open_sides and y >= 9:
            return True
        if "e" in open_sides and x >= 9:
            return True
        if "w" in open_sides and x <= 6:
            return True
        if corner:
            ccx = 15 if corner[1] == "e" else 0
            ccy = 0 if corner[0] == "n" else 15
            if max(abs(x - ccx), abs(y - ccy)) <= 6:
                return True
        return False

    seeds = []
    for x in range(N):
        for y in range(N):
            on_side = ("n" in open_sides and y == 0) or ("s" in open_sides and y == N - 1) or \
                      ("e" in open_sides and x == N - 1) or ("w" in open_sides and x == 0)
            if corner:
                ccx = 15 if corner[1] == "e" else 0
                ccy = 0 if corner[0] == "n" else 15
                on_side = on_side or (x == ccx and abs(y - ccy) <= 4) or (y == ccy and abs(x - ccx) <= 4)
            if on_side and owner[y][x] is None:
                seeds.append((x, y))
    grass = [[False] * N for _ in range(N)]
    while seeds:
        x, y = seeds.pop()
        if grass[y][x]:
            continue
        grass[y][x] = True
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            xx, yy = x + dx, y + dy
            if 0 <= xx < N and 0 <= yy < N and owner[yy][xx] is None and not grass[yy][xx] and near_open(xx, yy):
                seeds.append((xx, yy))

    g = grid("k")
    for y in range(N):
        for x in range(N):
            i = owner[y][x]
            if i is None:
                g[y][x] = "g" if grass[y][x] else ("d" if (x + y) % 2 == 0 else "k")
                continue
            cx, cy, r = cs[i]
            dx, dy = (x + 0.5 - cx) / r, (y + 0.5 - cy) / r
            d = math.hypot(dx, dy * 1.1)
            lit = -dx * 0.75 - dy * 0.65
            if d > 0.8 and (dx + dy) > 0.1:
                c = "k"
            elif d > 0.8:
                c = "d"
            elif lit > 0.45:
                c = "G"
            elif lit > 0.15:
                c = "G" if bayer4(x, y) < (lit - 0.15) / 0.3 else "g"
            elif lit < -0.35:
                c = "d"
            elif lit < -0.1:
                c = "d" if bayer4(x, y) < (-0.1 - lit) / 0.25 else "g"
            else:
                c = "g"
            g[y][x] = c
    # 草に面した冠の縁は墨で締める
    for y in range(N):
        for x in range(N):
            if owner[y][x] is None:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                xx, yy = x + dx, y + dy
                if 0 <= xx < N and 0 <= yy < N and grass[yy][xx]:
                    g[y][x] = "k"
    if "s" in open_sides:
        for (cx, cy, r) in cs:
            if cy != 7:
                continue
            x0 = int(round(cx))
            for y in range(11, 14):
                for (tx, c) in ((x0 - 1, "d"), (x0, "k")):
                    if 0 <= tx < N and owner[y][tx] is None:
                        g[y][tx] = c
                        grass[y][tx] = False
            for x in range(x0 - 2, x0 + 3):
                if 0 <= x < N and grass[14][x]:
                    g[14][x] = "d"
    # 落ち影: 冠の右と下の草へ 1px（光は左上から）
    for y in range(N):
        for x in range(N):
            if not grass[y][x] or g[y][x] != "g":
                continue
            up = y > 0 and owner[y - 1][x] is not None
            lf = x > 0 and owner[y][x - 1] is not None
            if up or lf:
                g[y][x] = "d"
    # 草の房（縁の草地が寂しくならないよう 1 つ）
    for (x, y) in ((7, 14), (1, 2), (14, 9)):
        if grass[y][x] and g[y][x] == "g" and y + 1 < N and grass[y + 1][x]:
            g[y][x] = "G"
            g[y + 1][x] = "d"
            break
    return rows(g)


def forest(edge):
    return forest_tile(("s",) if edge else ())


# ---------------------------------------------------------------- mountains v2
# 峰ごとに「列ごとの頂の高さ」と「受光と陰の境（行ごとの x）」を手で決める。
PEAK_A = {
    "top": [7, 6, 5, 5, 4, 3, 2, 1, 1, 2, 3, 3, 4, 5, 6, 7],
    "ridge": lambda y: 8 + (1 if y > 4 else 0) + (1 if y > 9 else 0) - (1 if y > 12 else 0),
    "lines": [(6, 4, 4, "l"), (3, 8, 2, "l"), (7, 9, 4, "l"), (3, 13, 2, "l"), (10, 6, 3, "s"), (12, 9, 3, "s"), (10, 11, 3, "s"), (14, 12, 2, "s")],
}
PEAK_B_BACK = {
    "top": [5, 4, 3, 3, 2, 1, 2, 3, 3, 4, 5, 6, 7, 8, 9, 9],
    "ridge": lambda y: 6 + (1 if y > 6 else 0),
    "lines": [(3, 6, 3, "l"), (8, 6, 3, "s"), (9, 9, 2, "s")],
}
PEAK_B_FRONT = {
    "top": [None, None, None, None, None, None, None, 8, 7, 5, 4, 3, 4, 5, 6, 7],
    "ridge": lambda y: 12 + (1 if y > 9 else 0),
    "lines": [(10, 9, 3, "l"), (14, 9, 2, "s"), (13, 12, 2, "s")],
}
PEAK_SNOW = {
    "top": [6, 5, 5, 4, 3, 2, 1, 0, 0, 1, 2, 3, 4, 5, 5, 6],
    "ridge": lambda y: 8 + (1 if y > 3 else 0) + (1 if y > 8 else 0),
    "lines": [(4, 10, 3, "l"), (6, 12, 3, "l"), (11, 9, 3, "s"), (13, 11, 3, "s"), (10, 12, 2, "s")],
}


def draw_peaks(peaks, ground="g", lit="R", shade="r", lit_line="r", shade_line="k", snowline=None, snow_lit="S", snow_shade="R"):
    g = grid(ground)
    own = [[None] * N for _ in range(N)]
    for i, p in enumerate(peaks):
        for x in range(N):
            t = p["top"][x]
            if t is None:
                continue
            for y in range(t, N):
                own[y][x] = i
    for y in range(N):
        for x in range(N):
            i = own[y][x]
            if i is None:
                continue
            is_lit = x < peaks[i]["ridge"](y)
            if snowline is not None and y <= snowline[x]:
                g[y][x] = snow_lit if is_lit else snow_shade
            else:
                g[y][x] = lit if is_lit else shade
    for i, p in enumerate(peaks):
        for (x0, y0, ln, kind) in p["lines"]:
            for j in range(ln):
                x, y = (x0 - j, y0 + j) if kind == "l" else (x0 + j, y0 + j)
                if 0 <= x < N and 0 <= y < N and own[y][x] == i:
                    if snowline is not None and y <= snowline[x]:
                        continue
                    g[y][x] = lit_line if kind == "l" else shade_line
    # 輪郭: 上の縁・横の縁（地との境）と、前の峰が後ろの峰に重なる縁
    for y in range(N):
        for x in range(N):
            i = own[y][x]
            if i is None:
                continue
            nbs = []
            if y > 0:
                nbs.append(own[y - 1][x])
            if x > 0:
                nbs.append(own[y][x - 1])
            if x < N - 1:
                nbs.append(own[y][x + 1])
            if any(n is None or n < i for n in nbs):
                g[y][x] = "k"
    # 雪の縁の段差（受光面の雪の下に墨の切れ目を間欠で）
    if snowline is not None:
        for x in range(N):
            y = snowline[x] + 1
            if 0 <= y < N and own[y][x] is not None and g[y][x] != "k" and x % 4 != 2:
                g[y][x] = "k"
    # 裾の接地（間欠の墨で地に置く）
    for x in range(N):
        if own[15][x] is not None and x % 5 in (1, 2, 3):
            g[15][x] = "k"
    return g, own


def mountain(variant):
    if variant == "a":
        g, _ = draw_peaks([PEAK_A])
    else:
        g, _ = draw_peaks([PEAK_B_BACK, PEAK_B_FRONT])
    return rows(g)


def mountain_snow():
    snowline = [0, 0, 7, 8, 9, 8, 9, 10, 9, 9, 10, 8, 9, 7, 0, 0]
    # 雪の下の岩は 受光 = R・陰 = 墨の地に R の斜線（色を足さずに陰を作る）
    g, own = draw_peaks([PEAK_SNOW], lit="R", shade="k", lit_line="k", shade_line="R", snowline=snowline)
    for y in range(N):
        for x in range(N):
            if own[y][x] is not None and g[y][x] == "k" and y > snowline[x] + 1 and x >= PEAK_SNOW["ridge"](y) and x < 15:
                if (x + y) % 3 == 0 and own[y][x - 1] is not None and g[y - 1][x] != "k" or (x + y) % 3 == 0 and y > snowline[x] + 2:
                    g[y][x] = "R"
    return rows(g)


def mine():
    # 山と同じ形の峰に、坑道の口。受光面は中間の灰（fc10 の代わりに fc00）、陰は墨の斜線
    g, own = draw_peaks([PEAK_A], lit="r", shade="r", lit_line="k", shade_line="k")
    for y in range(N):
        for x in range(N):
            if own[y][x] is not None and g[y][x] == "r" and x >= PEAK_A["ridge"](y) and (x - y) % 3 == 0:
                g[y][x] = "k"
    # 口と板の枠（梁 y=6..7、柱 x=4 / x=11、口の中は墨）
    for y in range(6, 16):
        for x in range(3, 13):
            g[y][x] = "k"
    for x in range(4, 12):
        g[6][x] = "o"
        g[7][x] = "o" if x % 3 else "k"
    for y in range(8, 15):
        g[y][4] = "o"
        g[y][11] = "o" if y % 3 else "k"
    g[6][3] = "k"; g[6][12] = "k"
    # 奥へ続くレール（口の中の暗がりに中間の灰）
    for y in range(11, 16):
        g[y][6 + (0 if y > 12 else 1) - (1 if y > 14 else 0)] = "r"
        g[y][9 - (0 if y > 12 else 1) + (1 if y > 14 else 0)] = "r"
    for x in (6, 7, 8, 9):
        g[13][x] = "r"
    # 入口脇のたいまつ（灯りの橙）
    g[9][2] = "o"; g[10][2] = "k"; g[11][2] = "k"
    g[9][13] = "o"; g[10][13] = "k"; g[11][13] = "k"
    return rows(g)


def town():
    g = grid("g")
    # 家: (x0, y0, w, 屋根の高さ, 壁の高さ, 戸の x)
    for (x0, y0, w, rh, wh, door) in ((0, 1, 7, 4, 3, 4), (9, 2, 6, 3, 3, 2), (4, 8, 8, 4, 3, 2)):
        for j in range(rh):
            for i in range(w):
                x, y = x0 + i, y0 + j
                # 屋根: 上の縁と左右の縁は墨、本体は赤、瓦の段は 2 行ごとの墨の点線、右 2 列は陰
                if j == 0 or i == 0 or i == w - 1:
                    c = "k"
                elif j % 2 == 0 and (i + j) % 2 == 0:
                    c = "k"
                elif i >= w - 2:
                    c = "k" if (x + y) % 2 == 0 else "h"
                else:
                    c = "h"
                g[y][x] = c
        # 屋根の軒は壁より 1px 外へ出る: 軒下の影
        for j in range(wh):
            for i in range(1, w - 1):
                x, y = x0 + i, y0 + rh + j
                if j == 0:
                    c = "k"
                elif i == 1 or i == w - 2:
                    c = "k"
                elif i == w - 3:
                    c = "c" if (x + y) % 2 else "k"
                else:
                    c = "c"
                if i == door and j >= 1:
                    c = "k"
                if i == door + 2 and j == 1 and i < w - 3:
                    c = "k"
                g[y][x] = c
        # 接地の影（右下へ）
        y = y0 + rh + wh
        if y < N:
            for i in range(2, w):
                x = x0 + i
                if x < N and g[y][x] == "g":
                    g[y][x] = "k" if (x + y) % 2 == 0 or i == w - 1 else "g"
    # 家の間の草の陰
    return rows(g)



HOUSE_BIG = [
    ".kkkkkk.",
    "khhhhhhk",
    "khkhkhkk",
    "kkkkkkkk",
    "kcccckck",
    "kckkcckk",
    "kckkcckk",
    "kkkkkkkk",
]
HOUSE_SMALL = [
    ".kkkkk.",
    "khhhhkk",
    "khkhkhk",
    "kkkkkkk",
    "kcckckk",
    "kcckcck",
    "kkkkkkk",
]


def stamp(g, pat, ox, oy):
    for j, line in enumerate(pat):
        for i, ch in enumerate(line):
            x, y = ox + i, oy + j
            if ch != "." and 0 <= x < N and 0 <= y < N:
                g[y][x] = ch
    # 接地の影（右下へ 1px・間欠）
    y = oy + len(pat)
    for i in range(2, len(pat[0]) + 1):
        x = ox + i
        if 0 <= x < N and 0 <= y < N and g[y][x] == "g" and (x + y) % 2 == 0:
            g[y][x] = "k"
    for j in range(2, len(pat)):
        x, y = ox + len(pat[0]), oy + j
        if 0 <= x < N and 0 <= y < N and g[y][x] == "g" and (x + y) % 2 == 0:
            g[y][x] = "k"


def town():
    g = grid("g")
    stamp(g, HOUSE_SMALL, 9, 0)
    stamp(g, HOUSE_BIG, 0, 1)
    stamp(g, HOUSE_BIG, 7, 6)
    return rows(g)



# ---------------------------------------------------------------- cave mouth（森の中の岩穴）
# 土台は forest_edge_s（北・東西の継ぎ目が森とそろい、南は草地へ開く）。
# 岩の灰 fc10 を入れる代わりに fc2A を外して、墨・fc0A・fc1A・fc10 の 4 枠に収める。
CAVE_ROCK = [
    ".....kkkkkk.....",
    "...kkdRRdRdkk...",
    "..kRRRRRRRRRdk..",
    ".kRRkRRRRRRRRdk.",
    ".kRRRkRRRkRRddk.",
    "kRRRRkkkkkkRRdk.",
    "kRRRkkkkkkkkRddk",
    "kRRkkkkkkkkkkRdk",
    "kRRkkdkkkkkkkRdk",
    "kRdkkkkkkkkkkddk",
    "kRdkkkkkkkkkkRdk",
    "kkkkkkkkkkkkkkkk",
]


def cave_mouth():
    g = [list(r.replace("G", "g")) for r in forest_tile(("s",))]
    for j, line in enumerate(CAVE_ROCK):
        for i, ch in enumerate(line):
            if ch != ".":
                g[3 + j][i] = ch
    # 足元: 転がった石と、口から右下へ落ちる影
    g[15][2] = "R"
    g[15][1] = "k"
    for x in range(3, 15):
        if g[15][x] == "g" and x % 2 == 1:
            g[15][x] = "d"
    return rows(g)


def sp(note, frames, loop=None):
    d = {"note": note, "kind": "tile", "anchor": {"x": 0, "y": 0}, "frames": frames}
    if loop:
        d["loop"] = loop
    return d


S = {}
S["sea"] = sp("海（沖）。波の印が f0→f1 で横へ揺れる。湖も同じ絵を使う。", {"f0": sea_tile(None, 0), "f1": sea_tile(None, 1)})
NAMES = {
    "n": "北の辺が陸", "s": "南の辺が陸", "e": "東の辺が陸", "w": "西の辺が陸",
    "ne": "北と東の 2 辺が陸（水は南西）", "nw": "北と西の 2 辺が陸（水は南東）",
    "se": "南と東の 2 辺が陸（水は北西）", "sw": "南と西の 2 辺が陸（水は北東）",
    "in_ne": "北東の隅だけが陸（岬の先）", "in_nw": "北西の隅だけが陸", "in_se": "南東の隅だけが陸", "in_sw": "南西の隅だけが陸",
}
for k, desc in NAMES.items():
    S["sea_" + k] = sp("岸。" + desc + "。陸の深さは辺の端で 4px（隣の岸とそろう）。", {"f0": sea_tile(k, 0), "f1": sea_tile(k, 1)})
S["plains"] = sp("草原。草の房と、タイルに 1 か所だけ明るい草のディザ。", {"idle": plains(0)})
S["plains_b"] = sp("草原の変種（房の位置と明るい所が違う・小石）。", {"idle": plains(1)})
S["forest"] = sp("森。敷き詰めると冠が互い違いに重なって塊になる（上下左右に継ぎ目が無い）。", {"idle": forest(False)})
S["forest_edge_s"] = sp("森の南の縁。上は forest と同じ冠、下に幹と草地。南に草原が来る所に置く。", {"idle": forest(True)})
S["forest_edge_n"] = sp("森の北の縁。冠の丸みが草原へ張り出して終わる。", {"idle": forest_tile(("n",))})
S["forest_edge_e"] = sp("森の東の縁。", {"idle": forest_tile(("e",))})
S["forest_edge_w"] = sp("森の西の縁。", {"idle": forest_tile(("w",))})
S["forest_ne"] = sp("森の外角（北と東が草原）。", {"idle": forest_tile(("n", "e"))})
S["forest_nw"] = sp("森の外角（北と西が草原）。", {"idle": forest_tile(("n", "w"))})
S["forest_se"] = sp("森の外角（南と東が草原）。南は幹が見える。", {"idle": forest_tile(("s", "e"))})
S["forest_sw"] = sp("森の外角（南と西が草原）。南は幹が見える。", {"idle": forest_tile(("s", "w"))})
S["forest_in_ne"] = sp("森の内角（上下左右は森・北東の斜めだけ草原）。", {"idle": forest_tile((), "ne")})
S["forest_in_nw"] = sp("森の内角（北西の斜めだけ草原）。", {"idle": forest_tile((), "nw")})
S["forest_in_se"] = sp("森の内角（南東の斜めだけ草原）。", {"idle": forest_tile((), "se")})
S["forest_in_sw"] = sp("森の内角（南西の斜めだけ草原）。", {"idle": forest_tile((), "sw")})
S["cave_mouth"] = sp("森の中の岩穴（洞窟の入口）。森の南の縁に置く: 北・東・西の継ぎ目は forest_edge_s と同じで、南は草地へ開く。色は 墨・fc0A・fc1A・fc10。", {"idle": cave_mouth()})
S["hills"] = sp("丘。草の色の小山 2 つ。", {"idle": hills()})
S["mountain"] = sp("山。裾がタイルの左右いっぱいまで広がり、並べると山脈になる。左の面が受光。", {"idle": mountain("a")})
S["mountain_b"] = sp("山の変種（高い峰と低い峰の 2 つ）。", {"idle": mountain("b")})
S["mountain_snow"] = sp("雪をかぶった高い峰。山脈の中ほどに置く。", {"idle": mountain_snow()})
S["road"] = sp("街道（土）。全面が土で、並べた形が道になる。", {"idle": road()})
S["bridge_h"] = sp("東西に渡る橋。上下は水（波の印なし）。", {"idle": bridge(True)})
S["bridge_v"] = sp("南北に渡る橋。左右は水。", {"idle": bridge(False)})
S["town"] = sp("ルーネ村の印。赤い屋根の家 3 軒（大 2・小 1）。戸と窓は墨。", {"idle": town()})
S["mine"] = sp("水晶の坑道の入口。山と同じ形の峰に板の枠の口と左右のたいまつ。山の並びの中に置く。", {"idle": mine()})
S["shrine"] = sp("小さな石の祠。屋根の頂と奥の玉が金。", {"idle": shrine()})

doc = {
    "version": 1,
    "title": "ワールドマップのタイル",
    "note": "場面 world の 1:1 タイル（16×16）。光は左上から。1 タイル = 墨 + 3 色（海と岸 = 墨・fc12・fc21・fc1A / 草原・丘・森 = 墨・fc0A・fc1A・fc2A / 山 = 墨・fc00・fc10・fc1A / 雪の峰 = 墨・fc10・fc20・fc1A / 道 = fc08・fc18・fc38 / 橋 = 墨・fc12・fc17・fc27 / 村 = 墨・fc16・fc37・fc1A / 坑道 = 墨・fc00・fc17・fc1A / 祠 = 墨・fc10・fc28・fc1A / 岩穴 = 墨・fc0A・fc1A・fc10）。海の 13 枚は f0/f1 の 2 コマ。",
    "paletteFile": "assets/rpg.palette.json",
    "legend": LEGEND,
    "sprites": S,
}
with open(OUT, "w") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
print("ok", len(S))
