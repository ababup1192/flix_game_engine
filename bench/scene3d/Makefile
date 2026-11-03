# scene3d — 3D の描き物（Render.Item.Scene3d）の固定の部屋 1 つ（床と壁・家具 12・松明 4）。
#   make still … CPU（SoftRaster）で静止画を 1 枚描く → debug/room.png（窓を開かない）
#   make cpu-time … CPU で同じ部屋を温めてから何回か描き（回数は Still.timingPlan）、1 枚の時間の中央値を出す（窓を開かない。PNG は書かない）
#   make run   … 実機の窓で毎コマ同じ部屋を描き、カメラを少しずつ回す。300 コマごとに 1 コマの p50 / p95 と GPU の時間の p50 を出し、
#                4 区間で閉じる（GL の確かめと重さを測る用。垂直同期は切る）
#   make check … 型検査だけ走らせる
#
# 家具は assets/models/*.obj（fps3d_lab の写し。Blender の 1 m = world の 16）。

.PHONY: still cpu-time run check

still:
	../../bin/flix run --entrypoint Still.write

cpu-time:
	../../bin/flix run --entrypoint Still.time

run:
	../../bin/flix run

check:
	../../bin/flix check
