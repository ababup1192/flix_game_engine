import sys; sys.path.insert(0, '.')
from lake import *
from ground import grass
out = ROOT + '/debug/town'
L = lambda n, f=0: lake_frames(n)[f'f{f}']
G = 'grass'
lay = [
 [G, G, G, G, G, G, G, G],
 [G, 'nw', 'n', 'n', 'ne', G, G, G],
 [G, 'w', '', '', 'e', G, G, G],
 [G, 'w', '', '', 'in_ne', 'n', 'ne', G],
 [G, 'w', '', '', '', '', 'e', G],
 [G, 'w', '', 'in_se', 's', 's', 'se', G],
 [G, 'sw', 's', 'se', G, G, G, G],
 [G, G, G, G, G, G, G, G],
]
for f in (0, 1):
    b = Board(8 * 16, 8 * 16)
    for j, row in enumerate(lay):
        for i, n in enumerate(row):
            b.put(i * 16, j * 16, grass().rows() if n == 'grass' else L(n, f))
    b.save(out + f'/lake_f{f}.png'); b.save(out + f'/lake_f{f}_x4.png', 4)
