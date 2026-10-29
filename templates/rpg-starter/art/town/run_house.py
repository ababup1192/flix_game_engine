import sys; sys.path.insert(0, '.')
from house import *
from ground import grass, path
out = ROOT + '/debug/town'
H = lambda n: HOUSE[n]().rows()
lay = [
 ['grass'] * 10,
 ['grass', 'roof_l', 'chimney', 'roof_m', 'roof_r', 'grass', 'roof_l', 'roof_m', 'roof_r', 'grass'],
 ['grass', 'eave_l', 'eave_m', 'eave_m', 'eave_r', 'grass', 'eave_l', 'eave_m', 'eave_r', 'grass'],
 ['grass', 'wall_l', 'sign_inn', 'door', 'wall_r', 'grass', 'wall_window', 'door', 'sign_item', 'grass'],
 ['grass', 'grass', 'grass', 'path', 'grass', 'grass', 'grass', 'path', 'grass', 'grass'],
]
b = Board(10 * 16, 5 * 16)
for j, row in enumerate(lay):
    for i, n in enumerate(row):
        r = grass().rows() if n == 'grass' else path().rows() if n == 'path' else H(n)
        b.put(i * 16, j * 16, r)
b.save(out + '/house.png'); b.save(out + '/house_x4.png', 4)
