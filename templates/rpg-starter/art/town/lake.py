from pxlib import *
from ground import hsh

WAVES = [(2, 2), (10, 4), (5, 8), (13, 11), (1, 13), (8, 14)]
W0 = [".BB.", "B..B", ".ww."]
W1 = ["BB..", "..BB", "ww.."]

def water(frame, deep=True):
    c = Cv(16, 16, 'b')
    for k, (x, y) in enumerate(WAVES):
        sh = (W0 if (k + frame) % 2 == 0 else W1)
        if k % 3 == 1: sh = [r[:3] for r in sh]
        if not deep: sh = [r.replace('w', '.') for r in sh]
        c.stamp(x, y, sh, wrap=True)
    return c

def shore_mask(name):
    R = 4
    def straight(side):
        def f(x, y):
            bump = 1 if (side in 'ns' and 6 <= x <= 9) or (side in 'ew' and 5 <= y <= 8) else 0
            if side == 'n': return y < 4 + (bump if x in (7, 8) else 0)
            if side == 's': return y >= 12 - (bump if x in (6, 7, 8) else 0)
            if side == 'e': return x >= 12 - (bump if y in (6, 7) else 0)
            if side == 'w': return x < 4 + (bump if y in (7, 8) else 0)
        return f
    sides = {'n': straight('n'), 's': straight('s'), 'e': straight('e'), 'w': straight('w')}
    if name in sides: return sides[name]
    if name.startswith('in_'):
        d = name[3:]
        cx = 15.5 if 'e' in d else -0.5
        cy = -0.5 if 'n' in d else 15.5
        return lambda x, y: (x - cx) ** 2 + (y - cy) ** 2 <= 4.6 ** 2
    # 外角: 2 辺が岸。水の角を丸める
    a, b = name[0], name[1]
    wx0, wx1 = (0, 11) if b == 'e' else (4, 15)
    wy0, wy1 = (4, 15) if a == 'n' else (0, 11)
    ccx = wx1 - R + 0.5 if b == 'e' else wx0 + R - 0.5
    ccy = wy0 + R - 0.5 if a == 'n' else wy1 - R + 0.5
    def f(x, y):
        if not (wx0 <= x <= wx1 and wy0 <= y <= wy1): return True
        inx = (x > ccx) if b == 'e' else (x < ccx)
        iny = (y < ccy) if a == 'n' else (y > ccy)
        if inx and iny and (x - ccx) ** 2 + (y - ccy) ** 2 > R * R: return True
        return False
    return f

def shore(name, frame):
    m = shore_mask(name)
    g = lambda x, y: (0 <= x < 16 and 0 <= y < 16 and m(x, y))
    # タイルの外は、その向きに続く同じ形として扱う（縁の判定を継ぎ目でそろえる）
    def G(x, y):
        x2 = min(max(x, 0), 15); y2 = min(max(y, 0), 15)
        return m(x2, y2)
    w = water(frame, deep=False)
    c = Cv(16, 16)
    for y in range(16):
        for x in range(16):
            if G(x, y): c.set(x, y, 'e'); continue
            if G(x, y - 1) or G(x - 1, y) or G(x + 1, y) or G(x, y + 1): c.set(x, y, 'k'); continue
            if G(x, y - 2) and dith(x, y, 8): c.set(x, y, 'k'); continue
            near = G(x, y - 2) or G(x - 2, y) or G(x + 2, y) or G(x, y + 2) or G(x, y - 3)
            if near:
                # 岸の泡は間欠に（全周に回さない）
                ph = (x + y + frame * 2) % 7
                c.set(x, y, 'B' if ph in (0, 1) else 'b'); continue
            c.set(x, y, w.get(x, y))
    return c

LAKE_NAMES = ['n', 's', 'e', 'w', 'ne', 'nw', 'se', 'sw', 'in_ne', 'in_nw', 'in_se', 'in_sw']
def lake_frames(name):
    if name == '': return {f'f{i}': water(i).rows() for i in (0, 1)}
    return {f'f{i}': shore(name, i).rows() for i in (0, 1)}
