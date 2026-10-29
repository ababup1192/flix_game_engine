"""坑道 B1〜B3 のマップ Doc を作る（座標の設計をここで 1 か所に持ち、JSON は書き出すだけ）。"""
import json, sys
from collections import deque

ROOT = sys.argv[1]

class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.g = [['#'] * w for _ in range(h)]
    def rect(self, x0, y0, x1, y1, ch='.'):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.g[y][x] = ch
    def line(self, x0, y0, x1, y1, ch='.'):
        if x0 == x1:
            for y in range(min(y0, y1), max(y0, y1) + 1): self.g[y][x0] = ch
        else:
            for x in range(min(x0, x1), max(x0, x1) + 1): self.g[y0][x] = ch
    def put(self, x, y, ch): self.g[y][x] = ch
    def at(self, x, y): return self.g[y][x]
    def rows(self): return [''.join(r) for r in self.g]

def chest(i, x, y, item='', count=1, gold=0):
    return {"id": i, "kind": "chest", "x": x, "y": y, "item": item, "count": count, "gold": gold}

def enc(a, b='', c='', w=1):
    return {"foe1": a, "foe2": b, "foe3": c, "weight": w}

def walkable(c, objs_block, x, y, extra=()):
    ch = c.at(x, y)
    return (ch in '.,<>' or (x, y) in extra) and (x, y) not in objs_block

def reach(c, start, block, extra=()):
    seen = {start}; q = deque([start])
    while q:
        x, y = q.popleft()
        for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)):
            n = (x+dx, y+dy)
            if 0 <= n[0] < c.w and 0 <= n[1] < c.h and n not in seen and walkable(c, block, *n, extra=extra):
                seen.add(n); q.append(n)
    return seen

def write(name, doc):
    with open(f"{ROOT}/assets/maps/{name}.map.json", "w") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2); f.write("\n")

# ───────────────────────── B1（32×30）─────────────────────────
b1 = Canvas(32, 30)
b1.rect(2, 22, 8, 28)                 # 入口の部屋
b1.put(3, 28, '<')
b1.line(5, 19, 5, 21)                 # 入口 → 分岐の広間
b1.rect(2, 12, 8, 18)                 # 分岐の広間
b1.rect(12, 2, 18, 5)                 # 北の行き止まり
b1.line(10, 4, 4, 4, '=')             # 帰りのレール（北の行き止まり → 広間）
b1.line(4, 5, 4, 11, '|')
b1.put(11, 4, '=')                    # 帰りのトロッコの駅
b1.line(9, 16, 13, 16, '=')           # 行きのレール（広間の駅 → 分かれ目）
b1.put(14, 16, '=')                   # 分かれ目
b1.line(14, 6, 14, 15, '|')           # 北へ
b1.line(14, 17, 14, 20, '|')          # 南へ
b1.line(15, 20, 24, 20, '=')          # 東へ
b1.rect(25, 9, 27, 21)                # 東の坑道
b1.put(26, 8, '>')
b1.line(26, 22, 26, 28)               # 帰りの近道
b1.line(10, 28, 26, 28)
b1.put(9, 28, '.')                    # 近道の格子のマス
b1.line(9, 24, 11, 24)                # 入口 → 岩の部屋 1
b1.rect(12, 23, 18, 26)               # 岩の部屋 1
b1.put(19, 24, '.')                   # 岩の部屋の格子のマス
b1.rect(20, 23, 22, 25)               # 小部屋
for (x, y) in ((4, 21), (7, 11), (16, 1), (24, 8), (11, 22), (21, 22)): b1.put(x, y, 't')
for (x, y) in ((2, 11), (8, 21), (12, 1), (28, 12), (28, 17)): b1.put(x, y, 'P')
for (x, y) in ((27, 10), (25, 15), (27, 19), (12, 26), (2, 26)): b1.put(x, y, ',')
b1.put(25, 12, 'u'); b1.put(27, 16, 'u'); b1.put(18, 5, 'u')

b1_objects = [
    {"id": "b1_lever", "kind": "lever", "x": 5, "y": 11, "sprite": "lever", "flag": "b1_switch"},
    {"id": "b1_cart", "kind": "cart", "x": 9, "y": 16, "sprite": "minecart", "dir": "right", "node": "Cart"},
    {"id": "b1_junction", "kind": "junction", "x": 14, "y": 16, "sprite": "rail_switch", "flag": "b1_switch", "dir": "up", "dirOn": "down"},
    {"id": "b1_cart_back", "kind": "cart", "x": 11, "y": 4, "sprite": "minecart", "dir": "left", "node": "Cart"},
    chest("b1_pick", 17, 2, "tetsunotsuruhashi"),
    chest("b1_kawa", 2, 12, "kawanoyoroi"),
    {"id": "b1_rock", "kind": "rock", "x": 14, "y": 24, "sprite": "boulder"},
    {"id": "b1_plate", "kind": "plate", "x": 16, "y": 24, "sprite": "plate", "flag": "b1_room", "hold": True},
    {"id": "b1_room_bars", "kind": "gate", "x": 19, "y": 24, "sprite": "gate_bars", "flag": "b1_room", "openWhen": "on"},
    chest("b1_reward", 22, 24, "yakusou", 3, 120),
    {"id": "b1_shortcut_lever", "kind": "lever", "x": 24, "y": 27, "sprite": "lever", "flag": "b1_shortcut"},
    {"id": "b1_shortcut_bars", "kind": "gate", "x": 9, "y": 28, "sprite": "gate_bars", "flag": "b1_shortcut", "openWhen": "on"},
]
b1_props = [{"sprite": s, "frame": "base", "fps": 0, "flat": True, "x": x, "y": 28}
            for (s, x) in (("rail_h", 12), ("rail_h", 13), ("rail_end", 15), ("rail_h", 18), ("rail_h", 19), ("rail_h", 20), ("rail_end", 23))]
write("mine_b1", {
    "version": 1, "title": "坑道 B1",
    "note": "水晶の坑道の 1 階（mine の組・暖色・32×30）。# は岩（真下が床なら正面の絵）・t はたいまつを掛けた壁・P は板の支柱・= | はレール（歩けない。曲がり角の絵は隣のレールから選ぶ）・u はがれき（入れない）・, は水晶のかけらの床・< は上り階段（ワールドマップへ）・> は下り階段（B2 へ）。"
            "仕掛けは 2 つ: 分岐の広間のトロッコ（b1_cart）と分かれ目（b1_junction）— 壁のレバー b1_lever の旗 b1_switch が下りていれば北の行き止まり（てつのつるはし・帰りのトロッコ）へ、立っていれば東の坑道（下り階段）へ走る。"
            "岩の部屋 1（岩 1・床 1。押すと格子が上がり、小部屋に やくそう×3 と 120G）。東の坑道の南の細道の奥のレバー b1_shortcut_lever で入口の格子が上がる（帰りの近道）。",
    "tileset": "mine", "battleBack": "bg_cave", "minSteps": 30, "maxSteps": 44,
    "rows": b1.rows(),
    "exits": [
        {"id": "to_world", "x": 3, "y": 28, "to": "world", "spawnX": 20, "spawnY": 4, "facing": "down"},
        {"id": "to_b2", "x": 26, "y": 8, "to": "mine_b2", "spawnX": 3, "spawnY": 2, "facing": "right"},
    ],
    "npcs": [{"id": "boljii", "sprite": "old_miner", "x": 6, "y": 23, "facing": "down", "node": "Boljii"}],
    "props": b1_props, "objects": b1_objects, "events": [],
    "encounter": [enc("koke", "koke", w=2), enc("koumori", "koke", w=2), enc("horimogu", w=1), enc("koumori", "koke", "koke", w=1)],
})

# ───────────────────────── B2（48×30・暗い）─────────────────────────
b2 = Canvas(48, 30)
b2.rect(1, 1, 6, 5)                   # 入口の小部屋（コロンの店）
b2.put(2, 1, '<')                     # B1 へ
main = [((7, 3), (14, 3)), ((14, 3), (14, 9)), ((14, 9), (24, 9)), ((24, 9), (24, 15)), ((24, 15), (34, 15)),
        ((34, 15), (34, 5)), ((34, 5), (42, 5)), ((42, 5), (42, 22)), ((42, 22), (44, 22))]
for (a, b) in main: b2.line(a[0], a[1], b[0], b[1])
b2.rect(43, 22, 46, 27)               # 下り階段の部屋
b2.put(45, 27, '>')
branches = [((14, 6), (9, 6)), ((9, 6), (9, 14)),            # かぎ
            ((19, 9), (19, 13)),                             # 落とし穴 1
            ((29, 15), (29, 21)), ((29, 21), (20, 21)),      # まほうのローブ
            ((24, 21), (24, 25)),                            # 落とし穴 2
            ((34, 10), (39, 10)),                            # まりょくのみ
            ((42, 18), (36, 18)), ((36, 18), (36, 26)), ((36, 26), (30, 26)),   # くろがねゴブリン → はがねのつるぎ
            ((38, 5), (38, 2))]                              # 落とし穴 3
for (a, b) in branches: b2.line(a[0], a[1], b[0], b[1])
for (x, y) in ((3, 0), (12, 2), (26, 8), (40, 4), (44, 21)): b2.put(x, y, 't')
for (x, y) in ((17, 9), (27, 15), (42, 12), (33, 26), (9, 10)): b2.put(x, y, ',')
pits = [(19, 13), (24, 25), (38, 2)]
b2_objects = [
    chest("b2_torch", 1, 5, "taimatsu", 3),
    chest("b2_kagi", 9, 14, "furubitakagi"),
    chest("b2_robe", 20, 21, "mahounorobe"),
    chest("b2_maryoku", 39, 10, "maryoku", 2),
    {"id": "b2_kurogane", "kind": "guard", "x": 31, "y": 26, "sprite": "goblin_guard", "node": "Kurogane"},
    chest("b2_sword", 30, 26, "haganenotsurugi"),
]
write("mine_b2", {
    "version": 1, "title": "坑道 B2",
    "note": "水晶の坑道の 2 階（mine の組・48×30・暗い）。dark = 先頭のまわりしか見えない（たいまつを使うと広がる。rules の darkRadius / torchRadius・items の lightSteps）。"
            "入口の小部屋に行商人コロン（<<shop mine>>）と たいまつ×3 の宝箱。暗い迷路の行き止まりに ふるびたかぎ・まほうのローブ・まりょくのみ×2、一番奥で くろがねゴブリン（guard）が はがねのつるぎ の宝箱の前に立つ。"
            "割れた床（floor_crack の小物）の 3 マスは落とし穴（exits。B3 の西の小部屋へ落ちる。寄り道で近道ではない）。< は B1 へ・> は B3 へ。",
    "tileset": "mine", "battleBack": "bg_cave", "dark": True, "minSteps": 30, "maxSteps": 44,
    "rows": b2.rows(),
    "exits": [
        {"id": "to_b1", "x": 2, "y": 1, "to": "mine_b1", "spawnX": 26, "spawnY": 9, "facing": "down"},
        {"id": "to_b3", "x": 45, "y": 27, "to": "mine_b3", "spawnX": 16, "spawnY": 27, "facing": "up"},
    ] + [{"id": f"pit{i + 1}", "x": x, "y": y, "to": "mine_b3", "spawnX": 3, "spawnY": 3, "facing": "down"} for i, (x, y) in enumerate(pits)],
    "npcs": [{"id": "koron", "sprite": "merchant", "x": 5, "y": 2, "facing": "left", "node": "Koron"}],
    "props": [{"sprite": "floor_crack", "frame": "base", "fps": 0, "flat": True, "x": x, "y": y} for (x, y) in pits],
    "objects": b2_objects, "events": [],
    "encounter": [enc("koumori", "horimogu", w=2), enc("fukane", "fukane", w=2), enc("goblin", "koumori", w=2), enc("hinoko", "hinoko", w=1), enc("horimogu", "fukane", "koumori", w=1)],
})

# ───────────────────────── B3（32×30）─────────────────────────
b3 = Canvas(32, 30)
b3.rect(12, 24, 20, 28)               # 上り階段の部屋
b3.put(16, 28, '<')
b3.line(16, 22, 16, 23)
b3.rect(6, 8, 25, 20, '~')            # 地底湖
b3.line(5, 9, 5, 21); b3.line(26, 9, 26, 21); b3.line(5, 21, 26, 21)   # 岸（南・西・東）
b3.put(5, 8, '.')                     # 北の水晶の窪み（西の岸の上の端）
b3.put(27, 14, '.'); b3.put(4, 14, '.')   # 東・西の水晶の窪み
b3.rect(14, 14, 18, 17)               # 小島
b3.rect(14, 6, 18, 7)                 # 北の岸（飛び石でだけ着く）
b3.put(16, 5, '.')                    # 封じられた扉のマス
b3.rect(12, 1, 20, 4)                 # ボスの間（P7）
b3.line(21, 26, 21, 26)               # 階段の部屋 → 岩の部屋 2
b3.rect(22, 24, 27, 28)               # 岩の部屋 2
b3.put(28, 26, '.')                   # 格子のマス
b3.rect(29, 24, 30, 28)               # 宝の部屋
b3.rect(1, 1, 4, 4)                   # 西の小部屋（落とし穴の先）
b3.put(1, 1, '<')
for (x, y) in ((4, 10), (27, 10), (4, 19), (27, 19)): b3.put(x, y, 'x')
stones = [(16, 20), (16, 19), (16, 18), (16, 13), (16, 12), (16, 11), (16, 10), (16, 9), (16, 8)]
stone_sprites = ["stepping_stone", "stepping_stone_b", "stepping_stone_c"]
b3_objects = [
    {"id": "b3_crystal_e", "kind": "crystal", "x": 27, "y": 14, "sprite": "crystal_l", "flag": "b3_crystals", "order": 1},
    {"id": "b3_crystal_w", "kind": "crystal", "x": 4, "y": 14, "sprite": "crystal_l", "flag": "b3_crystals", "order": 2},
    {"id": "b3_crystal_n", "kind": "crystal", "x": 5, "y": 8, "sprite": "crystal_l", "flag": "b3_crystals", "order": 3},
] + [{"id": f"b3_stone{i + 1}", "kind": "bridge", "x": x, "y": y, "sprite": stone_sprites[i % 3], "flag": "b3_crystals"} for i, (x, y) in enumerate(stones)] + [
    chest("b3_robe", 14, 14, "mizunohagoromo"),
    {"id": "b3_door", "kind": "door", "x": 16, "y": 5, "key": "furubitakagi"},
    {"id": "b3_tablet", "kind": "sign", "x": 18, "y": 24, "sprite": "tablet_l", "node": "Tablet"},
    {"id": "b3_rock_a", "kind": "rock", "x": 23, "y": 26, "sprite": "boulder_deep"},
    {"id": "b3_rock_b", "kind": "rock", "x": 24, "y": 25, "sprite": "boulder_deep"},
    {"id": "b3_plate_n", "kind": "plate", "x": 26, "y": 25, "sprite": "plate_deep", "flag": "b3_room", "hold": True},
    {"id": "b3_plate_s", "kind": "plate", "x": 26, "y": 27, "sprite": "plate_deep", "flag": "b3_room", "hold": True},
    {"id": "b3_room_bars", "kind": "gate", "x": 28, "y": 26, "sprite": "gate_bars", "flag": "b3_room", "openWhen": "on"},
    chest("b3_bomb", 30, 25, "bakudanishi", 3),
    {"id": "b3_mimic", "kind": "guard", "x": 30, "y": 27, "sprite": "chest", "node": "Mimic"},
    chest("b3_seisui", 4, 1, "seisui", 2),
]
b3_props = [{"sprite": "crystal_pillar", "frame": "base", "fps": 0, "flat": False, "x": x, "y": y - 1} for (x, y) in ((4, 10), (27, 19))] + \
           [{"sprite": "crystal_l", "frame": "f0", "fps": 1, "flat": False, "x": x, "y": y - 1} for (x, y) in ((27, 10), (4, 19))]
write("mine_b3", {
    "version": 1, "title": "坑道 B3",
    "note": "水晶の坑道の 3 階（mine_deep の組・寒色・32×30）。~ は地底湖（入れない）・x は水晶の柱と大きな水晶の下の床（入れない）・< は B2 へ。"
            "湖の岸の水晶 3 つ（crystal。order の順 = 東・西・北）を点けると旗 b3_crystals が立ち、飛び石（bridge）が現れて小島（みずのはごろも）と北の岸へ渡れる。北の岸の封じられた扉（door。ふるびたかぎ）の奥がボスの間。"
            "上り階段の部屋にミナの父（話すと全快・水晶の順番の手がかり）と石碑（sign）。東の岩の部屋 2（岩 2・床 2。押す順を違えると角に詰まる。階段を出入りすると岩は元へ戻る）の格子の奥に宝箱 2 つ（片方は ひとくいばこ = guard）。"
            "北西の小部屋は B2 の落とし穴の先（せいすい×2・上り階段で B2 の入口へ戻る。湖へは出られない）。",
    "tileset": "mine_deep", "battleBack": "bg_lake", "minSteps": 30, "maxSteps": 44,
    "rows": b3.rows(),
    "exits": [
        {"id": "to_b2", "x": 16, "y": 28, "to": "mine_b2", "spawnX": 44, "spawnY": 27, "facing": "up"},
        {"id": "to_b2_west", "x": 1, "y": 1, "to": "mine_b2", "spawnX": 3, "spawnY": 4, "facing": "down"},
    ],
    "npcs": [{"id": "mina_father", "sprite": "mina_father", "x": 13, "y": 25, "facing": "right", "node": "MinaFather"}],
    "props": b3_props, "objects": b3_objects, "events": [],
    "encounter": [enc("shouyado", "goblin", w=2), enc("akabou", "koriyado", w=2), enc("koriyado", "shouyado", w=1), enc("akabou", "goblin", w=1)],
})

# ── 確かめ（歩きで着けるか。塞ぐ物は宝箱・人・閉じた格子など） ──
def check(name, c, start, block, must, mustnot, extra=()):
    seen = reach(c, start, block, extra)
    for p in must:
        ok = any((p[0]+dx, p[1]+dy) in seen for dx, dy in ((0,0),(1,0),(-1,0),(0,1),(0,-1)))
        if not ok: print(f"[{name}] 着けない: {p}")
    for p in mustnot:
        if p in seen: print(f"[{name}] 着けてはいけない所に着く: {p}")
    print(f"[{name}] 歩けるマス {len(seen)}")

b1_block = {(o['x'], o['y']) for o in b1_objects if o['kind'] in ('chest', 'cart', 'lever', 'gate', 'rock')} | {(6, 23)}
check("B1 入口", b1, (3, 27), b1_block, [(6, 23), (14, 24), (2, 12), (5, 11), (9, 16)], [(17, 3), (26, 9), (21, 24)])
check("B1 北", b1, (14, 5), b1_block, [(17, 2), (11, 4)], [(5, 13)])
check("B1 東", b1, (25, 20), b1_block, [(26, 8), (24, 27), (9, 28)], [(5, 13)])
b2_block = {(o['x'], o['y']) for o in b2_objects} | {(5, 2)}
check("B2", b2, (3, 2), b2_block, [(45, 27), (9, 14), (20, 21), (39, 10), (31, 26)] + pits, [])
b3_block = {(o['x'], o['y']) for o in b3_objects if o['kind'] not in ('bridge', 'plate')} | {(13, 25)}
check("B3 階段", b3, (16, 27), b3_block, [(27, 14), (4, 14), (5, 8), (18, 24), (23, 26)], [(16, 6), (14, 14), (3, 3), (30, 25)])
check("B3 飛び石", b3, (16, 21), b3_block, [(14, 14), (16, 5)], [], extra=set(stones))
check("B3 西", b3, (3, 3), b3_block, [(4, 1), (1, 1)], [(16, 27)])
for name, c in (("B1", b1), ("B2", b2), ("B3", b3)):
    print(name); print("\n".join(c.rows()))
