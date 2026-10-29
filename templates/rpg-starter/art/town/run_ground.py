import sys; sys.path.insert(0, '.')
from ground import *
from view import tile3
out = ROOT + '/debug/town'
names = list(GROUND)
b = Board(len(names) * 52, 52)
for i, n in enumerate(names):
    r = GROUND[n]().rows()
    for j in range(3):
        for k in range(3): b.put(i * 52 + k * 16, j * 16, r)
b.save(out + '/ground_sheet.png', 1); b.save(out + '/ground_sheet_x4.png', 4)
