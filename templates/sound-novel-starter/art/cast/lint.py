#!/usr/bin/env python3
"""make lint-cast: assets/novel.cast.json の人物と小物の絵が揃っているかを見る（読むだけ・Pillow は要らない）。

見る物: 全部の表情の「cast_<名前>_<表情>」が project.json の textures にあるか・その path のファイルがあるか・
PNG の縦横の比が Doc の aspect と 2% より離れていないか（View はテクスチャの大きさを引けないので、比は Doc が持つ）・
既定の表情 face が faces の中にあり、既定の位置 slot が slots と portraitSlots の両方にあるか（無いとゲームは faces の頭・slots の頭へ丸める）。
ずれは 1 行ずつ出して終わりの番号 1。
"""
import json
import os
import struct
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def png_size(path: str):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", head[16:24])


def main() -> int:
    doc = json.load(open(os.path.join(ROOT, "assets", "novel.cast.json"), encoding="utf-8"))
    project = json.load(open(os.path.join(ROOT, "project.json"), encoding="utf-8"))
    textures = {t.get("name"): t.get("path") for t in project.get("textures", [])}
    problems = []
    count = 0
    for kind in ("cast", "props"):
        for name, entry in doc.get(kind, {}).items():
            aspect = float(entry.get("aspect", 0.0))
            face = entry.get("face", "")
            if face not in entry.get("faces", []):
                problems.append(f"{kind}.{name}: 既定の表情 face '{face}' が faces {entry.get('faces', [])} に無い")
            slot = entry.get("slot", "")
            for key in ("slots", "portraitSlots"):
                if slot not in doc.get(key, {}):
                    problems.append(f"{kind}.{name}: 既定の位置 slot '{slot}' が {key} に無い")
            for face in entry.get("faces", []):
                count += 1
                texture = f"cast_{name}_{face}"
                path = textures.get(texture)
                if path is None:
                    problems.append(f"{kind}.{name}: textures に {texture} が無い（project.json に path と hasAlpha: true で足す）")
                    continue
                size = png_size(os.path.join(ROOT, path))
                if size is None:
                    problems.append(f"{kind}.{name}: {path} が無いか PNG でない")
                    continue
                real = size[0] / size[1]
                if aspect <= 0 or abs(real - aspect) / real > 0.02:
                    problems.append(f"{kind}.{name}: {path} の比は {real:.3f}（{size[0]}x{size[1]}）・Doc の aspect は {aspect}")
    for line in problems:
        print(f"[lint-cast] {line}")
    print(f"[lint-cast] {'OK' if not problems else 'NG'}（表情 {count} 枚）")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
