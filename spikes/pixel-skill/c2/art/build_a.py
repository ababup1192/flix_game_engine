import json, os, sys

here = os.path.dirname(os.path.abspath(__file__))
f0 = [l for l in open(os.path.join(here, "a_f0.txt")).read().split("\n") if l]
assert len(f0) == 32, len(f0)
for i, r in enumerate(f0):
    assert len(r) == 32, (i, len(r), r)

def lift(rows, top, bottom, x0, x1):
    """rows[top..bottom] の x0..x1 の列を 1 行上へ。bottom 行には 1 つ下の行の同じ列を入れる。"""
    out = [list(r) for r in rows]
    for y in range(top, bottom + 1):
        src = rows[y + 1] if y + 1 < len(rows) else "." * 32
        for x in range(x0, x1 + 1):
            out[y][x] = src[x]
    return ["".join(r) for r in out]

# 胴（頭と肩）は 0〜13 行を持ち上げる。腕とランプは 1 コマ遅れて、形を変えずに 1 行上がる。
# 肩（14 行の 5・6 列）と胴の輪郭（7 列）は残すので、列ごとに持ち上げる範囲が違う。
def arm_up(rows):
    rows = lift(rows, 14, 26, 0, 4)
    rows = lift(rows, 15, 26, 5, 5)
    return lift(rows, 15, 19, 6, 6)

torso_up = lift(f0, 0, 13, 6, 24)
f1 = torso_up
f2 = arm_up(torso_up)
f3 = arm_up(f0)

legend = {
    "O": "ink0",
    "Y": "coat0", "C": "coat1", "c": "coat2", "D": "coat3",
    "S": "skin0", "s": "skin1",
    "H": "hair0", "h": "hair1",
    "B": "boot0", "b": "boot1",
}
doc = {
    "version": 1,
    "title": "灯台守の見習い",
    "note": "32×32・正面寄りの 3/4（顔は画面の左へ向く）。光は左上。ランプは画面の左の手に提げる。",
    "paletteFile": "assets/palette.json",
    "legend": legend,
    "sprites": {
        "idle": {
            "kind": "character",
            "anchor": {"x": 15.0, "y": 30.0},
            "delaysMs": [420, 160, 420, 160],
            "frames": {"f0": f0, "f1": f1, "f2": f2, "f3": f3},
        }
    },
}
out = os.path.join(here, "..", "assets", "a_char.sprite.json")
json.dump(doc, open(out, "w"), indent=2, ensure_ascii=False)
print("ok")
