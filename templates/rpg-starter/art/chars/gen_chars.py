#!/usr/bin/env python3
# rpg.chars.sprite.json を部品の重ね合わせで組む。
# 部品の文字: K=ink  A=主色  S=明るい色（肌など）  L=脚の色（K か A か S に読み替え）  '.'=何も置かない  ','=透明で消す
import json, sys, zlib, struct, os

ROOT = "/Users/abab/Desktop/flix_game_engine/templates/rpg-starter"
OUT = ROOT + "/assets/rpg.chars.sprite.json"
DBG = ROOT + "/debug/chars"

W = H = 16

def blank():
    return [["."] * W for _ in range(H)]

def put(cv, part, x=0, y=0):
    for j, row in enumerate(part):
        for i, ch in enumerate(row):
            if ch == ".":
                continue
            yy, xx = y + j, x + i
            if 0 <= yy < H and 0 <= xx < W:
                cv[yy][xx] = "." if ch == "," else ch

def mirror(rows):
    return ["".join(reversed(r)) for r in rows]

def rows(cv):
    return ["".join(r) for r in cv]

def check(name, part, w=None):
    for r in part:
        if w is not None and len(r) != w:
            raise SystemExit(f"{name}: 幅 {len(r)} != {w}: {r!r}")

#PARTS
# ---------------------------------------------------------------- 書き出し
def load_palette():
    d = json.load(open(ROOT + "/assets/rpg.palette.json"))
    return {k: tuple(round(c * 255) for c in v["rgb"]) for k, v in d.items() if isinstance(v, dict)}

def main():
    names = [n for n in ["hero", "mina", "toto", "chief", "woman", "child", "smith", "merchant", "mina_father", "old_miner", "goblin_guard"] if n in CH]
    letters = iter("BCDEFGHIJMNOPQRTUVWXYZabcdefghijlmnopqrstuvwxyz0123456789")
    legend = {"K": "ink"}
    keymap = {"ink": "K"}
    sprites = {}
    for n in names:
        c = CH[n]
        fr = frames_for(c)
        local = {"K": "K"}
        for ph, key in c["colors"].items():
            if key not in keymap:
                ch = next(letters)
                keymap[key] = ch
                legend[ch] = key
            local[ph] = keymap[key]
        conv = {}
        for k, rs in fr.items():
            for r in rs:
                assert len(r) == 16, (n, k, r)
            conv[k] = ["".join(local.get(ch, ch) for ch in r) for r in rs]
        sprites[n] = {
            "kind": "character",
            "note": c.get("note", ""),
            "anchor": {"x": 8.0, "y": 15.0},
            "frames": conv,
        }
    doc = {
        "version": 1,
        "title": "人の歩き（仲間と村人）",
        "note": "16×16・1 人 = 墨 + 2 色 + 透明（FC のスプライト 1 枚分）。光は左上。歩きは 2 コマの足踏み、right_* は left_* の左右反転。anchor は足元の中央。",
        "paletteFile": "assets/rpg.palette.json",
        "legend": dict(sorted(legend.items())),
        "sprites": sprites,
    }
    with open(OUT, "w") as fp:
        json.dump(doc, fp, ensure_ascii=False, indent=2)
    pal = load_palette()
    os.makedirs(DBG, exist_ok=True)
    sheet(doc, pal)

# ---------------------------------------------------------------- PNG
def write_png(path, w, h, px):
    raw = b"".join(b"\x00" + bytes(px[y * w * 3:(y + 1) * w * 3]) for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)

def render(cells, w, h, scale, path):
    px = bytearray(w * scale * h * scale * 3)
    W2 = w * scale
    for y in range(h):
        for x in range(w):
            col = cells[y][x]
            for dy in range(scale):
                base = ((y * scale + dy) * W2 + x * scale) * 3
                for dx in range(scale):
                    px[base + dx * 3:base + dx * 3 + 3] = bytes(col)
    write_png(path, W2, h * scale, px)

def sheet(doc, pal):
    leg = doc["legend"]
    order = ["down_0", "down_1", "up_0", "up_1", "left_0", "left_1", "right_0", "right_1"]
    sp = doc["sprites"]
    gap = 2
    bgs = [pal["fc1A"], pal["fc18"], pal["fc2D"]]
    w = len(order) * (16 + gap) + gap
    h = len(sp) * len(bgs) * (16 + gap) + gap
    cells = [[(40, 40, 48)] * w for _ in range(h)]
    yy = gap
    for name, s in sp.items():
        for bg in bgs:
            for i, fn in enumerate(order):
                x0 = gap + i * (16 + gap)
                fr = s["frames"].get(fn)
                for y in range(16):
                    for x in range(16):
                        ch = fr[y][x] if fr else "."
                        cells[yy + y][x0 + x] = pal[leg[ch]] if ch != "." else bg
            yy += 16 + gap
    render(cells, w, h, 1, DBG + "/sheet.png")
    render(cells, w, h, 4, DBG + "/sheet@4x.png")
    bgs = [pal["fc1A"]]
    h = len(sp) * (16 + gap) + gap
    cells = [[(40, 40, 48)] * w for _ in range(h)]
    yy = gap
    for name, s in sp.items():
        for i, fn in enumerate(order):
            x0 = gap + i * (16 + gap)
            fr = s["frames"].get(fn)
            for y in range(16):
                for x in range(16):
                    ch = fr[y][x] if fr else "."
                    cells[yy + y][x0 + x] = pal[leg[ch]] if ch != "." else bgs[0]
        yy += 16 + gap
    render(cells, w, h, 6, DBG + "/grass@6x.png")
    # 隊列（草の上）: 縦に hero / mina / toto、横に並ぶ
    party = [n for n in ("hero", "mina", "toto") if n in sp]
    W3, H3 = 96, 64
    g = [[pal["fc1A"]] * W3 for _ in range(H3)]
    # 草の粒
    for y in range(H3):
        for x in range(W3):
            if (x * 7 + y * 13) % 23 == 0:
                g[y][x] = pal["fc2A"]
            elif (x * 5 + y * 11) % 29 == 0:
                g[y][x] = pal["fc0A"]
    def stamp(fr, ox, oy):
        for y in range(16):
            for x in range(16):
                ch = fr[y][x]
                if ch != ".":
                    g[oy + y][ox + x] = pal[leg[ch]]
    for i, n in enumerate(party):  # 縦隊（上向きに歩く: 先頭が上）
        stamp(sp[n]["frames"]["up_0" if i % 2 == 0 else "up_1"], 8, 2 + i * 16)
    for i, n in enumerate(party):  # 縦隊（下向き）
        stamp(sp[n]["frames"]["down_0" if i % 2 == 0 else "down_1"], 28, 2 + i * 16)
    for i, n in enumerate(party):  # 横隊（左へ歩く: 先頭が左）
        stamp(sp[n]["frames"]["left_0" if i % 2 == 0 else "left_1"], 46 + i * 16, 8)
    for i, n in enumerate(party):  # 横隊（右へ）
        stamp(sp[n]["frames"]["right_0" if i % 2 == 0 else "right_1"], 46 + (2 - i) * 16, 30)
    render(g, W3, H3, 1, DBG + "/party.png")
    render(g, W3, H3, 6, DBG + "/party@6x.png")

if __name__ == "__main__":
    exec(open(os.path.join(os.path.dirname(__file__), "chars_parts.py")).read()) if os.path.exists(os.path.join(os.path.dirname(__file__), "chars_parts.py")) else None
    main()
