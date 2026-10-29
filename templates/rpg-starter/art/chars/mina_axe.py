#!/usr/bin/env python3
# mina の手持ちの武器を 3 案で描き比べ、選んだ案を chars_parts.py の mina に入れる。
#   python3 mina_axe.py compare   … 3 案を描き、debug/chars/axe_variants.png に並べる
#   python3 mina_axe.py use <A|B|C> … その案を chars_parts.py に書き、gen_chars.py を流す
# 塗り方は 3 案とも同じ: 鉄は墨（K）、刃先・打つ面だけ fc37（S）の 1px、柄は橙（A）1 色。
# 重ねる格子は 6 列 × 11 行（列 10〜15・行 0〜10）。'.' は基の絵のまま。
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = "/Users/abab/Desktop/flix_game_engine/templates/rpg-starter"

# 基の絵（列 10〜15 の行 0〜11 を空けてある。列 9 が胴の縁）
BASE = {
 # 頭（列 1〜10）の中心 5.5 を胴（列 3〜8）と脚の中心にそろえる。頭と胴の中心がずれると顔が傾いて見える。
 "front": ["................", "..KKKKKKKK......", ".KAAAAAAAAK.....", ".KAAAAAAAAK.....",
           ".KKSKKKKSKK.....", ".KSSKSSKSSK.....", ".KSSSSSSSSK.....", "..KKSSSSKK......",
           ".KKKAKKAKS......", "KSSKAAAAKS......", "KSSKAAAAKK......", "KSSKKKKKK.......",
           ".KKAAAAAAK......"],
 "back":  ["................", "..KKKKKKKK......", ".KAAAAAAAAK.....", ".KAAAAAAAAK.....",
           ".KKKKAAKKKK.....", ".KKKAKKAKKK.....", ".KKKKKKKKKK.....", "..KKSSSSKK......",
           ".KKKAAAAKS......", "KSSKAAAAKS......", "KSSKAAAAKK......", "KSSKKKKKK.......",
           ".KKAAAAAAK......"],
 "left":  ["................", "...KKKKKKK......", "..KAAAAAAAK.....", "..KAAAAAAAK.....",
           ".KKSSKKKKAK.....", ".KSKSSKKKAK.....", ".KSSSSSKKKK.....", "..KKSSSKKK......",
           "..KKAAAAAK......", ".KSSKAAAAK......", "KSSSKAAAAK......", "KSSKKKKKKK......",
           ".KKAAAAAAAK....."],
}

VARIANTS = {
 # 案 A ひげ斧: 刃は上で柄に付き、下の角が柄から離れて長く垂れる（柄の側にくぼみ）
 "A": ["......",   # 0  列: 10 11 12 13 14 15
       ".AKKS.",   # 1  上の角は小さい
       ".AKKKS",   # 2
       ".A.KKS",   # 3  柄の側のくぼみ
       ".A.KKS",   # 4
       ".A.KKS",   # 5
       ".A.KS.",   # 6
       "KAKS..",   # 7  垂れた下の角の先・拳の上の墨
       "SSSK..",   # 8  拳
       "SSSK..",   # 9
       "KAK..."],  # 10 拳の下の短い柄
 # 案 B 両刃の斧: 柄（列 13）の左右に三日月の刃。柄は刃の上へ 1px 突き出す
 "B": ["...A..",
       ".S.A.S",
       ".SKAKS",
       ".SKAKS",
       ".SKAKS",
       ".S.A.S",
       "...A..",
       "..KAK.",
       "SSSSSK",
       "SSSSSK",
       "KKKAK."],
 # 案 C 鉱夫のハンマー: 柄（列 13）の真上に 5×3 の鉄の頭を T 字に載せる。角を 1px 落とし、両の打つ面に明るい縁。
 # 頭は行 0〜2: 顔の右の縁（列 10・行 2〜6）に打つ面が接すると、ハンマーが頭に付いて見える
 # （柄の片側にだけ張り出すと旗に読まれるので、柄の中心に左右同じだけ出す）
 "C": ["..KKK.",
       ".SKKKS",
       "..KKK.",
       "...A..",
       "...A..",
       "...A..",
       "...A..",
       "..KAK.",
       "SSSSSK",
       "SSSSSK",
       "KKKAK."],
}

NOTE = {
 "A": "手斧は橙の短い柄を拳で握る。刃はひげ斧（上の角は小さく、下の角が柄から離れて垂れる）で、鉄は墨・刃先の弧だけ fc37。明るい面の扇にすると旗に読まれる。",
 "B": "手斧は両刃。柄の左右に墨の三日月の刃を付け、外の弧だけ fc37。明るい面の扇にすると旗に読まれる。",
 "C": "鉱夫のハンマー。橙の短い柄の先に墨の鉄の頭（角を落とし、両の打つ面だけ fc37）。明るい面にすると旗に読まれる。",
}

def overlay(base, ov):
    out = []
    for y, r in enumerate(base):
        if y < len(ov):
            r = list(r)
            for i, ch in enumerate(ov[y]):
                if ch != ".":
                    r[10 + i] = ch
            r = "".join(r)
        out.append(r)
    return out

def mina_rows(v):
    ov = VARIANTS[v]
    front = overlay(BASE["front"], ov)
    back = overlay(BASE["back"], ov)
    left = overlay(BASE["left"], ov)
    for rows in (front, back, left):
        assert all(len(r) == 16 for r in rows)
    return {"down": front, "up": ["".join(reversed(r)) for r in back], "left": left}

def write_parts(v):
    path = os.path.join(HERE, "chars_parts.py")
    s = open(path).read()
    def fmt(rows):
        return "[" + ",\n                 ".join(f'"{r}"' for r in rows) + "]"
    rows = mina_rows(v)
    a = s.index('CH["mina"]')
    for d in ("down", "up", "left"):
        u = s.index("upper=", a)
        i = s.index(f'"{d}":', u)
        j = s.index("]", i)
        s = s[:i] + f'"{d}": ' + fmt(rows[d])[:-1] + s[j:]
    n0 = s.index('note="', a) + 6
    n1 = s.index('"', n0)
    s = s[:n0] + "ミナ。鉱夫の娘。橙のバンダナ（fc17）と袖なしの胴着・太い腕。" + NOTE[v] + s[n1:]
    open(path, "w").write(s)

def gen():
    env = dict(os.environ, DEVELOPER_DIR="/Library/Developer/CommandLineTools")
    subprocess.run([sys.executable, os.path.join(HERE, "gen_chars.py")], check=True, env=env)

def compare():
    g = {}
    exec(open(os.path.join(HERE, "gen_chars.py")).read().split("if __name__")[0], g)
    pal = g["load_palette"]()
    shots = {}
    for v in VARIANTS:
        write_parts(v)
        gen()
        shots[v] = json.load(open(ROOT + "/assets/rpg.chars.sprite.json"))
    order = ["down_0", "down_1", "up_0", "up_1", "left_0", "left_1", "right_0", "right_1"]
    grass, dark = pal["fc1A"], (40, 40, 48)
    # 1 案 = 1 段: [mina 8 コマ（実寸）] [隊列（実寸 64×24）] [隊列（6 倍）]
    PW, PH = 64, 24
    S6 = 6
    rowh = PH * S6 + 8
    W = 8 * 18 + 4 + PW + 8 + PW * S6 + 4
    H = len(VARIANTS) * rowh + 4
    cv = [[dark] * W for _ in range(H)]
    def stamp(doc, name, fn, ox, oy, scale=1):
        leg = doc["legend"]
        fr = doc["sprites"][name]["frames"][fn]
        for y in range(16):
            for x in range(16):
                ch = fr[y][x]
                if ch == ".":
                    continue
                for dy in range(scale):
                    for dx in range(scale):
                        cv[oy + y * scale + dy][ox + x * scale + dx] = pal[leg[ch]]
    def fill(ox, oy, w, h, col):
        for y in range(oy, oy + h):
            for x in range(ox, ox + w):
                cv[y][x] = col
    for k, v in enumerate(VARIANTS):
        doc = shots[v]
        y0 = 4 + k * rowh
        for i, fn in enumerate(order):
            fill(4 + i * 18, y0, 16, 16, grass)
            stamp(doc, "mina", fn, 4 + i * 18, y0)
        # 隊列: 右へ歩く横隊（先頭 hero）と下向きの縦隊は幅が足りないので横隊 + 正面の 3 人
        for scale, ox in ((1, 8 * 18 + 8), (S6, 8 * 18 + 8 + PW + 8)):
            fill(ox, y0, PW * scale, PH * scale, grass)
            for i, n in enumerate(("toto", "mina", "hero")):
                stamp(doc, n, "right_0" if i % 2 == 0 else "right_1", ox + (2 + i * 18) * scale, y0 + 4 * scale, scale)
        # 実寸の隊列の下に正面の 3 人
        ox = 8 * 18 + 8
        fill(ox, y0 + PH + 4, PW, 20, grass)
        for i, n in enumerate(("hero", "mina", "toto")):
            stamp(doc, n, "down_0", ox + 2 + i * 20, y0 + PH + 6)
    g["render"](cv, W, H, 1, ROOT + "/debug/chars/axe_variants.png")
    g["render"](cv, W, H, 2, ROOT + "/debug/chars/axe_variants@2x.png")

if __name__ == "__main__":
    if sys.argv[1] == "compare":
        compare()
    elif sys.argv[1] == "use":
        write_parts(sys.argv[2])
        gen()
