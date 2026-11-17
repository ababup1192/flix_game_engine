#!/usr/bin/env python3
"""sprite.json を拡大 PNG・GIF にする（PIL 無しで動く）。

  render.py png   <sprite.json> <outdir> [--scale 8] [--delay 200]
        各スプライト: 1 コマ目・全コマの帯・2 コマ以上なら GIF（sprite に "delayMs": 全コマ共通 か "delaysMs": [コマごと] を書ける）
  render.py tiles <sprite.json> <outdir> <pattern> --map G=grass,D=dirt,... [--scale 8]
        pattern は "GGDS/GDSS/..." のように 1 字 = 1 タイル、/ で行を区切る
  render.py show  <sprite.json> <name> [<frame>]   行と列の目盛り付きで格子を出す
  render.py diff  <a.sprite.json> <b.sprite.json>  コマごとに変わった画素の数と範囲
"""
import json, math, os, struct, subprocess, sys, zlib

BG = (42, 42, 51, 255)


def load(path):
    d = json.load(open(path))
    base = os.path.dirname(os.path.abspath(path))
    pf = d.get("paletteFile")
    pal = {}
    if pf:
        for cand in (os.path.join(base, pf), os.path.join(base, "..", pf), os.path.join(base, os.path.basename(pf))):
            if os.path.exists(cand):
                pal = json.load(open(cand))
                break
        else:
            sys.exit(f"palette が見つからない: {pf}")
    colors = {}
    for ch, name in d.get("legend", {}).items():
        e = pal.get(name)
        if e is None:
            sys.exit(f"legend {ch}={name} が palette に無い")
        r, g, b = e["rgb"]
        a = e.get("a", 1.0)
        colors[ch] = (round(r * 255), round(g * 255), round(b * 255), round(a * 255))
    return d, colors


def frames_of(sp):
    fr = sp["frames"]
    return list(fr.items()) if isinstance(fr, dict) else [(str(i), f) for i, f in enumerate(fr)]


def to_rgba(rows, colors):
    out = []
    for y, row in enumerate(rows):
        line = []
        for x, ch in enumerate(row):
            if ch in ". ":
                line.append((0, 0, 0, 0))
            elif ch in colors:
                line.append(colors[ch])
            else:
                sys.exit(f"知らない字 '{ch}' (行 {y} 列 {x})")
        out.append(line)
    w = max(len(r) for r in out)
    for y, r in enumerate(out):
        if len(r) != w:
            sys.exit(f"行 {y} の幅 {len(r)} != {w}")
    return out


def write_png(path, px, scale=1, bg=None):
    h = len(px) * scale
    w = len(px[0]) * scale
    raw = bytearray()
    for row in px:
        line = bytearray()
        for p in row:
            if bg and p[3] == 0:
                p = bg
            line += bytes(p) * scale
        for _ in range(scale):
            raw += b"\x00" + line

    def chunk(t, data):
        c = struct.pack(">I", len(data)) + t + data
        return c + struct.pack(">I", zlib.crc32(t + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)


def hstack(imgs, gap=1):
    h = max(len(i) for i in imgs)
    out = [[] for _ in range(h)]
    for k, im in enumerate(imgs):
        for y in range(h):
            out[y] += im[y] if y < len(im) else [BG] * len(im[0])
            if k < len(imgs) - 1:
                out[y] += [BG] * gap
    return out


def cmd_png(path, outdir, scale, delay_ms):
    d, colors = load(path)
    os.makedirs(outdir, exist_ok=True)
    for name, sp in d["sprites"].items():
        frs = [to_rgba(rows, colors) for _, rows in frames_of(sp)]
        write_png(os.path.join(outdir, f"{name}.png"), frs[0], scale, BG)
        if len(frs) > 1:
            write_png(os.path.join(outdir, f"{name}.strip.png"), hstack(frs), scale, BG)
            tmp = os.path.join(outdir, f".{name}_frames")
            os.makedirs(tmp, exist_ok=True)
            delays = sp.get("delaysMs") or [sp.get("delayMs", delay_ms)] * len(frs)
            if len(delays) != len(frs):
                sys.exit(f"{name}: delaysMs の数 {len(delays)} != コマ数 {len(frs)}")
            unit = max(10, math.gcd(*delays))
            seq = [f for f, dl in zip(frs, delays) for _ in range(max(1, dl // unit))]
            for i, f in enumerate(seq):
                write_png(os.path.join(tmp, f"{i:03d}.png"), f, scale, BG)
            fps = 1000.0 / unit
            subprocess.run(
                ["ffmpeg", "-loglevel", "error", "-y", "-framerate", f"{fps}", "-i", os.path.join(tmp, "%03d.png"),
                 "-vf", "split[a][b];[a]palettegen=reserve_transparent=0:stats_mode=full[p];[b][p]paletteuse=dither=none",
                 "-loop", "0", os.path.join(outdir, f"{name}.gif")],
                check=True)
            for f in os.listdir(tmp):
                os.remove(os.path.join(tmp, f))
            os.rmdir(tmp)
        print(f"{name}: {len(frs)} コマ → {outdir}")


def cmd_tiles(path, outdir, pattern, mapping, scale):
    d, colors = load(path)
    os.makedirs(outdir, exist_ok=True)
    tiles = {ch: to_rgba(frames_of(d["sprites"][nm])[0][1], colors) for ch, nm in mapping.items()}
    out = []
    for prow in pattern.split("/"):
        for y in range(len(tiles[prow[0]])):
            line = []
            for ch in prow:
                line += tiles[ch][y]
            out.append(line)
    write_png(os.path.join(outdir, "tiles_4x4.png"), out, scale, BG)
    print(f"tiles_4x4.png ({pattern})")


def cmd_show(path, name, frame):
    d, _ = load(path)
    frs = dict(frames_of(d["sprites"][name]))
    rows = frs[frame] if frame else list(frs.values())[0]
    w = len(rows[0])
    print("    " + "".join(str(x // 10) if x % 10 == 0 else " " for x in range(w)))
    print("    " + "".join(str(x % 10) for x in range(w)))
    for y, r in enumerate(rows):
        print(f"{y:3d} {r}")
    print("legend:", d["legend"])


def cmd_diff(a, b):
    da, _ = load(a)
    db, _ = load(b)
    for name in db["sprites"]:
        if name not in da["sprites"]:
            print(f"{name}: 新しい")
            continue
        fa = dict(frames_of(da["sprites"][name]))
        fb = dict(frames_of(db["sprites"][name]))
        for k, rb in fb.items():
            ra = fa.get(k)
            if ra is None:
                print(f"{name}/{k}: 新しいコマ")
                continue
            pts = [(x, y) for y in range(min(len(ra), len(rb))) for x in range(min(len(ra[y]), len(rb[y]))) if ra[y][x] != rb[y][x]]
            if pts:
                xs = [p[0] for p in pts]
                ys = [p[1] for p in pts]
                print(f"{name}/{k}: {len(pts)} 画素 x{min(xs)}..{max(xs)} y{min(ys)}..{max(ys)}")


def main():
    a = sys.argv[1:]

    def opt(flag, default):
        if flag in a:
            i = a.index(flag)
            v = a[i + 1]
            del a[i:i + 2]
            return v
        return default

    scale = int(opt("--scale", "8"))
    delay = int(opt("--delay", "200"))
    mp = opt("--map", "")
    if not a:
        print(__doc__)
        return
    c = a[0]
    if c == "png":
        cmd_png(a[1], a[2], scale, delay)
    elif c == "tiles":
        cmd_tiles(a[1], a[2], a[3], dict(kv.split("=") for kv in mp.split(",")), scale)
    elif c == "show":
        cmd_show(a[1], a[2], a[3] if len(a) > 3 else None)
    elif c == "diff":
        cmd_diff(a[1], a[2])
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
