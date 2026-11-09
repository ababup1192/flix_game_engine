#!/usr/bin/env python3
"""テスト用の透過画像 assets/cast/_sample_plain.png（単色の立ち姿の形）をコードで書く。

使い方: python3 art/cast/sample.py

描き出しとテストが立ち絵の層を確かめるための物で、作例のシナリオには出さない（CastDoc.sample が名前 _sample で引く）。
Pillow を使わず、標準ライブラリ（zlib・struct）だけで PNG を書く。縁は 4×4 の副画素で塗って透明度をなめらかにする。
縦横の比（160 ÷ 400 = 0.4）は CastDoc.sample の aspect と同じにする（make lint-cast が見る）。
"""
import math
import os
import struct
import zlib

W, H = 160, 400
INK = (212, 200, 182)   # 生成りの肌の上に、少し暖かい灰の一色
EDGE = (150, 138, 124)  # 輪郭に寄るほど暗く（形の丸みが読める）


def inside(x: float, y: float) -> float:
    """(x, y) が立ち姿の形の中なら 0〜1 の内側の深さ（0 = 外）。頭・首・肩から裾へ広がる胴。"""
    # 頭（楕円）
    hx, hy, hrx, hry = W / 2, 62.0, 30.0, 36.0
    d = ((x - hx) / hrx) ** 2 + ((y - hy) / hry) ** 2
    if d <= 1.0:
        return 1.0 - d
    # 首
    if 92 <= y <= 112 and abs(x - W / 2) <= 11:
        return 0.5
    # 胴: 肩（y=112）から裾（y=H）へ、肩幅 104 → 裾幅 150 に広がる角の丸い台形
    if 108 <= y <= H:
        t = (y - 108) / (H - 108)
        half = 52 + 23 * t
        # 肩の角を丸める
        if y < 128:
            half -= (128 - y) * 0.9
        dx = abs(x - W / 2)
        if dx <= half:
            return min(1.0, (half - dx) / 18.0)
    return 0.0


def pixel(px: int, py: int) -> tuple:
    cover = 0.0
    depth = 0.0
    n = 4
    for sy in range(n):
        for sx in range(n):
            v = inside(px + (sx + 0.5) / n, py + (sy + 0.5) / n)
            if v > 0.0:
                cover += 1.0
                depth += v
    if cover == 0.0:
        return EDGE + (0,)  # 透明な画素も縁の色にしておく（なめらかに読む時に黒がにじまない）
    k = min(1.0, depth / cover)
    rgb = tuple(round(e + (i - e) * math.sqrt(k)) for i, e in zip(INK, EDGE))
    return rgb + (round(255 * cover / (n * n)),)


def png(rows: list) -> bytes:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + bytes(c for p in row for c in p) for row in rows)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def main():
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "cast", "_sample_plain.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as f:
        f.write(png([[pixel(x, y) for x in range(W)] for y in range(H)]))
    print(f"{os.path.normpath(out)} {W}x{H}")


if __name__ == "__main__":
    main()
