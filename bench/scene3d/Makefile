# scene3d — 3D の描き物（Render.Item.Scene3d）の固定の部屋 1 つ（床と壁・家具 12・松明 4）。
#   make still … CPU（SoftRaster）で静止画を 1 枚描く → debug/room.png（窓を開かない）
#   make cpu-time … CPU で同じ部屋を温めてから何回か描き（回数は Still.timingPlan）、1 枚の時間の中央値を出す（窓を開かない。PNG は書かない）
#   make run   … 実機の窓で毎コマ同じ部屋を描き、カメラを少しずつ回す。区間ごとに 1 行の JSON（[bench] result …。1 コマ・GL へ送る・GPU の時間・
#                draw call・3D の描き手の CPU の区間）を出し、4 区間で閉じる（GL の確かめと重さを測る用。垂直同期は切る）
#   make run SCENE=field … 小さな箱と柱を格子に並べた場面（src/Field.flix）。つまみ:
#                COUNT=1000（物の数）・SHAPES=1（形の種類。each で物ごとに違う形）・MATS=1（材質の種類）・MOVING=100（動く物の %）・
#                ALPHA=0（半透明の物の %）・SHADOW=1（太陽の影）。FRAMES=240 で 1 区間で測るコマ数・REPEAT=4 で同じ条件を続けて測る回数
#   make check … 型検査だけ走らせる
#
# 家具は assets/models/*.obj（fps3d_lab の写し。Blender の 1 m = world の 16）。
# 基準は RESULTS.md。ブラウザ版は engine の根で make bench-web BENCH=scene3d ARGS='scene=field&n=12000'。

.PHONY: common-fresh still cpu-time run check

still:
	../../bin/flix run --entrypoint Still.write

cpu-time:
	../../bin/flix run --entrypoint Still.time

run: common-fresh
	FLIX_GE_NO_VSYNC=1 FLIX_GE_MUTE=1 ../../bin/flix run

check: common-fresh
	../../bin/flix check

# src の BenchRun.flix・BenchEnv.flix は bench/common の写し。食い違ったまま測らない。
common-fresh:
	@for f in BenchRun.flix BenchEnv.flix; do cmp -s ../common/$$f src/$$f || { echo "src/$$f が bench/common と違う。engine の根で make bench-common"; exit 1; }; done
