# sprite_stress — 2D のスプライトを数だけ描く。物の数の区間を順に回し、区間ごとに 1 行の JSON（[bench] result …）を stdout へ出して閉じる。
#   make run   … 半分が単色の箱・半分が同じ絵のスプライト・SDF の字 約 300 字（COUNTS の既定 500,2000,5000,10000）
#                HUD=1 で HUD の層を足す
#   make run TEX=16            … 全部スプライト。絵は TEX 種類（1 / 16 / 256 など）を順に使う（COUNTS の既定 1000,5000,20000）
#   make run TEX=1 BLEND=alt   … Normal と Multiply を 1 個ごとに替える（BLEND だけなら TEX=1）
#   COUNTS=5000,5000 で区間の物の数・FRAMES=300 で 1 区間で測るコマ数を替える。垂直同期は切る
#   make check … 型検査だけ走らせる
# 結果の読み方と基準は RESULTS.md。ブラウザ版は engine の根で make bench-web BENCH=sprite_stress ARGS='n=20000&tex=16'。

.PHONY: common-fresh run check bake-atlas run-px

run: common-fresh
	FLIX_GE_NO_VSYNC=1 FLIX_GE_MUTE=1 ../../bin/flix run

check: common-fresh
	../../bin/flix check

# R2b: PxSprite box 列 vs 1 クアッドの A/B (BenchPx)
bake-atlas:
	../../bin/flix run --entrypoint BenchPx.bakeAtlas

run-px: bake-atlas
	../../bin/flix run --entrypoint BenchPx.bench

# src の BenchRun.flix・BenchEnv.flix は bench/common の写し。食い違ったまま測らない。
common-fresh:
	@for f in BenchRun.flix BenchEnv.flix; do cmp -s ../common/$$f src/$$f || { echo "src/$$f が bench/common と違う。engine の根で make bench-common"; exit 1; }; done
