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

# 歩く先の町が出来ていく動画（台本は assets/buildup.json）。
#   make buildup-frames … CPU で描く（debug/build_frames/・窓を開かない）
#   make gpu-buildup    … GPU（隠しウィンドウ・FLIX_GE_FRAME_SHOT）で描く（debug/gpu_build_frames/・1 回の起動で 64 コマずつ・起動した JVM は PID で止める）
#   make buildup-video  … GPU のコマを debug/hd2d_town_buildup.mp4 にする（CPU のコマなら FRAMES_DIR=debug/build_frames）
#   make gpu-bench      … 出来た町を歩く場面の 1 コマの重さ（後がけ・太陽の影のあり・なしの 4 通り）を debug/gpu_bench.log へ
FRAMES_DIR ?= debug/gpu_build_frames
BUILDUP_FRAMES ?= 1018

.PHONY: buildup-frames gpu-buildup buildup-video gpu-bench

buildup-frames:
	@mkdir -p debug/build_frames
	../../bin/flix run --entrypoint BuildVideo.frames

gpu-buildup:
	bin/gpu_frames.sh $(BUILDUP_FRAMES)

buildup-video:
	ffmpeg -v error -y -framerate 30 -i $(FRAMES_DIR)/f%04d.png -c:v libx264 -pix_fmt yuv420p -crf 22 -movflags +faststart debug/hd2d_town_buildup.mp4
	@ls -la debug/hd2d_town_buildup.mp4

# 立ったまま、隊列を中心に輪で町が出来る動画（613 コマ・約 20.4 秒）を GPU で撮る
center-video:
	rm -rf debug/gpu_center_frames
	BUILDUP=assets/buildup_center.json bin/gpu_frames.sh 613 build debug/gpu_center_frames
	ffmpeg -v error -y -framerate 30 -i debug/gpu_center_frames/f%04d.png -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart debug/hd2d_town_buildup_center.mp4
	@ls -la debug/hd2d_town_buildup_center.mp4

# 炎の洞窟・氷の谷を地図の walk.path で歩く CPU のコマ（光なしの素の絵・debug/fire_frames/・debug/ice_frames/）。
#   FRAME_STEP=30 で 1 秒ごと・FRAME_FROM / FRAME_TO で範囲（BuildVideo.frames に WALK_MAP と LOOK を渡す）
.PHONY: fire-frames ice-frames

fire-frames:
	@mkdir -p debug/fire_frames
	WALK_MAP=assets/fire_cave.map.json LOOK=assets/fire_plain.json FRAMES_DIR=debug/fire_frames ../../bin/flix run --entrypoint BuildVideo.frames

ice-frames:
	@mkdir -p debug/ice_frames
	WALK_MAP=assets/ice_cave.map.json LOOK=assets/ice_plain.json FRAMES_DIR=debug/ice_frames ../../bin/flix run --entrypoint BuildVideo.frames

gpu-bench:
	@rm -f debug/gpu_bench.log
	@for p in 1 0; do for s in 1 0; do POST=$$p SHADOW=$$s LIMIT=300 bin/gpu_run.sh bench debug/gpu_bench_$$p$$s.log; grep '\[bench\] result' debug/gpu_bench_$$p$$s.log >> debug/gpu_bench.log; done; done
	@cat debug/gpu_bench.log

test:
	../../bin/flix test

check:
	../../bin/flix check

# 最終動画: 町・炎・氷を 1 本の通しのコマで並べ、境目を白い四角で白飛びさせる（台本は assets/final.json）。
#   make final-plan   … 場面ごとの通しのコマの区間と全体の秒を出す（絵は描かない）
#   make final-frames … CPU で描く（debug/final_frames/・FRAME_FROM / FRAME_TO / FRAME_STEP で範囲・要る場面だけ読む）
#   make final-video  … GPU（GL）で 64 コマずつ撮り、debug/hd2d_town_final.mp4・_sheet.png・_flash.png にする（KEEP=1 で撮ったコマを残す）
#                       BGM を頭から重ねる（0.5 秒で入り終わり 3 秒で消す・ピーク −1 dB 前後）。曲は git に入れず hd2d_lab から読む（無ければ音なし）
.PHONY: final-plan final-frames final-video

HD2D_LAB ?= $(HOME)/Desktop/hd2d_lab
BGM ?= $(HD2D_LAB)/audio/bgm_candidates/01_field-airship.mp3

final-plan:
	../../bin/flix run --entrypoint FinalCut.plan

final-frames:
	@mkdir -p debug/final_frames
	../../bin/flix run --entrypoint FinalCut.frames

final-video:
	BGM="$(BGM)" bin/final_video.sh

# 昼の町を歩き回る場面（src/Explore.flix・つまみは assets/explore.json・キーは assets/explore.keys.json）。
#   make explore        … 窓を開いて歩く（矢印・WASD・パッドの左スティック。重さは SHADOW_MAP=2048 DOF=0 POST=0 で落とす）
#   make explore-web    … ブラウザ版へ書き出す（build/web・bin/fge export-web）。web/measure.js を index.html に差し込む
#   make explore-serve  … 書き出した物を手元のサーバーで配る（PORT・既定 8765。スマホは同じ Wi-Fi で http://<この機械の IP>:<PORT>/）
#   make explore-grid   … 通れるマスの格子を字で出す（# 地図と建物・+ 建物の北に隠れるので塞いだ・d 広場のにぎやかし・窓を開かない）
#   make explore-record … ブラウザ版をヘッドレスの Chrome でキーを押して歩かせ、debug/web_walk.mp4 にする（台本は bin/web_walk_demo.json・
#                         先に make explore-serve を別に立てておく・URL の query は QUERY）
PORT ?= 8765
QUERY ?= backend=webgl2

.PHONY: explore explore-web explore-serve explore-grid explore-record

explore:
	../../bin/headless-run --build-only
	../../bin/headless-run --window Explore.main

explore-web:
	../../bin/fge export-web . --out build/web $(EXPORT_FLAGS)
	cp web/measure.js build/web/measure.js
	perl -0pi -e 's|<script>\n\(function \(\) \{\n  var baked|<script src="measure.js"></script>\n$$&|' build/web/index.html
	@grep -q 'measure.js' build/web/index.html || { echo "[explore-web] index.html に fge-web.js を読む script が無く、measure.js を差し込めない"; exit 1; }
	@echo "[explore-web] build/web（make explore-serve で配る）"

explore-serve:
	@echo "[explore-serve] http://localhost:$(PORT)/ ・スマホは http://$$(ipconfig getifaddr en0 2>/dev/null || echo '<この機械の IP>'):$(PORT)/?fps=1&measure=1"
	DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 -m http.server $(PORT) --bind 0.0.0.0 --directory build/web

explore-grid:
	../../bin/flix run --entrypoint Explore.printGrid

explore-record:
	rm -rf debug/web_walk_frames
	DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 bin/web_walk_record.py "http://127.0.0.1:$(PORT)/?$(QUERY)" debug/web_walk_frames
	cd debug/web_walk_frames && ffmpeg -v error -y -f concat -safe 0 -i frames.txt -vf "fps=15,format=yuv420p" -c:v libx264 -crf 22 -movflags +faststart ../web_walk.mp4
	@ls -la debug/web_walk.mp4
