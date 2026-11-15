# webgpu_v2 — WebGPU の 3D の描き手（Render3d.WebGpuRenderer）を、ウィンドウを開かずに GL の描き手（GlOffscreen）と画素で比べ、1 コマの時間を同じ回で測る（V2）。
# 場面は bench/scene3d の部屋（Room.flix をそのまま使う）。960×540（design 320×180 の 3 倍）で GL と WebGPU の両方に 1 コマずつ描き、違う画素の数と成分の差の最大を出す。
# 許す差は src/Main.flix の tolerances。超えるか、WebGPU の誤りの数が 0 でなければ exit 1。GPU が要るので CI には載せない（webgpu-v1-check と同じ）。
# 1 コマの時間は GL（glFinish まで）・WebGPU（waitIdle まで）を交互に回して中央値を出す（門ではなく記録）。3D を 2D へ貼る 2 つの形（plans/engine-webgpu.md の 5.4）の
# 比べ（src/Render3d/WebGpuRenderer/SplitPassTrial.flix）も同じ回で流す。
#   make run    … 比べと時間（絵は debug/gl・debug/webgpu）
#   make check  … 型検査だけ
# 先にエンジンの root で make sync-engine-full。
#
# WhyNot: engine を fpkg の依存で組まない — Render3d.WebGpuRenderer と RenderPaint.Internal.WebGpuPaint は別のパッケージから見えない（bench/webgpu_v1 と同じ）。
# WhyNot: Room.flix を写さない — bench/scene3d の部屋と同じ物を描く事が比べの前提なので、木を組む時に `use fge::` を外して置く（木の中では engine が fge に載らない）。

.PHONY: run check tree

TREE := build/tree
JAR := $(TREE)/artifact/tree.jar
FLIX := $(CURDIR)/../../bin/flix
# WhyNot: LWJGL の置き場を既定のままにしない — fat jar から起こすと LWJGL が版を読めず、作業フォルダの .lwjgl へ書き出す。
JAVA_OPTS := -Dorg.lwjgl.system.SharedLibraryExtractDirectory=$(CURDIR)/build/lwjgl --enable-native-access=ALL-UNNAMED
V1_ASSETS := LwjglLayer/Internal/WebGpuWindowLayer/V1Assets.flix

# WhyNot: フォルダごとに symlink を張らない — flix はフォルダの symlink の中を探さず、何も組まずに緑を返す。ファイルごとに張る。
tree:
	@rm -rf $(TREE)/src && mkdir -p $(TREE)/src $(TREE)/lib/external build
	@for pair in engine:../../engine_full/src bench:src; do role=$${pair%%:*}; root=$${pair#*:}; \
		(cd "$$root" && find . -name '*.flix') | sed 's|^\./||' | while read -r f; do \
			dest="$(TREE)/src/$$role/$$f"; mkdir -p "$$(dirname "$$dest")"; \
			ln -sfn "$(CURDIR)/$$root/$$f" "$$dest"; \
		done; \
	done
	@mkdir -p "$(TREE)/src/bench/$$(dirname $(V1_ASSETS))" && ln -sfn "$(CURDIR)/../webgpu_v1/src/$(V1_ASSETS)" "$(TREE)/src/bench/$(V1_ASSETS)"
	@sed '/^    use fge::{/d' ../scene3d/src/Room.flix > $(TREE)/src/bench/Room.flix
	@grep -v '^repository' ../../engine_full/flix.toml > $(TREE)/flix.toml
	@[ -d $(TREE)/lib/cache ] || { [ -d ../../engine_full/lib/cache ] && cp -R ../../engine_full/lib/cache $(TREE)/lib/; } || true
	@[ -d ../webgpu_check/lib/cache ] && cp -Rn ../webgpu_check/lib/cache/ $(TREE)/lib/cache/ 2>/dev/null || true
	@cp -n ../../engine_full/lib/external/* $(TREE)/lib/external/ 2>/dev/null || true

run: tree
	cd $(TREE) && "$(FLIX)" build-fatjar
	java $(JAVA_OPTS) -jar $(JAR)

check: tree
	cd $(TREE) && "$(FLIX)" check
