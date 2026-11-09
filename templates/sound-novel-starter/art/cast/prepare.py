#!/usr/bin/env python3
"""人物と小物の透過画像を、画面に出す高さの約 1.6 倍へ縮め、透明な画素の色を縁の色で埋めて assets/cast/ に書く。

使い方: python3 art/cast/prepare.py <元の絵の置き場> [縦の画面の design の高さ（既定 1169 = 390×844 のスマホ）]
  元の絵は <置き場>/<名前>_<表情>.png（assets/novel.cast.json の cast・props の名前と faces）。
  書き先は assets/cast/<名前>_<表情>.png。project.json の textures に「cast_<名前>_<表情>」の名前で登録する。
  書いた後に make lint-cast で、Doc の aspect と登録の抜けを確かめる。
  Pillow が要る（pip install Pillow）。

高さの決め方: 画面に出す高さ（位置の height × 項目の scale × design の高さ。横は 540・縦は引数の高さの大きい方）の 1.6 倍。
人物はどの位置にも出しうるので全部の位置の一番高い物、小物は既定の位置（slot）の高さで見る。元の絵より大きくはしない。
縁を埋める理由: GPU が 2 つの画素の間をなめらかにつなぐ時、透明な画素の色（多くは黒）が混ざり、
人物の輪郭に黒い線がにじむ。透明な画素の色だけを近くの見える画素の色にしておけば、混ざっても縁の色のまま。
"""
import json
import os
import sys

from PIL import Image, ImageChops, ImageFilter, ImageMath

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
LANDSCAPE_HEIGHT = 540
PORTRAIT_HEIGHT = 1169
MARGIN = 1.6


def bleed(im: Image.Image) -> Image.Image:
    r, g, b, a = im.split()
    filled = [r, g, b]
    # 見える画素の色を、ぼかしの幅を倍々に広げながら透明な所へ流す（alpha で重みをつけて平均する）
    known = a.point(lambda v: 255 if v > 0 else 0)
    for radius in (1, 2, 4, 8, 16, 32, 64):
        w = known.filter(ImageFilter.GaussianBlur(radius))
        out = []
        for c in filled:
            pm = ImageChops.multiply(c, known).filter(ImageFilter.GaussianBlur(radius))
            avg = ImageMath.lambda_eval(lambda e: e["float"](e["p"]) * 255.0 / (e["float"](e["w"]) + 0.0001), p=pm, w=w).convert("L")
            out.append(Image.composite(c, avg, known))
        filled = out
        known = w.point(lambda v: 255 if v > 0 else 0)
    return Image.merge("RGBA", (*filled, a))


def target_height(doc: dict, kind: str, entry: dict, portrait: float) -> int:
    """その人（か小物）を出しうる一番大きな高さ × 1.6。"""
    tallest = 0.0
    for key, screen in (("slots", LANDSCAPE_HEIGHT), ("portraitSlots", portrait)):
        slots = doc.get(key, {})
        if kind == "props":
            slots = {k: v for k, v in slots.items() if k == entry.get("slot", "item")}
        for slot in slots.values():
            tallest = max(tallest, float(slot.get("height", 0.9)) * screen)
    return max(1, round(tallest * float(entry.get("scale", 1.0)) * MARGIN))


def main():
    if len(sys.argv) not in (2, 3):
        print(__doc__)
        sys.exit(1)
    src = sys.argv[1]
    portrait = float(sys.argv[2]) if len(sys.argv) == 3 else PORTRAIT_HEIGHT
    doc = json.load(open(os.path.join(ROOT, "assets", "novel.cast.json"), encoding="utf-8"))
    dst = os.path.join(ROOT, "assets", "cast")
    os.makedirs(dst, exist_ok=True)
    for kind in ("cast", "props"):
        for name, entry in doc.get(kind, {}).items():
            want = target_height(doc, kind, entry, portrait)
            for face in entry.get("faces", []):
                stem = f"{name}_{face}"
                path = os.path.join(src, stem + ".png")
                if not os.path.exists(path):
                    print(f"[prepare] 無い: {path}")
                    continue
                im = bleed(Image.open(path).convert("RGBA"))  # 縮める前に埋める（縮める時の平均にも黒が混ざらない）
                h = min(want, im.height)  # 元より大きくすると、ぼけるだけで重くなる
                w = round(im.width * h / im.height)
                im = bleed(im.resize((w, h), Image.LANCZOS))
                out = os.path.join(dst, stem + ".png")
                im.save(out, optimize=True)
                print(f"[prepare] {out} {w}x{h} aspect={w / h:.3f}（textures の名前は cast_{stem}）")


if __name__ == "__main__":
    main()
