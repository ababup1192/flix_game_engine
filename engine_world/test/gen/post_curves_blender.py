# Blender（5.2.3）の Color Management で、線形の色の帯を view transform と露出に通した 8bit の値を表にし、
# engine_world/test/gen/PostCurveCases.flix（TestPostStackBlender が読む手本）を書く。
#
#   /nix/store/2rqcqsp3ww61r0qw46izbppssz3bnqxg-blender-5.2.3/bin/blender -b --factory-startup \
#       --python engine_world/test/gen/post_curves_blender.py -- engine_world/test/gen/PostCurveCases.flix
#
# 帯: 明るさ 2^-8〜2^4（13 段）× 色相 12 × 彩度 3（0・0.5・1）。色は HSV（明度 1）を線形の値として 2^段 を掛けた物。
# Blender の設定: 表示 sRGB・Look なし・gamma 1・カーブなし・ディザ 0・8bit PNG（Image.save_render が view transform を掛ける）。
# Blender の版を上げた時はこれを流し直し、出た表を差分で見る。
import bpy
import colorsys
import os
import sys
import tempfile

CONFIGS = [
    # (Flix の関数名, Blender の view transform, 露出)
    ("standardZero", "Standard", 0.0),
    ("standardPlusTwo", "Standard", 2.0),
    ("standardMinusTwo", "Standard", -2.0),
    ("neutralZero", "Khronos PBR Neutral", 0.0),
    ("neutralPlusTwo", "Khronos PBR Neutral", 2.0),
]


def band():
    out = []
    for step in range(13):
        scale = 2.0 ** (step - 8)
        for hue in range(12):
            for sat in (0.0, 0.5, 1.0):
                r, g, b = colorsys.hsv_to_rgb(hue / 12.0, sat, 1.0)
                out.append((r * scale, g * scale, b * scale))
    return out


def render(samples, view, exposure, tmp):
    scene = bpy.context.scene
    scene.display_settings.display_device = "sRGB"
    vs = scene.view_settings
    vs.view_transform = view
    vs.look = "None"
    vs.exposure = exposure
    vs.gamma = 1.0
    vs.use_curve_mapping = False
    scene.render.dither_intensity = 0.0
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_depth = "8"
    scene.render.image_settings.color_mode = "RGBA"
    n = len(samples)
    img = bpy.data.images.new("band", n, 1, alpha=True, float_buffer=True)
    img.colorspace_settings.name = "Linear Rec.709"
    flat = []
    for (r, g, b) in samples:
        flat += [r, g, b, 1.0]
    img.pixels = flat
    path = os.path.join(tmp, "band.png")
    img.save_render(path, scene=scene)
    bpy.data.images.remove(img)
    back = bpy.data.images.load(path)
    back.colorspace_settings.name = "Non-Color"
    px = list(back.pixels)
    bpy.data.images.remove(back)
    return [tuple(int(round(px[i * 4 + c] * 255.0)) for c in range(3)) for i in range(n)]


def main():
    target = sys.argv[sys.argv.index("--") + 1]
    samples = band()
    lines = [
        "// 生成物: engine_world/test/gen/post_curves_blender.py が Blender 5.2.3 で書く。手で編集しない。",
        "// 1 行 = 線形の r g b（入力）と、Blender の Color Management を通した 8bit の r g b（答え）。",
        "mod PostCurveCases {",
    ]
    with tempfile.TemporaryDirectory() as tmp:
        for (name, view, exposure) in CONFIGS:
            got = render(samples, view, exposure, tmp)
            rows = ["%.9g %.9g %.9g %d %d %d" % (s[0], s[1], s[2], o[0], o[1], o[2]) for (s, o) in zip(samples, got)]
            lines.append("    /// %s・露出 %+g。" % (view, exposure))
            lines.append("    pub def %s(): String =" % name)
            lines.append("        \"" + "\\n".join(rows) + "\"")
            lines.append("")
    lines[-1] = "}"
    with open(target, "w") as f:
        f.write("\n".join(lines) + "\n")


main()
