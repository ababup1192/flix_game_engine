# crowd2d — 2D の敵の群れ。全員が動く目標を追いながら近くの敵と押し合う。近くの敵を探す処理を
# 全部と比べる形と SpatialGrid で比べる。敵の数は Crowd.counts。
#   make cpu-time … 窓を開かず規則だけを回し、1 コマの p50 / p95 を出す。FlowField と 1 体ずつの経路探索の比べも出す
#   make run      … 実機の窓で敵の数 × 探し方の区間を順に回し、区間ごとに 1 行の JSON（[bench] result …。1 コマ・規則（work）・
#                 GL へ送る・swap・GPU の時間）を出して閉じる
#                 COUNTS=6000,10000,20000 で敵の数・SEARCH=grid（scan / both）で探し方・FRAMES=300 で 1 区間で測るコマ数を替える
#                 20,000 体を全部と比べる形で回すと 1 コマ 約 200 ms（300 コマで 約 90 秒）かかり、機械が熱くなる。SEARCH=grid を付ける
#   make check    … 型検査だけ走らせる
# 基準は RESULTS.md。ブラウザ版は engine の根で make bench-web BENCH=crowd2d ARGS='n=20000&search=grid'。

.PHONY: common-fresh cpu-time run check

cpu-time:
	../../bin/flix run --entrypoint CrowdCpu.time

run: common-fresh
	FLIX_GE_NO_VSYNC=1 FLIX_GE_MUTE=1 ../../bin/flix run

check: common-fresh
	../../bin/flix check

# src の BenchRun.flix・BenchEnv.flix は bench/common の写し。食い違ったまま測らない。
common-fresh:
	@for f in BenchRun.flix BenchEnv.flix; do cmp -s ../common/$$f src/$$f || { echo "src/$$f が bench/common と違う。engine の根で make bench-common"; exit 1; }; done
