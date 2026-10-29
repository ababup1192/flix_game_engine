from pxlib import *
from ground import hsh
import math

def outline(c, ch='k'):
    snap = c.copy()
    for y in range(c.h):
        for x in range(c.w):
            if snap.get(x, y) == '.' and any(snap.get(x + dx, y + dy) not in (None, '.') for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                c.set(x, y, ch)

def shadow(c, cx, cy, rx, ry, lv=16):
    # 接地影: 横長の楕円。足元の透明な所だけに落とす
    for y in range(c.h):
        for x in range(c.w):
            if c.get(x, y) == '.' and ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1 and dith(x, y, lv):
                c.set(x, y, 'k')

def clumps(c, circles, ramp, seed=1, tex=True, cuts=(-0.28, 0.42)):
    # 丸い塊の集まり（葉・岩）。奥→手前の順に描き、塊ごとに左上を明るく
    # ramp は暗→明の 3 色か 4 色。cuts はその境の値
    owner = {}
    for k, (cx, cy, rx, ry) in enumerate(circles):
        for y in range(c.h):
            for x in range(c.w):
                if ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2 <= 1: owner[(x, y)] = k
    for (x, y), k in owner.items():
        cx, cy, rx, ry = circles[k]
        nx, ny = (x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry
        v = -(nx * 0.7 + ny * 0.75)
        idx = sum(1 for t in cuts if v > t)
        # 境の手前 0.12 の帯だけ 1 段上と混ぜる（面の階調。小さい物には効かせない）
        if tex and idx < len(cuts) and v > cuts[idx] - 0.14 and dith(x, y, 6): idx += 1
        c.set(x, y, ramp[idx])
    for (x, y), k in owner.items():
        dn = owner.get((x, y + 1))
        if dn is not None and dn > k: c.set(x, y, ramp[0])
    return c

def tree():
    c = Cv(16, 16)
    c.stamp(6, 10, ["kmmk", "kmmk", "kmmk", "kkkk"])
    clumps(c, [(10.5, 5.5, 4.6, 4.2), (5.5, 6.0, 4.6, 4.2), (8.0, 3.8, 5.0, 3.8), (8.0, 8.6, 5.6, 3.0)], ('k', 'd', 'e', 'f'), cuts=(-0.5, 0.2, 0.62))
    for (x, y) in []:
        if c.get(x, y) == 'e': c.set(x, y, 'f')
    for y in range(12, 15): c.set(6, y, 'k'); c.set(7, y, 'm'); c.set(8, y, 'm'); c.set(9, y, 'k')
    outline(c)
    shadow(c, 8.5, 14.6, 5.5, 1.6)
    return c

def big_tree():
    c = Cv(32, 32)
    clumps(c, [(10, 9, 7.5, 6.5), (21, 8, 7.5, 6.5), (15.5, 5.5, 8, 5.5), (7.5, 15, 6.5, 5.5), (24, 15, 6.5, 5.5), (15.5, 13, 9, 6.5), (15.5, 19, 9.5, 4.5)], ('k', 'd', 'e', 'f'), cuts=(-0.5, 0.2, 0.62))
    for (x, y) in []:
        if c.get(x, y) == 'e': c.set(x, y, 'f')
    for y in range(22, 29):
        for x in range(12, 20):
            c.set(x, y, 'o' if x < 15 else 'm')
    for (x, y) in [(15, 24), (16, 25), (14, 27), (17, 23)]: c.set(x, y, 'm')
    c.stamp(10, 28, ["kkmm....mmk", "..........."])
    c.set(11, 28, 'm'); c.set(19, 28, 'm'); c.set(20, 28, 'm')
    outline(c)
    shadow(c, 17, 29.5, 11, 2.2)
    return c

def bush():
    c = Cv(16, 16)
    clumps(c, [(5, 9.5, 4.2, 3.6), (11, 9.5, 4.2, 3.6), (8, 7.5, 4.6, 3.6), (8, 11.0, 5.5, 2.6)], ('k', 'd', 'e', 'f'), cuts=(-0.55, 0.0, 0.5), tex=False)
    outline(c)
    shadow(c, 9, 14.2, 6.5, 1.5)
    return c

def rock():
    c = Cv(16, 16)
    clumps(c, [(9.5, 9.5, 5.0, 3.8), (6.0, 9.0, 4.4, 3.8), (8.0, 11.0, 6.0, 2.6)], ('g', 'G', 'p'), tex=False)
    for (x, y) in [(5, 9), (6, 10), (11, 10), (12, 11)]:
        if c.get(x, y) in 'Gg': c.set(x, y, 'k' if (x + y) % 2 else 'g')
    outline(c)
    shadow(c, 9.5, 13.8, 6.5, 1.4)
    return c

def barrel():
    c = Cv(16, 16)
    for y in range(3, 14):
        t = (y - 8.5) / 6.0
        half = 5.0 - 0.9 * t * t * 1.2
        for x in range(16):
            dx = x + 0.5 - 8
            if abs(dx) <= half:
                u = (dx + half) / (2 * half)
                ch = 'O' if u < 0.3 else 'o' if u < 0.72 else 'm'
                c.set(x, y, ch)
    # 板の継ぎ目
    for y in range(5, 13):
        for x in (6, 10):
            if c.get(x, y) not in '.': c.set(x, y, 'm' if x == 10 else 'o')
    # たが
    for y in (5, 11):
        for x in range(16):
            if c.get(x, y) not in '.': c.set(x, y, 'k' if x > 5 else 'm')
    # ふた（上から見える楕円）
    for y in range(1, 6):
        for x in range(16):
            if ((x + 0.5 - 8) / 4.6) ** 2 + ((y + 0.5 - 3.4) / 1.9) ** 2 <= 1:
                c.set(x, y, 'O' if y < 3 else 'o')
    for x in range(5, 11): c.set(x, 3, 'm') if x != 7 else None
    outline(c)
    shadow(c, 9, 14.5, 6.5, 1.5)
    return c

def crate():
    c = from_rows([
        "................",
        "................",
        "................",
        "...kkkkkkkkkkk..",
        "..kOOOOOOOOOOok.",
        "..kOkkkkkkkkkok.",
        "..kOOOOOOOOOOok.",
        "..kkkkkkkkkkkkk.",
        "..kOoooooooomok.",
        "..kOmmmmmmmmmmk.",
        "..kOoooooooooomk",
        "..kOmmmmmmmmmmk.",
        "..kOoooooooooomk",
        "..kOmmmmmmmmmmk.",
        "..kkkkkkkkkkkkk.",
        "................",
    ])
    shadow(c, 9.5, 15.0, 7.5, 1.6)
    return c

def signpost():
    c = from_rows([
        "................",
        ".kkkkkkkkkkkk...",
        "kOOOOOOOOOOOok..",
        "kOkkOkkkOkkOook.",
        "kOOOOOOOOOOOooOk",
        "kOkkkOkkOOOOook.",
        "koooooooooooook.",
        ".kkkkkkkkkkkkk..",
        "......kOmk......",
        "......kOmk......",
        "......kOmk......",
        "......kOmk......",
        "......kOmk......",
        "......kOmk......",
        "......kkkk......",
        "................",
    ])
    shadow(c, 9, 14.6, 4, 1.2)
    return c

def anvil():
    c = from_rows([
        "................",
        "................",
        "................",
        "................",
        ".kkkkkkkkkkkk...",
        "kGGGGGGGGGGGGkk.",
        "kpppGGGGGGGGgGgk",
        ".kgggggggggggkk.",
        "...kkggggkkk....",
        "....kgggk.......",
        "..kkkkkkkkkkk...",
        ".kooooooooomk...",
        ".kooooooooommk..",
        ".komooooommmmk..",
        "..kkkkkkkkkkk...",
        "................",
    ])
    shadow(c, 8, 14.8, 7, 1.3)
    return c

def fence_h():
    c = from_rows([
        "................",
        "................",
        "................",
        "................",
        "..kkkk......kkkk",
        "..kOok......kOok",
        "kkkOokkkkkkkkOok",
        "OOkOokOOOOOOkOok",
        "mmkOokmmmmmmkOok",
        "kkkOokkkkkkkkOok",
        "..kOok......kOok",
        "kkkOmkkkkkkkkOmk",
        "OOkOmkOOOOOOkOmk",
        "mmkOmkmmmmmmkOmk",
        "kkkmmkkkkkkkkmmk",
        "..kkkk......kkkk",
    ])
    for x in (6, 7, 0):
        pass
    c.set(6, 15, 'k'); c.set(7, 15, 'k')
    return c

def fence_v():
    post = [
        ".....kkkkkk.....",
        ".....kOOOok.....",
        ".....kOoomk.....",
        ".....kOoomk.....",
        ".....kOommk.....",
        ".....kkkkkkk....",
        "......kOmkkk....",
        "......kOmk......",
    ]
    return from_rows(post + post)

def forge(frame):
    c = Cv(32, 32)
    base = [
        "................................",
        "................................",
        "..........kkkkkkkkkkkk..........",
        "..........kpGGGGGGGGgk..........",
        "..........kGkkkkkkkkgk..........",
        "..........kGGGGGGGGGgk..........",
        "........kkkkkkkkkkkkkkkk........",
        "......kkpppGGGGGGGGGGGGgkk......",
        ".....kpGGGGGGGGGGGGGGGGGggk.....",
        "....kkkkkkkkkkkkkkkkkkkkkkkk....",
        "....kpGGkGGGGkGGGGkGGGGkGGgk....",
        "....kpGGkGGGGkGGGGkGGGGkGggk....",
        "....kkkkkkkkkkkkkkkkkkkkkkkk....",
        "....kpGGGGkGGGGkkkkGGGGkGggk....",
        "....kpGGGGkGGkk....kkGGkGggk....",
        "....kkkkkkkkk........kkkkkkk....",
        "....kpGGkGGk..........kGGGgk....",
        "....kpGGkGk............kGggk....",
        "....kkkkkkk............kkkkk....",
        "....kpGGGGk............kGGgk....",
        "....kpGGGGk............kGggk....",
        "....kkkkkkk............kkkkk....",
        "....kpGGkGk............kGggk....",
        "....kpGGkGk............kGggk....",
        "....kkkkkkkkkkkkkkkkkkkkkkkk....",
        "....kGGGGGGGGGGGGGGGGGGGGggk....",
        "....kggggggggggggggggggggggk....",
        "....kkkkkkkkkkkkkkkkkkkkkkkk....",
        "................................",
        "................................",
        "................................",
        "................................",
    ]
    c = from_rows(base)
    # 炉の口の中: 奥は墨、炭の上で火が揺れる
    for y in range(13, 24):
        for x in range(4, 28):
            if c.get(x, y) == '.': c.set(x, y, 'k')
    fires = [
        ["......y.....", "....y.yy....", "...yyOyy.y..", "..yOOOOOyy..", "..yOOrOOOy..", ".yOOrrrOOOy.", ".yOrrrrrOOy.", "yOrrkrrkrrOy", "rrrkkrrkkrrr"],
        [".....y......", "...yy.y.y...", "..yyOyyOy...", "..yOOOOOOy..", ".yOOrOOOOy..", ".yOrrrrOOOy.", "yOOrrrrrrOy.", "yOrrkrrkrrOy", "rrrkkrrkkrrr"],
        ["......y.y...", "..y..yy.....", "..yyOyyy....", "..yOOOOOyy..", "..yOOOrOOy..", ".yOOrrrrOOy.", ".yOrrrrrrOy.", "yOrrkrrkrrOy", "rrrkkrrkkrrr"],
    ]
    c.stamp(10, 15, fires[frame], only_on='k')
    # 火の照り返し（口の縁）
    for (x, y) in [(11, 15), (20, 15), (12, 14), (19, 14)]:
        if c.get(x, y) == 'G': c.set(x, y, 'O')
    # 煙突の口から火の粉
    sp = [[(15, 1), (17, 0), (17, 1)], [(16, 1), (16, 0)], [(14, 1), (17, 1)]][frame]
    for (x, y) in sp: c.set(x, y, 'y')
    # 接地影
    for x in range(5, 30):
        if c.get(x, 28) == '.': c.set(x, 28, 'k' if x > 6 else '.')
        if c.get(x, 29) == '.' and dith(x, 29, 8) and 8 < x < 29: c.set(x, 29, 'k')
    return c

PROPS = {
    'fence_h': fence_h, 'fence_v': fence_v, 'tree': tree, 'big_tree': big_tree, 'bush': bush, 'rock': rock,
    'barrel': barrel, 'crate': crate, 'signpost': signpost, 'anvil': anvil,
}
