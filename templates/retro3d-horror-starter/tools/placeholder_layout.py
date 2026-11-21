"""仮の校舎の layout.json（assets/school/layout.json）を書く。

校舎の glb と一緒に書き出す layout.json と同じ形・同じ座標の約束で、
1 階の昇降口と教室 1 つ・東の階段・2 階の廊下と教室 1 つだけを置く。
校舎の glb が届くまでの間、ゲームはこの箱を絵としても描く（School.placeholderItems）。

流し方: DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 tools/placeholder_layout.py
"""
import json
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "assets" / "school" / "layout.json"
STOREY = 3.5

layout = {
    "units": "m",
    "axes": {"up": "+Y", "mapping": "Blender X → glTF X, Blender Y → glTF -Z, Blender Z → glTF Y",
             "yaw": "degrees about +Y; 0 faces glTF -Z"},
    "placeholder": True,
    "floors": [], "props": [], "signs": [], "lights": [],
    "spawn": {"pos": [4.5, 0.0, 5.6], "yaw": 0},
}


def box(coll, center, size):
    """Blender の座標の真ん中と大きさの箱を glTF の座標の min / max で足す。"""
    (cx, cy, cz), (sx, sy, sz) = center, size
    coll.append({"min": [round(cx - sx / 2, 3), round(cz - sz / 2, 3), round(-(cy + sy / 2), 3)],
                 "max": [round(cx + sx / 2, 3), round(cz + sz / 2, 3), round(-(cy - sy / 2), 3)]})


def wall_x(coll, x1, x2, y, z, holes):
    """東西に走る壁。holes = (左, 右, 下, 上) の開口。腰板（0〜1 m）と漆喰（1 m〜）を分けた箱にする。"""
    cuts = sorted(set([x1, x2] + [max(x1, min(x2, v)) for h in holes for v in h[:2]]))
    for a, b in zip(cuts, cuts[1:]):
        if b - a < 0.001:
            continue
        intervals = sorted((lo, hi) for l, r, lo, hi in holes if l < (a + b) / 2 < r)
        bottom = 0.0
        for lo, hi in intervals + [(3.0, 3.0)]:
            if lo > bottom:
                for low, high in [(bottom, min(lo, 1.0)), (max(bottom, 1.0), lo)]:
                    if high - low > 0.001:
                        box(coll, ((a + b) / 2, y, z + (low + high) / 2), (b - a, 0.14, high - low))
            bottom = max(bottom, hi)


def prop(name, floor, x, y, z, yaw, coll, size):
    layout["props"].append({"prop": name, "floor": floor, "pos": [x, z, -y], "yaw": yaw})
    a, b, h = size
    if yaw % 180 == 90:
        a, b = b, a
    coll.append({"min": [round(x - a / 2, 3), z, round(-y - b / 2, 3)], "max": [round(x + a / 2, 3), round(z + h, 3), round(-y + b / 2, 3)]})


ROOMS = [[("entrance", "昇降口", 9.0), ("class11", "1年1組", 9.0)],
         [("class21", "2年1組", 9.0), ("storage", "物置", 9.0)]]
SX = 18.0  # 東の階段の西の端

for fi, rooms in enumerate(ROOMS, 1):
    z = (fi - 1) * STOREY
    info = {"index": fi, "y": z, "glb": f"school_floor{fi}.glb", "rooms": [], "colliders": [], "stairs": []}
    layout["floors"].append(info)
    coll = info["colliders"]
    box(coll, (11.0, -2.15, z - 0.1), (22.0, 9.7, 0.2))  # 床（階段の所も含む。上の階は School が階段の所を抜く）
    windows = [(x - 0.5, x + 0.5, 0.9, 2.7) for x in [0.9 + 1.8 * i for i in range(10)]]
    for y in (2.7, -7.0):
        wall_x(coll, 0.0, 18.0, y, z, windows)
        for l, r, lo, hi in windows:
            layout["lights"].append({"type": "moon", "floor": fi, "pos": [(l + r) / 2, z + 1.8, -(y - 0.5 if y > 0 else y + 0.5)]})
    box(coll, (0.0, -2.15, z + 1.5), (0.14, 9.7, 3.0))  # 西の端の壁
    x = 0.0
    for rid, name, width in rooms:
        info["rooms"].append({"id": rid, "name": name, "min": [x, 0.0], "max": [x + width, 7.0]})
        box(coll, (x, -3.5, z + 1.5), (0.14, 7.0, 3.0))
        holes = [] if rid == "storage" else ([(x + 3.0, x + 6.0, 0.0, 2.2)] if rid == "entrance" else [(x + 1, x + 2, 0, 2), (x + width - 2, x + width - 1, 0, 2)])
        wall_x(coll, x, x + width, 0.0, z, holes)
        if rid != "storage":
            layout["signs"].append({"pos": [x + 0.5, z + 2.15, -0.36], "yaw": 90, "text": name})
        if rid.startswith("class"):
            prop("teacher_desk", fi, x + 1.0, -3.5, z, 90, coll, (1.2, 0.65, 0.78))
            for row in range(6):
                for col in range(5):
                    xx = x + 2.1 + row * 1.02
                    yy = -0.75 - col * 1.12
                    prop("desk", fi, xx, yy, z, 90, coll, (0.65, 0.48, 0.73))
                    prop("chair", fi, xx + 0.38, yy, z, 90, coll, (0.42, 0.42, 0.9))
        if rid == "entrance":
            for i in range(3):
                for j in range(2):
                    prop("shoe_locker", fi, x + 2 + i * 2.3, -2.5 - j * 2.2, z, 0, coll, (1.5, 0.4, 1.8))
        x += width
    # 東の階段室（幅 4・奥行き 9.7）。廊下の側は開いている。
    box(coll, (SX, -3.5, z + 1.5), (0.14, 7.0, 3.0))
    box(coll, (SX + 4.0, -2.15, z + 1.5), (0.14, 9.7, 3.0))
    for yy in (-7.0, 2.7):
        box(coll, (SX + 2.0, yy, z + 1.5), (4.0, 0.14, 3.0))
    layout["lights"].append({"type": "exit_green", "floor": fi, "pos": [SX - 0.6, z + 2.7, -1.4]})
    if fi < len(ROOMS):
        info["stairs"].append({"id": f"east{fi}", "from": fi, "to": fi + 1, "ramp": [
            [[SX + 0.15, z, -2.3], [SX + 1.85, z, -2.3], [SX + 1.85, z + 1.75, 5.5], [SX + 0.15, z + 1.75, 5.5]],
            [[SX + 2.15, z + 1.75, 5.5], [SX + 3.85, z + 1.75, 5.5], [SX + 3.85, z + 3.5, -2.3], [SX + 2.15, z + 3.5, -2.3]]]})

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(layout, ensure_ascii=False, indent=1) + "\n", encoding="utf8")
print(f"wrote {OUT}")
