import json, os

here = os.path.dirname(os.path.abspath(__file__))
lines = [l for l in open(os.path.join(here, "b_tiles.txt")).read().split("\n") if l]
tiles, cur = {}, None
for l in lines:
    if l.isalpha() and l.islower() and len(l) < 16:
        cur = l
        tiles[cur] = []
    else:
        tiles[cur].append(l)
for n, rows in tiles.items():
    assert len(rows) == 16, (n, len(rows))
    for i, r in enumerate(rows):
        assert len(r) == 16, (n, i, r)

legend = {
    "g": "grass0", "G": "grass1", "k": "grass2", "K": "grass3",
    "l": "dirt0", "d": "dirt1", "x": "dirt2",
    "L": "stone0", "R": "stone1", "r": "stone2", "m": "stone3",
    "a": "water0", "w": "water1", "W": "water2", "D": "water3",
}
doc = {
    "version": 1,
    "title": "地面タイル（真上から）",
    "note": "16×16・上下左右で回る。光は左上。",
    "paletteFile": "assets/palette.json",
    "legend": legend,
    "sprites": {n: {"kind": "tile", "frames": {"f0": rows}} for n, rows in tiles.items()},
}
json.dump(doc, open(os.path.join(here, "..", "assets", "b_tiles.sprite.json"), "w"), indent=2, ensure_ascii=False)
print("ok")
