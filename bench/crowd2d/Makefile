# crowd2d — 2D の敵の群れ。全員が動く目標を追いながら近くの敵と押し合う。近くの敵を探す処理を
# 全部と比べる形と SpatialGrid で比べる。敵の数は Crowd.counts。
#   make cpu-time … 窓を開かず規則だけを回し、1 コマの p50 / p95 を出す。FlowField と 1 体ずつの経路探索の比べも出す
#   make run      … 実機の窓で敵の数 × 探し方の区間を順に回し、1 コマ・規則・GL へ送る・swap・GPU の時間を出して閉じる
#                 COUNTS=6000,10000 で敵の数を替える
#   make check    … 型検査だけ走らせる

.PHONY: cpu-time run check

cpu-time:
	../../bin/flix run --entrypoint CrowdCpu.time

run:
	FLIX_GE_NO_VSYNC=1 ../../bin/flix run

check:
	../../bin/flix check
