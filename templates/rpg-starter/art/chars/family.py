#!/usr/bin/env python3
# ミナ・父・祖父（smith）を並べた見比べ（実寸と 6 倍）を debug/chars/family.png に描く。
import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
g = {}
exec(open(os.path.join(HERE, "gen_chars.py")).read().split("if __name__")[0], g)
pal = g["load_palette"]()
d = json.load(open(g["OUT"]))
who = ["smith", "mina_father", "mina"]
dirs = ["down_0", "left_0", "right_1", "up_0"]
grass = pal["fc1A"]
# 上段: 実寸で 3 人を横に並べた 4 向き / 下段: 同じ物を 6 倍
w1 = len(dirs) * (len(who) * 16 + 6)
h1 = 20
cells = [[grass] * w1 for _ in range(h1)]
for j, fn in enumerate(dirs):
    for i, n in enumerate(who):
        fr = d["sprites"][n]["frames"][fn]
        ox = j * (len(who) * 16 + 6) + i * 16
        for y in range(16):
            for x in range(16):
                ch = fr[y][x]
                if ch != ".":
                    cells[2 + y][ox + x] = pal[d["legend"][ch]]
S = 6
W = w1 * S
H = h1 + 4 + h1 * S
out = [[(40, 40, 48)] * W for _ in range(H)]
for y in range(h1):
    for x in range(w1):
        out[y][x] = cells[y][x]
for y in range(h1 * S):
    for x in range(W):
        out[h1 + 4 + y][x] = cells[y // S][x // S]
g["render"](out, W, H, 1, g["DBG"] + "/family.png")
