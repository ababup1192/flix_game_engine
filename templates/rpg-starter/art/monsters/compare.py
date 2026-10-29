"""Lay the previous boss next to the current one: python3 compare.py <old sprite.json> <out name>"""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *


def load(path, name):
    d = json.load(open(path))
    lg = d['legend']
    out = []
    for fr in ('idle_0', 'idle_1'):
        rows = d['sprites'][name]['frames'][fr]
        g = Grid(len(rows[0]), len(rows))
        for y, r in enumerate(rows):
            for x, ch in enumerate(r):
                if ch != '.':
                    g.set(x, y, lg[ch])
        out.append(g)
    return out


old = load(sys.argv[1], 'boss')
new = load(ROOT + '/assets/rpg.monsters.sprite.json', 'boss')
c0, c2d = rgb('fc00'), rgb('fc2D')
rock = lambda x, y: c0 if ((x // 3 + y // 5) % 4 == 0 and (x + y) % 2 == 0) else (c2d if y % 7 else c0)
canvas = compose(old + new, rgb('ink'), 6) + compose(old + new, None, 6, bgfn=rock)
base = ROOT + '/debug/monsters/' + sys.argv[2]
save(base + '_x1.png', canvas, 1)
save(base + '_x4.png', canvas, 4)
