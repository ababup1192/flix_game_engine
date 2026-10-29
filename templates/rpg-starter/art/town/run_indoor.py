import sys; sys.path.insert(0, '.')
from indoor import *
out = ROOT + '/debug/town'
R = lambda f: f().rows()
W, H = 12, 9
b = Board(W * 16, H * 16)
for j in range(H):
    for i in range(W):
        b.put(i * 16, j * 16, R(wall_top) if j == 0 or i == 0 or i == W - 1 else R(wall_in) if j == 1 else R(floor_wood))
b.put(3 * 16, 16, R(window_in)); b.put(8 * 16, 16, R(window_in))
b.put(5 * 16, 0, fireplace(0).rows())
b.put(1 * 16, 16, bookshelf().rows())
b.put(4 * 16, 4 * 16, rug().rows())
b.put(6 * 16 + 8, 5 * 16, table().rows())
b.put(6 * 16, 5 * 16, chair().rows())
b.put(9 * 16, 2 * 16 + 4, bed().rows())
b.put(1 * 16, 7 * 16, pot().rows()); b.put(2 * 16, 7 * 16, pot().rows())
b.save(out + '/indoor.png'); b.save(out + '/indoor_x4.png', 4)
b2 = Board(3 * 34 + 4, 36)
for f in range(3): b2.put(2 + f * 34, 2, fireplace(f).rows())
b2.save(out + '/fireplace_x6.png', 6)
