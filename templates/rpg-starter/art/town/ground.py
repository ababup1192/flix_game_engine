from pxlib import *

def tdist(x, y, cx, cy, rx, ry, n=16):
    dx = min(abs(x - cx), n - abs(x - cx)) / rx
    dy = min(abs(y - cy), n - abs(y - cy)) / ry
    return (dx * dx + dy * dy) ** 0.5

TA = ["f.f", "d.d", ".d."]
TB = [".f..", "fd.f", "d.dd", ".d.."]
TC = ["f.", "dd"]
TD = ["..f", "f.d", "dd."]

def blob(c, cx, cy, rx, ry, ch, lv, ox=0):
    # 中心ほど密になるディザの斑。縁はタイルを回り込む
    for y in range(16):
        for x in range(16):
            t = tdist(x, y, cx, cy, rx, ry)
            if t < 1 and dith(x + ox, y, int(lv * (1 - t) ** 0.7 + 1)): c.set(x, y, ch)

def grass_base(blobs, tufts):
    c = Cv(16, 16, 'e')
    for b in blobs: blob(c, *b)
    for (x, y, sh) in tufts: c.stamp(x, y, sh, wrap=True)
    return c

def hsh(x, y, s):
    v = (x * 374761393 + y * 668265263 + s * 2246822519) & 0xffffffff
    v = ((v ^ (v >> 13)) * 1274126177) & 0xffffffff
    return (v ^ (v >> 16)) / 0xffffffff

def scatter(c, dens, shapes, seed, tries=1):
    taken = set()
    for y in range(16):
        for x in range(16):
            if hsh(x, y, seed) < dens(x, y):
                sh = shapes[int(hsh(x, y, seed + 7) * len(shapes))]
                cells = [(x + i, y + j) for j, r in enumerate(sh) for i, ch in enumerate(r) if ch not in ' .']
                ring = {((px + dx) % 16, (py + dy) % 16) for (px, py) in cells for dx, dy in ((0,0),(1,0),(-1,0),(0,1),(0,-1))}
                if ring & taken: continue
                taken |= {(px % 16, py % 16) for (px, py) in cells}
                c.stamp(x, y, sh, wrap=True)

LIGHT = [["ff"], ["f", "f"], [".f", "ff"], ["fe", ".f"]]
DARK = [["dd"], ["d.d", ".d."], [".d", "dd"], ["d", "d"]]

def grass():
    c = Cv(16, 16, 'e')
    scatter(c, lambda x, y: 0.10 * max(0, 1 - tdist(x, y, 4, 4, 9, 7)), LIGHT, 3)
    scatter(c, lambda x, y: 0.08 * max(0, 1 - tdist(x, y, 12, 12, 9, 7)), DARK, 5)
    for (x, y, sh) in [(9, 1, TB), (1, 10, TA), (13, 6, TC)]: c.stamp(x, y, sh, wrap=True)
    return c

def grass_b():
    c = Cv(16, 16, 'e')
    scatter(c, lambda x, y: 0.10 * max(0, 1 - tdist(x, y, 12, 3, 9, 7)), LIGHT, 11)
    scatter(c, lambda x, y: 0.09 * max(0, 1 - tdist(x, y, 4, 11, 9, 7)), DARK, 13)
    for (x, y, sh) in [(2, 1, TA), (7, 6, TB), (12, 12, TD)]: c.stamp(x, y, sh, wrap=True)
    return c

def flowers():
    c = Cv(16, 16, 'e')
    scatter(c, lambda x, y: 0.08 * max(0, 1 - tdist(x, y, 12, 12, 9, 7)), DARK, 31)
    FL = [".P.", "PkP", ".d."]
    FL2 = [".P", "Pk", "d."]
    for (x, y, s) in [(2, 2, FL), (9, 4, FL2), (5, 10, FL), (13, 11, FL), (6, 5, FL2), (12, 7, FL2), (0, 7, FL2)]:
        c.stamp(x, y, s, wrap=True)
    return c

def tall_grass():
    # 地は草と同じ中の緑にして、敷いた区画の縁を角張らせない。葉の束を密に置く
    c = Cv(16, 16, 'e')
    BL = ["f...f", "df.fd", "dd.dd", ".kdk."]
    BL2 = ["..f..", ".fd.f", "fdd.d", "kd.dk"]
    for (x, y, s) in [(0, 0, BL), (6, 1, BL2), (11, 0, BL), (3, 5, BL2), (9, 5, BL), (14, 6, BL2),
                      (0, 10, BL2), (6, 10, BL), (11, 11, BL2), (2, 14, BL), (9, 15, BL2)]:
        c.stamp(x, y, s, wrap=True)
    return c

def path():
    c = Cv(16, 16, 'n')
    scatter(c, lambda x, y: 0.12 * max(0, 1 - tdist(x, y, 4, 4, 9, 7)), [["NN"], ["N", "N"], [".N", "NN"]], 21)
    scatter(c, lambda x, y: 0.10 * max(0, 1 - tdist(x, y, 12, 12, 9, 7)), [["mm"], ["m.", "mm"], ["m"]], 23)
    PEB = ["N.", "mm"]
    PEB2 = [".N.", "Nnm", ".mm"]
    for (x, y, s) in [(9, 2, PEB2), (2, 9, PEB), (14, 6, PEB), (6, 13, PEB2), (12, 14, PEB)]:
        c.stamp(x, y, s, wrap=True)
    return c

def voronoi(seeds, n=16):
    lab = [[0] * n for _ in range(n)]
    for y in range(n):
        for x in range(n):
            best = None
            for k, (sx, sy, ax) in enumerate(seeds):
                dx = min(abs(x - sx), n - abs(x - sx)) * ax
                dy = min(abs(y - sy), n - abs(y - sy))
                d = dx * dx + dy * dy
                if best is None or d < best[0]: best = (d, k)
            lab[y][x] = best[1]
    return lab

def cobble():
    seeds = [(3, 2, 1.0), (10, 1, 0.8), (14, 6, 1.0), (6, 7, 0.8), (1, 11, 1.0), (9, 12, 0.9), (13, 13, 1.0), (1, 6, 1.2)]
    lab = voronoi(seeds)
    L = lambda x, y: lab[y % 16][x % 16]
    edge = lambda x, y: L(x + 1, y) != L(x, y) or L(x, y + 1) != L(x, y)
    # 泉を浮かせるため、広場の石は一段沈めた灰（石 = fc00・光 = fc10・目地 = 墨）
    c = Cv(16, 16, 'g')
    for y in range(16):
        for x in range(16):
            if edge(x, y):
                c.set(x, y, 'k' if (L(x, y + 1) != L(x, y) or hsh(x, y, 43) < 0.5) else 'h')
                continue
            up, lf = edge(x, y - 1), edge(x - 1, y)
            if up and lf: continue
            if (up or lf) and hsh(x, y, 41) < 0.75: c.set(x, y, 'G')
    return c

def field():
    c = Cv(16, 16, 'n')
    for y in range(16):
        for x in range(16):
            r = y % 4
            if r == 3: c.set(x, y, 'm')
    SP = ["e.e", ".e."]
    SP2 = ["ee"]
    for (x, y, s) in [(1, 0, SP), (6, 1, SP2), (11, 0, SP), (3, 4, SP2), (8, 4, SP), (14, 5, SP2),
                      (0, 8, SP2), (5, 8, SP), (12, 9, SP), (2, 12, SP), (9, 13, SP2), (13, 12, SP)]:
        c.stamp(x, y, s, wrap=True)
    return c

GROUND = {'grass': grass, 'grass_b': grass_b, 'flowers': flowers, 'tall_grass': tall_grass,
          'path': path, 'cobble': cobble, 'field': field}
