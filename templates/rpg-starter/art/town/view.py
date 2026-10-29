import sys
sys.path.insert(0, '.')
from pxlib import *
import importlib
def tile3(rows, name, out):
    h = len(rows); w = len(rows[0])
    b = Board(w * 3, h * 3)
    for j in range(3):
        for i in range(3): b.put(i * w, j * h, rows)
    b.save(out + f'/{name}_3x3.png', 1); b.save(out + f'/{name}_3x3_x4.png', 4)
