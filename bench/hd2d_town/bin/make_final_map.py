#!/usr/bin/env python3
# 最終動画の地図の写し assets/town_final.map.json を作る（Blender の地図は触らない）。
#   行 0〜25: 北の新しい部分（北の門と北の大通り）・行 26〜51: hd2d_lab の town_avenue.map.json（f730800）をそのまま・行 52〜63: 南の大通り。
# usage: python3 bin/make_final_map.py <hd2d_lab の town_avenue.map.json>（git show f730800:art/hd2d_gen/town_avenue.map.json の写し）
import json, sys, os

os.chdir(os.path.join(os.path.dirname(__file__), '..'))
lab = json.load(open(sys.argv[1]))
W = 27
NORTH = 26
AVENUE_GROUND = 'ggggggggggwgcccgwgggggggggg'


def row(cells):
    r = ['.'] * W
    for c, ch in cells.items():
        r[c] = ch
    return ''.join(r)


# 1. 北の新しい部分（行 0〜25）
north_ground, north_objects = [], []
for r in range(NORTH):
    if r <= 3:
        north_ground.append('g' * 10 + 'c' * 7 + 'g' * 10)  # 門の前の石畳（列 10〜16）
        north_objects.append(row({10: 'L', 16: 'L'} if r == 3 else {}))
        continue
    north_ground.append(AVENUE_GROUND)
    # WhyNot: 北の大通りの街灯を植え込みの帯（列 11・15）に立てない — 追従カメラの手前で柱がパーティの上に重なって隠した。水路の外（列 9・17）に立てる
    cells = {11: 'h', 15: 'h', 9: 'L', 17: 'L'} if r % 3 == 2 else {11: 'h', 15: 'h'}
    if r == 9:
        cells.update({c: 'H' for c in range(1, 10)})
    if r in (12, 22):
        cells.update({6 if r == 12 else 4: 'T'})
    if r in (8, 21):
        cells.update({20 if r == 8 else 21: 'T'})
    if 18 <= r <= 21:
        cells.update({18: 'X', 19: 'f'})
    north_objects.append(row(cells))
north_buildings = [
    {"id": "gate_left", "x": 4, "y": 0, "w": 6, "h": 3, "level": 1, "floors": 2, "wall": "stone",
     "roof": {"kind": "gable", "ridge": "x", "pitchDeg": 40, "overhang": 0.4}},
    {"id": "gate_right", "x": 17, "y": 0, "w": 6, "h": 3, "level": 1, "floors": 2, "wall": "stone",
     "roof": {"kind": "gable", "ridge": "x", "pitchDeg": 40, "overhang": 0.4}},
    {"id": "north_left", "x": 1, "y": 4, "w": 7, "h": 4, "level": 1, "floors": 1, "wall": "plaster",
     "roof": {"kind": "gable", "ridge": "x", "pitchDeg": 40, "overhang": 0.4}},
    {"id": "north_right", "x": 21, "y": 11, "w": 5, "h": 5, "level": 1, "floors": 2, "wall": "stone",
     "roof": {"kind": "gable", "ridge": "x", "pitchDeg": 40, "overhang": 0.4}},
    {"id": "north_left2", "x": 1, "y": 14, "w": 6, "h": 4, "level": 1, "floors": 1, "wall": "plaster",
     "roof": {"kind": "gable", "ridge": "x", "pitchDeg": 38, "overhang": 0.5}},
]

# 2. hd2d_lab の地図（行 26〜51）。夜の街灯の差分（nightlamps）を入れ、池の東を回る道のために (15,4) を (16,4) へ動かす。
lab_objects = [list(r) for r in lab['objects']]
for c0, r0, c1, r1, ch in lab['variants']['nightlamps']['objects']:
    lab_objects[r0][c0] = ch
lab_objects[4][15] = '.'
lab_objects[4][16] = 'L'
# 広場の 2 本（元の (10,21)・(16,21)）は屋台の行商人と風船の子のすぐ前に立って隠すので、大通りの帯の列（11・15）へ寄せる。
lab_objects[21][10] = '.'
lab_objects[21][11] = 'L'
lab_objects[21][16] = '.'
lab_objects[21][15] = 'L'
lab_objects = [''.join(r) for r in lab_objects]
lab_buildings = [dict(b, y=b['y'] + NORTH) for b in lab['buildings']]

# 3. 南の大通り（行 52〜63・南へ広げた写しの行 20〜31 と同じ作り）
south = json.load(open('assets/town_avenue_south.map.json'))
south_ground = south['ground'][20:32]
south_objects = south['objects'][20:32]

ground = north_ground + lab['ground'] + south_ground
objects = north_objects + lab_objects + south_objects
H = len(ground)
assert H == 64 and all(len(r) == W for r in ground + objects), (H,)

d = dict(south)
d.update({
    "version": 1,
    "title": "最終動画の町（北の門・北の大通り・十字の広場・南の大通り）",
    "note": "最終動画の地図の写し（bench だけ・bin/make_final_map.py が作る・hd2d_lab の地図は触らない）。"
            "行 0〜25 は北の新しい部分（行 0〜3 が北の門・行 4〜25 が北の大通り）、行 26〜51 は hd2d_lab f730800 の town_avenue.map.json をそのまま（夜の街灯の差分を入れ、(15,30) の街灯を (16,30) へ、広場の (10,47)・(16,47) を (11,47)・(15,47) へ動かした）、行 52〜63 は南の大通り。",
    "ground": ground, "objects": objects, "height": ['1' * W] * H, "shape": ['.' * W] * H,
    "buildings": north_buildings + lab_buildings,
    "camera": dict(lab['camera'], target=[lab['camera']['target'][0], lab['camera']['target'][1] + NORTH],
                   frame=dict(lab['camera']['frame'], anchor=[lab['camera']['frame']['anchor'][0], lab['camera']['frame']['anchor'][1] + NORTH])),
    "walk": dict(lab['walk'], fromRow=lab['walk']['fromRow'] + NORTH, toRow=lab['walk']['toRow'] + NORTH),
})
# 広場のにぎやかし（park の案）。行を 26 ずらす。
props = []
for p in lab['props']:
    if p.get('variant', 'park') != 'park':
        continue
    q = dict(p)
    c, r = q['at']
    q['at'] = [c, r + NORTH]
    props.append(q)
d['props'] = props
for k in list(d):
    if k.startswith('walk_'):
        del d[k]
json.dump(d, open('assets/town_final.map.json', 'w'), ensure_ascii=False, indent=2)
open('assets/town_final.map.json', 'a').write('\n')
print(f'assets/town_final.map.json（{W}×{H}・建物 {len(d["buildings"])}・広場のにぎやかし {len(props)}・街灯 {sum(r.count("L") for r in objects)}）')
