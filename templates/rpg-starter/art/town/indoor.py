from pxlib import *
from props import outline, shadow, clumps

def floor_wood():
    # 横に長い板。継ぎ目は 4 枚に 1 か所だけ、板の間は細い墨の線、木目は長く薄く
    c = Cv(16, 16, 'm')
    grain = [[(2, 1, 7)], [(9, 2, 6)], [(5, 1, 5), (13, 2, 4)], [(0, 2, 6)]]
    for p in range(4):
        y0 = p * 4
        for x in range(16): c.set(x, y0 + 3, 'k')
        for (gx, gy, ln) in grain[p]:
            for d in range(ln): c.set((gx + d) % 16, y0 + gy, 'n')
    return c

def wall_in():
    c = Cv(16, 16, 'p')
    for x in range(16):
        c.set(x, 0, 'G'); c.set(x, 1, 'G' if dith(x, 1, 8) else 'p')
        c.set(x, 9, 'k'); c.set(x, 10, 'o'); c.set(x, 11, 'm')
        for y in range(12, 15): c.set(x, y, 'm' if x % 4 == 3 else 'o')
        c.set(x, 15, 'k')
    c.stamp(4, 4, ["GG", ".G"]); c.stamp(12, 6, ["G.", "GG"])
    return c

def wall_top():
    # 部屋の外。画面の外として墨の地にし、ごく弱い点だけ置く
    c = Cv(16, 16, 'k')
    c.stamp(3, 5, ["VV"]); c.stamp(11, 12, ["V"])
    return c

def window_in():
    c = wall_in()
    c.stamp(3, 1, [
        "kkkkkkkkkk",
        "kOOOOOOOOk",
        "kOccBkcBmk",
        "kOcBBkBBmk",
        "kOBBBkBBmk",
        "kOkkkkkkmk",
        "kOBBbkbbmk",
        "kmmmmmmmmk",
        "kkkkkkkkkk",
    ])
    return c

def rug():
    c = Cv(32, 32)
    for y in range(2, 30):
        for x in range(1, 31):
            c.set(x, y, 's')
    for y in range(2, 30):
        for x in range(1, 31):
            if x in (1, 30) or y in (2, 29): c.set(x, y, 'k')
            elif x in (2, 29) or y in (3, 28): c.set(x, y, 'r')
            elif x in (4, 27) or y in (5, 26): c.set(x, y, 'y')
            elif (x < 4 or x > 27 or y < 5 or y > 26):
                c.set(x, y, 'r' if (x + y) % 4 == 0 else 's')
    # 中央の菱形
    for y in range(6, 26):
        for x in range(5, 27):
            d = abs(x - 15.5) / 9.5 + abs(y - 15.5) / 8.5
            if 0.92 < d <= 1.02: c.set(x, y, 'y')
            elif d < 0.45 and abs(d - 0.3) < 0.08: c.set(x, y, 'y')
            elif d <= 0.92 and d > 0.85: c.set(x, y, 'r')
            elif d < 0.15: c.set(x, y, 'r')
    # 房（上下の端）
    for x in range(2, 30):
        if x % 2 == 0: c.set(x, 1, 'y'); c.set(x, 30, 'y')
        else: c.set(x, 0, '.'); 
    # 敷物の光（左上だけ明るく）
    for y in range(6, 14):
        for x in range(5, 14):
            pass
    return c

def table():
    c = Cv(32, 16)
    for y in range(1, 11):
        for x in range(1, 31):
            c.set(x, y, 'O' if y < 9 else 'o')
    for (y, x0, x1) in [(3, 4, 12), (5, 17, 27), (7, 7, 15)]:
        for x in range(x0, x1): c.set(x, y, 'o')
    for x in range(1, 31): c.set(x, 9, 'o'); c.set(x, 10, 'm')
    # 脚（手前の 2 本だけ）
    for y in range(11, 14):
        for x in (3, 4, 27, 28): c.set(x, y, 'm' if x in (4, 28) else 'o')
    outline(c)
    # 光の通り道（左上の窓から）
    for y in range(2, 8):
        for x in range(2, 30):
            if 10 + (y - 2) <= x <= 13 + (y - 2) and c.get(x, y) == 'O': c.set(x, y, 'N')
    shadow(c, 16.5, 13.6, 14.5, 2.0)
    return c

def chair():
    c = from_rows([
        "................",
        "....kkkkkkk.....",
        "....kOOOOok.....",
        "....kOkkkok.....",
        "....kOOOOmk.....",
        "....kOkkkmk.....",
        "....kOoooomk....",
        "...kkkkkkkkk....",
        "...kOOOOOOOOk...",
        "...kOOOOOOOok...",
        "...kooooooomk...",
        "...kmkkkkkmmk...",
        "...kok....kmk...",
        "...kok....kmk...",
        "...kkk....kkk...",
        "................",
    ])
    shadow(c, 9, 14.6, 5.5, 1.3)
    return c

def bookshelf():
    c = Cv(16, 32)
    rows = [
        "kkkkkkkkkkkkkkkk",
        "kOOOOOOOOOOOOOok",
        "koooooooooooommk",
        "kkkkkkkkkkkkkkkk",
    ]
    c.stamp(0, 0, rows)
    shelves = [(4, ['s', 's', 'r']), (12, ['b', 'b', 'w']), (20, ['e', 'e', 'd'])]
    for (y0, (mid, lt, dk)) in shelves:
        for y in range(y0, y0 + 8):
            c.set(0, y, 'k'); c.set(1, y, 'o'); c.set(14, y, 'm'); c.set(15, y, 'k')
            for x in range(2, 14): c.set(x, y, 'k')
        hts = [6, 5, 6, 4, 6, 5, 3, 6, 5, 6, 4, 6]
        for i, x in enumerate(range(2, 14)):
            h = hts[(i + y0) % 12]
            if (i + y0 // 4) % 7 == 6: continue
            for y in range(y0 + 7 - h, y0 + 7):
                ch = lt if x % 3 == 0 else (dk if x % 3 == 2 else mid)
                c.set(x, y, ch)
        for x in range(1, 15): c.set(x, y0 + 7, 'o')
    for y in range(28, 32):
        for x in range(16): c.set(x, y, 'o' if 0 < x < 15 else 'k')
    for x in range(16): c.set(x, 28, 'O' if 0 < x < 15 else 'k'); c.set(x, 31, 'k')
    for x in range(1, 15): c.set(x, 30, 'm')
    return c

def fireplace(frame):
    c = Cv(32, 32)
    for y in range(0, 30):
        for x in range(1, 31):
            c.set(x, y, 'G')
    # 石積み（段違い）
    for y in range(0, 30):
        r = y % 5; off = 0 if (y // 5) % 2 == 0 else 3
        for x in range(1, 31):
            if r == 4: c.set(x, y, 'g')
            elif (x + off) % 6 == 0: c.set(x, y, 'g')
            elif r == 0 and (x + off) % 6 in (1, 2): c.set(x, y, 'p')
    # 棚板（マントル）
    for x in range(0, 32):
        c.set(x, 9, 'k'); c.set(x, 10, 'o'); c.set(x, 11, 'm'); c.set(x, 12, 'm'); c.set(x, 13, 'k')
    # 火の口
    for y in range(15, 29):
        for x in range(6, 26):
            arch = y > 17 or (abs(x - 15.5) < 10 - (17 - y) * 1.6)
            if arch: c.set(x, y, 'k')
    for y in range(15, 29):
        for x in range(5, 27):
            if c.get(x, y) == 'k' and any(c.get(x + dx, y + dy) == 'G' or c.get(x + dx, y + dy) == 'p' for dx, dy in ((1, 0), (-1, 0), (0, -1))):
                pass
    fires = [
        ["......y.....", "....y.yy....", "...yyOyy.y..", "..yOOOOOyy..", "..yOOsOOOy..", ".yOOsssOOOy.", ".yOssrssOOy.", "ySssrrrssOy."],
        [".....y......", "...yy.y.y...", "..yyOyyOy...", "..yOOOOOOy..", ".yOOsOOOOy..", ".yOsssOOOOy.", "yOOssrsssOy.", "ySssrrrrsOy."],
        ["......y.y...", "..y..yy.....", "..yyOyyy....", "..yOOOOOyy..", "..yOOOsOOy..", ".yOOssssOOy.", ".yOssrrssOy.", "yOssrrrrsOy."],
    ]
    c.stamp(10, 18, fires[frame], only_on='k')
    c.stamp(8, 26, ["..mmmmmmmmmmmm..", "kmoOommmOoomomk.", "kkmmkkkkmmkkmmkk"])
    # 炉床
    for x in range(0, 32):
        c.set(x, 29, 'p' if x % 5 else 'G'); c.set(x, 30, 'G'); c.set(x, 31, 'k')
    for y in range(0, 32): c.set(0, y, 'k'); c.set(31, y, 'k')
    # 照り返し
    for (x, y) in [(6, 17), (25, 17), (5, 20), (26, 20), (5, 23), (26, 23)]:
        if c.get(x, y) in 'Gp': c.set(x, y, 'O')
    return c

def bed():
    c = Cv(16, 32)
    c.stamp(0, 0, [
        ".kkkkkkkkkkkkkk.",
        "kOOOOOOOOOOOOOok",
        "kOoooooooooooomk",
        "kOkkkkkkkkkkkomk",
        "kOkppppppppGkomk",
        "kOkpppppppGGkomk",
        "kOkpGGGGGGGGkomk",
        "kOkkkkkkkkkkkomk",
    ])
    for y in range(8, 28):
        c.set(0, y, 'k'); c.set(1, y, 'O'); c.set(14, y, 'm'); c.set(15, y, 'k')
        for x in range(2, 14):
            ch = 'B' if x < 5 else 'b' if x < 12 else 'w'
            if y == 8: ch = 'B'
            if y == 10 and 2 < x < 13: ch = 'w'
            if y == 11 and 2 < x < 13: ch = 'B'
            c.set(x, y, ch)
    for y in range(14, 27, 4):
        for x in range(4, 12):
            if (x + y) % 4 == 0: c.set(x, y, 'B')
    c.stamp(0, 27, [
        "kOkkkkkkkkkkkomk",
        "kOOOOOOOOOOOOomk",
        "koooooooooooommk",
        "kmmmmmmmmmmmmmmk",
        "kkkkkkkkkkkkkkkk",
    ])
    return c

def pot():
    c = Cv(16, 16)
    for y in range(4, 14):
        for x in range(16):
            dx = (x + 0.5 - 8) / 5.6; dy = (y + 0.5 - 9.5) / 4.6
            if dx * dx + dy * dy <= 1:
                v = -(dx * 0.7 + dy * 0.6)
                c.set(x, y, 'O' if v > 0.45 else 'm' if v < -0.35 else 'o')
    c.stamp(4, 2, ["kkkkkkkk", "kOookkok", ".kmmmmk."], )
    c.set(5, 8, 'p'); c.set(6, 7, 'p')
    for x in range(3, 13):
        if c.get(x, 10) not in '.': c.set(x, 10, 'm' if x % 2 else 'o')
    outline(c)
    shadow(c, 9, 14.6, 6, 1.3)
    return c

INDOOR = {'floor_wood': floor_wood, 'wall_in': wall_in, 'wall_top': wall_top, 'rug': rug, 'table': table,
          'chair': chair, 'bookshelf': bookshelf, 'bed': bed, 'pot': pot, 'window_in': window_in}
