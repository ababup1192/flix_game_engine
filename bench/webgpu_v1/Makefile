# webgpu_v1 — WebGPU の 2D の描き手（RenderPaint.Internal.WebGpuPaint）を、ウィンドウを開かずに GL の描き手（GlOffscreen）と画素で比べる門。
# 同じ場面（src/Scenes.flix）を両方で 1 コマずつ描き、場面ごとに違う画素の数と成分の差の最大を出す。許す差は tolerance.tsv（既定は 0）。
# 1 つでも許す差を超えるか、WebGPU の誤りの数が 0 でないか、submit の数が場面の期待と違えば exit 1。GPU が要るので CI には載せない（webgpu-check と同じ）。
#   make run    … 門（描いた絵は debug/gl・debug/webgpu・差は debug/diff）
#   make check  … 型検査だけ
# 先にエンジンの root で make sync-engine-full（engine_full/src の symlink 集と、Dawn のネイティブを持つ engine_full/flix.toml を使う）。
#
# WhyNot: engine を fpkg の依存（mount = "fge"）で組まない — RenderPaint は pub でない mod で、その子の RenderPaint.Internal.WebGpuPaint は
#   別のパッケージから見えない。engine の pub を増やさずに呼ぶため、engine_full/src と src/ を 1 つのパッケージの木（build/tree）に束ねて組む。
# WhyNot: 木の中で flix run しない — 作業フォルダが木になり、project.json の絵の道と tolerance.tsv をこのフォルダから読めない。fat jar をここで起こす。

.PHONY: run check tree

TREE := build/tree
JAR := $(TREE)/artifact/tree.jar
FLIX := $(CURDIR)/../../bin/flix
# WhyNot: LWJGL の置き場を既定のままにしない — fat jar から起こすと LWJGL が版を読めず、作業フォルダの .lwjgl へ書き出す。
JAVA_OPTS := -Dorg.lwjgl.system.SharedLibraryExtractDirectory=$(CURDIR)/build/lwjgl --enable-native-access=ALL-UNNAMED

# WhyNot: フォルダごとに symlink を張らない — flix はフォルダの symlink の中を探さず、何も組まずに緑を返す。ファイルごとに張る。
tree:
	@rm -rf $(TREE)/src && mkdir -p $(TREE)/src $(TREE)/lib/external build
	@for pair in engine:../../engine_full/src bench:src; do role=$${pair%%:*}; root=$${pair#*:}; \
		(cd "$$root" && find . -name '*.flix') | sed 's|^\./||' | while read -r f; do \
			dest="$(TREE)/src/$$role/$$f"; mkdir -p "$$(dirname "$$dest")"; \
			ln -sfn "$(CURDIR)/$$root/$$f" "$$dest"; \
		done; \
	done
	@grep -v '^repository' ../../engine_full/flix.toml > $(TREE)/flix.toml
	@[ -d $(TREE)/lib/cache ] || { [ -d ../../engine_full/lib/cache ] && cp -R ../../engine_full/lib/cache $(TREE)/lib/; } || true
	@[ -d ../webgpu_check/lib/cache ] && cp -Rn ../webgpu_check/lib/cache/ $(TREE)/lib/cache/ 2>/dev/null || true
	@cp -n ../../engine_full/lib/external/* $(TREE)/lib/external/ 2>/dev/null || true

run: tree
	cd $(TREE) && "$(FLIX)" build-fatjar
	java $(JAVA_OPTS) -jar $(JAR)

check: tree
	cd $(TREE) && "$(FLIX)" check
