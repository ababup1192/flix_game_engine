# physics2d — 2D の剛体の物理（PhysicsWorld2d）の重さと指紋。場面と予算は src/PhysicsBench.flix の頭。
#   make run    … 窓を開かずに場面を 3 回流し、場面ごとに 1 行の JSON（1 刻みの平均 ms・起きている体・指紋）を出す
#   make check  … 型検査だけ
# ブラウザ版は engine の根で make bench-web BENCH=physics2d CPU=4（指紋が PC と同じかも見る）。先に engine の根で make sync-engine-full。

.PHONY: run check

run:
	../../bin/flix run

check:
	../../bin/flix check
