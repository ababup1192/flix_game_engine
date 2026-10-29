import sys; sys.path.insert(0, '.')
from pxlib import *
from ground import grass
def show(items, out, scale=8, bgfn=grass, cols=None):
    W = sum(c.w + 4 for c in items) + 4
    H = max(c.h for c in items) + 8
    b = Board(W, H)
    for j in range(H // 16 + 1):
        for i in range(W // 16 + 1): b.put(i * 16, j * 16, bgfn().rows())
    x = 4
    for c in items: b.put(x, 4, c.rows()); x += c.w + 4
    b.save(out, scale)
