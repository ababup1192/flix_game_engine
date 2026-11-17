#!/usr/bin/env bash
# lighting-sheets.sh — make lighting と make lighting-frames が debug/lighting/ に書いた絵を、日本語の大きなラベルを付けて並べる（ffmpeg の drawtext と xstack）。
#   ./lighting-sheets.sh [Blender の部屋の手本の PNG]   → debug/lighting/sheet_*.png と debug/lighting/lamps_shadows.mp4
# 手本を省くと、光の量の読み方の比べは 3 枚で並べる。
set -euo pipefail
cd "$(dirname "$0")/debug/lighting"
font="/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"
reference="${1:-}"

# label <入力> <出力> <ラベル>: 上に 80 px の黒い帯を足し、ラベルを白で書く。
label() {
	ffmpeg -v error -y -i "$1" -vf "scale=960:540,pad=960:620:0:80:black,drawtext=fontfile='${font}':text='$3':fontcolor=white:fontsize=40:x=24:y=20" "$2"
}

# row <出力> <入力…>: 横に並べる。
row() {
	local out="$1"; shift
	local args=() n=$#
	for f in "$@"; do args+=(-i "$f"); done
	ffmpeg -v error -y "${args[@]}" -filter_complex "hstack=inputs=${n}" "$out"
}

mkdir -p labeled
label room_shadow_off.png labeled/a.png "部屋・点光源の影なし（今）"
label room_shadow_on.png labeled/b.png "部屋・点光源の影あり（松明 4 本）"
row sheet_point_shadows_room.png labeled/a.png labeled/b.png

label lamps_shadow_off.png labeled/a.png "夜の街灯・影なし（今）"
label lamps_shadow_on.png labeled/b.png "夜の街灯・点光源の影あり（6 本）"
row sheet_point_shadows_lamps.png labeled/a.png labeled/b.png

label room_units_legacy.png labeled/a.png "光の単位・今（Legacy）"
label room_units_physical.png labeled/b.png "Physical（intensity そのまま）"
label room_units_physical_x4.png labeled/c.png "Physical・intensity×4π＋点光源の影"
if [ -n "$reference" ] && [ -f "$reference" ]; then
	label "$reference" labeled/d.png "Blender（Cycles・手本）"
	ffmpeg -v error -y -i labeled/a.png -i labeled/b.png -i labeled/c.png -i labeled/d.png \
		-filter_complex "[0][1]hstack[top];[2][3]hstack[bottom];[top][bottom]vstack" sheet_light_units_room.png
else
	row sheet_light_units_room.png labeled/a.png labeled/b.png labeled/c.png
fi

label room_units_physical_x2.png labeled/a.png "Physical・intensity×2π"
label room_units_physical_x3.png labeled/b.png "Physical・intensity×3π"
label room_units_physical_x6.png labeled/c.png "Physical・intensity×6π"
row sheet_light_units_sweep.png labeled/a.png labeled/b.png labeled/c.png

label sun_caster_before.png labeled/a.png "キャラの太陽の影・今（板そのまま）"
label sun_caster_after.png labeled/b.png "影の板を 幅0.6・高さ0.7 に絞る"
label lamps_caster_before.png labeled/c.png "街灯の影・今（板そのまま）"
label lamps_caster_after.png labeled/d.png "街灯の影・幅0.6・高さ0.7"
ffmpeg -v error -y -i labeled/a.png -i labeled/b.png -i labeled/c.png -i labeled/d.png \
	-filter_complex "[0][1]hstack[top];[2][3]hstack[bottom];[top][bottom]vstack" sheet_billboard_shadow_scale.png

if [ -d frames ] && ls frames/on_000.png >/dev/null 2>&1; then
	ffmpeg -v error -y -framerate 6 -i frames/off_%03d.png -framerate 6 -i frames/on_%03d.png -filter_complex \
		"[0]scale=960:540,pad=960:620:0:80:black,drawtext=fontfile='${font}':text='影なし（今）':fontcolor=white:fontsize=40:x=24:y=20[a];[1]scale=960:540,pad=960:620:0:80:black,drawtext=fontfile='${font}':text='点光源の影あり':fontcolor=white:fontsize=40:x=24:y=20[b];[a][b]hstack,format=yuv420p" \
		-c:v libx264 -r 24 lamps_shadows.mp4
fi
rm -rf labeled
ls -1 sheet_*.png lamps_shadows.mp4 2>/dev/null || true
