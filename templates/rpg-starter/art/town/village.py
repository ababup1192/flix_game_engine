import sys, json; sys.path.insert(0, '.')
from pxlib import *
D = json.load(open(ROOT + '/assets/rpg.town.sprite.json'))
SP = D['sprites']
def fr(n, f=None):
    frs = SP[n]['frames']; return frs[f] if f in frs else list(frs.values())[0]
# 地面（16×15）
M = [
 "GgGGgGGGgGGgGGgG",
 "GGgGGGgGGgGGgGGG",
 "gGGGGgGGGGgGGGgG",
 "GGGGGGGgGGGGGGGG",
 "GgGPGGgGGGGPGFGg",
 "GGGPPPPCCPPPGGGF",
 "gFGGGGCCCCGPGGGG",
 "GFFGGGCCCCGPGfff",
 "GGGGGgCCCCGPGfff",
 "PPPPPPPCCPPPPfff",
 "GGgGGGGPPGgGGfff",
 "~~~~GgGPPGGGGGGg",
 "~~~~~~GPPGtGGgGG",
 "~~~~~~gPPGttGGGG",
 "~~~~~~GPPGGGgGGG",
]
LAKE = {
 (0, 11): 'lake_n', (1, 11): 'lake_n', (2, 11): 'lake_n', (3, 11): 'lake_ne',
 (0, 12): 'lake', (1, 12): 'lake', (2, 12): 'lake', (3, 12): 'lake_in_ne', (4, 12): 'lake_n', (5, 12): 'lake_ne',
 (0, 13): 'lake', (1, 13): 'lake', (2, 13): 'lake', (3, 13): 'lake', (4, 13): 'lake', (5, 13): 'lake_e',
 (0, 14): 'lake', (1, 14): 'lake', (2, 14): 'lake', (3, 14): 'lake', (4, 14): 'lake', (5, 14): 'lake_e',
}
GMAP = {'G': 'grass', 'g': 'grass_b', 'P': 'path', 'C': 'cobble', 'F': 'flowers', 'f': 'field', 't': 'tall_grass'}
TILES = {}
for (x, y), n in LAKE.items(): TILES[(x, y)] = n
# 家 A（宿）と 家 B（道具屋）
A = [['roof_l', 'chimney', 'roof_m', 'roof_r'], ['eave_l', 'eave_m', 'eave_m', 'eave_r'], ['wall_l', 'sign_inn', 'door', 'wall_r']]
B = [['roof_l', 'roof_m', 'roof_m', 'chimney', 'roof_r'], ['eave_l', 'eave_m', 'eave_m', 'eave_m', 'eave_r'], ['wall_l', 'wall_window', 'door', 'sign_item', 'wall_r']]
for j, row in enumerate(A):
    for i, n in enumerate(row): TILES[(1 + i, 1 + j)] = n
for j, row in enumerate(B):
    for i, n in enumerate(row): TILES[(9 + i, 1 + j)] = n
OBJ = [  # (名前, タイル x, タイル y, 画素のずれ x, y)
 ('spring_dry', 7, 6, -8, 0),
 ('big_tree', 14, 0, 0, -6), ('tree', 0, 3, 0, 0), ('tree', 5, 1, 2, 4), ('tree', 15, 10, 0, 0), ('tree', 12, 13, 4, 0),
 ('tree', 6, 2, 4, 6), ('bush', 10, 10, 0, 0), ('bush', 4, 10, 0, 0), ('rock', 9, 13, 0, 0), ('rock', 4, 6, 4, 2),
 ('barrel', 14, 3, 0, 0), ('crate', 15, 3, 0, 0), ('barrel', 8, 3, 2, 0), ('signpost', 5, 8, 0, 0),
 ('fence_h', 13, 6, 0, 0), ('fence_h', 14, 6, 0, 0), ('fence_h', 15, 6, 0, 0),
 ('fence_v', 12, 7, 4, 0), ('fence_v', 12, 8, 4, 0), ('fence_v', 12, 9, 4, 0), ('fence_v', 12, 10, 4, 0),
]
def render(frame='f0', spring='spring_dry', out='village'):
    b = Board(256, 240)
    for y in range(15):
        for x in range(16):
            n = TILES.get((x, y)) or GMAP[M[y][x]] if not TILES.get((x, y)) else TILES[(x, y)]
            b.put(x * 16, y * 16, fr(n, frame))
    objs = sorted(OBJ, key=lambda o: o[2] * 16 + o[4] + len(fr(o[0])))
    for (n, x, y, dx, dy) in objs:
        if n == 'spring_dry': n = spring
        b.put(x * 16 + dx, y * 16 + dy, fr(n, frame))
    b.save(ROOT + f'/debug/town/{out}.png'); b.save(ROOT + f'/debug/town/{out}_x3.png', 3)
render()
render('f1', 'spring_full', 'village_full')
