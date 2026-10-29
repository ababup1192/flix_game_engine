import sys; sys.path.insert(0, '.')
from props import *
from ground import grass, path
out = ROOT + '/debug/town'
items = [(n, PROPS[n]()) for n in PROPS] + [(f'forge{f}', forge(f)) for f in range(3)]
W = sum(max(16, c.w) + 4 for _, c in items) + 4
b = Board(W, 40)
for j in range(3):
    for i in range(W // 16 + 1): b.put(i * 16, j * 16, grass().rows())
x = 4
for n, c in items:
    b.put(x, 36 - c.h, c.rows()); x += max(16, c.w) + 4
b.save(out + '/props.png'); b.save(out + '/props_x4.png', 4)
