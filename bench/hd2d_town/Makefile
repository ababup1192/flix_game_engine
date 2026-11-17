# hd2d_town — HD-2D の町の試作（タイル地図 JSON から 3D の地面と箱を組み、2D の絵を立てる・パーティ 3 人が歩く）。どの口も窓を開かない。
#   make compare … Blender の試作と同じ止めたカメラで 1 枚（debug/compare_engine.png・1920×1080）→ debug/compare_side_by_side.png（左右に並べた 1 枚）
#   make frames  … 地図の walk の台本で歩いて止まる 30 fps のコマを CPU で描く（debug/frames/・FRAME_FROM / FRAME_TO で範囲・書いたコマは飛ばす・SCALE=4 で 1280×720）
#   make video   … frames を ffmpeg で debug/hd2d_town_walk.mp4 にする
#   make time    … 歩く場面の 1 コマを CPU で描く時間（後がけつき・なし）
#   make test    … 地図の読み・立体の決まり・カメラの式・隊列のテスト
#   make check   … 型検査だけ
#
# 地図と絵は ~/Desktop/hd2d_lab の写し（assets/）。見た目のつまみは assets/town.json。

.PHONY: compare side frames video time test check

BLENDER_SHOT ?= $(HOME)/Desktop/hd2d_lab/art/hd2d_gen/out/blender_tilemap_avenue_15_50_day.png
JFONT ?= /System/Library/Fonts/ヒラギノ角ゴシック W6.ttc

compare:
	../../bin/flix run --entrypoint Video.compare
	@$(MAKE) --no-print-directory side

side:
	@lab() { echo "scale=960:540,drawtext=fontfile='$(JFONT)':text='$$1':x=14:y=12:fontsize=26:fontcolor=white:box=1:boxcolor=black@0.6:boxborderw=8"; }; \
	ffmpeg -v error -y -i "$(BLENDER_SHOT)" -i debug/compare_engine.png -filter_complex \
	  "[0]$$(lab 'Blender の試作（EEVEE）')[a];[1]$$(lab 'エンジン（CPU の SoftRaster・同じ地図とカメラ）')[b];[a][b]hstack" debug/compare_side_by_side.png
	@echo debug/compare_side_by_side.png

frames:
	@mkdir -p debug/frames
	../../bin/flix run --entrypoint Video.frames

video:
	ffmpeg -v error -y -framerate 30 -i debug/frames/f%04d.png -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart debug/hd2d_town_walk.mp4
	@ls -la debug/hd2d_town_walk.mp4

time:
	../../bin/flix run --entrypoint Video.time

test:
	../../bin/flix test

check:
	../../bin/flix check
