# web_engine_compare — 比べる相手のベンチ（WebGPU Engine Bench の 9 場面）を engine のブラウザ版で同じ条件で測る。計画は plans/engine-web-bench.md（git の外）。
#   make check          … 型検査だけ（この場面の app と、配る大きさを測る 2 つの app）
#   make test           … Rng・Geometry・Scenes のテスト
#   make upstream       … 比べる相手のリポを harness/upstream.sha で build/upstream へ取り、npm ci と素材を取る（git の外・Sponza は CRYENGINE のライセンスなので配らない）
#   make upstream-quick … 比べる相手の 6 つの adapter を Chrome の WebGPU と WebGL2 で quick（1 回）で回す（結果は build/upstream/results/<session>）
#   make scene-compare  … Flix の場面（SceneDump）と比べる相手の buildScene の値を比べる（Float32 で相対 1e-5・整数は完全一致）
#   make footprint      … ../web_engine_compare_footprint の minimal（光の当たる箱）と featured（glTF・骨・影・bloom）を本番で書き出し、配る大きさ（brotli・quality 11）を出す
#   make spike          … X1 案 c のスパイク（minimal を書き出した頁で rAF を包み、外から 1 コマずつ回して submit まで戻るかを数える）
# ブラウザ版の測り（engine の口）は engine の根で make bench-web BENCH=web_engine_compare ARGS='scenario=k2&level=4000'。
# WhyNot: 比べる相手のリポと配る大きさの app をこのフォルダの下（build/ 以外）に置かない — export-web がゲームの根の下を丸ごと写す（写さないのは根の直下の build・lib など）。
# node は PATH の物か NODE（devbox の nix の nodejs）。

ROOT      := ../..
FLIX      := $(ROOT)/bin/flix
FGE       := $(ROOT)/bin/fge
NODE      ?= $(shell command -v node 2>/dev/null || ls -d /nix/store/*-nodejs-24.*/bin/node 2>/dev/null | head -1)
NODE_PATH_DIR := $(dir $(NODE))
UPSTREAM  := build/upstream
FOOTPRINT := ../web_engine_compare_footprint

.PHONY: check test upstream upstream-quick scene-compare footprint footprint-export featured-assets spike common-fresh

check: common-fresh
	$(FLIX) check
	cd $(FOOTPRINT)/minimal && ../../$(FLIX) check
	cd $(FOOTPRINT)/featured && ../../$(FLIX) check

test: common-fresh
	$(FLIX) test

# src の BenchRun.flix・BenchEnv.flix は bench/common の写し。食い違ったまま測らない。
common-fresh:
	@for f in BenchRun.flix BenchEnv.flix; do cmp -s ../common/$$f src/$$f || { echo "src/$$f が bench/common と違う。engine の根で make bench-common"; exit 1; }; done

upstream:
	@if [ ! -d $(UPSTREAM)/.git ]; then git clone -q https://github.com/endel/webgpu-webgl-benchmarks $(UPSTREAM); fi
	cd $(UPSTREAM) && git fetch -q origin && git checkout -q $$(cat ../../harness/upstream.sha)
	cd $(UPSTREAM) && PATH=$(NODE_PATH_DIR):$$PATH npm ci --no-audit --no-fund && PATH=$(NODE_PATH_DIR):$$PATH npm run fetch-assets

upstream-quick:
	cd $(UPSTREAM) && PATH=$(NODE_PATH_DIR):$$PATH npm run bench -- --browser chrome --profile quick $(if $(ONLY),--only "$(ONLY)")

scene-compare:
	@mkdir -p build
	$(FLIX) run --entrypoint SceneDump.write | grep '^{' > build/scene-dump.jsonl
	cd $(UPSTREAM) && PATH=$(NODE_PATH_DIR):$$PATH npx tsx ../../harness/compare-scenes.ts ../scene-dump.jsonl

featured-assets:
	@test -f $(UPSTREAM)/public/assets/Fox/Fox.glb || { echo "Fox.glb が無い。先に make upstream"; exit 1; }
	@mkdir -p $(FOOTPRINT)/featured/assets
	cp $(UPSTREAM)/public/assets/Fox/Fox.glb $(FOOTPRINT)/featured/assets/Fox.glb

footprint-export: featured-assets
	$(FGE) export-web $(FOOTPRINT)/minimal --out $(CURDIR)/build/footprint/minimal
	$(FGE) export-web $(FOOTPRINT)/featured --out $(CURDIR)/build/footprint/featured

footprint: footprint-export
	$(NODE) harness/footprint.mjs build/footprint/minimal build/footprint/featured

spike:
	@test -f build/footprint/minimal/classes.wasm || $(FGE) export-web $(FOOTPRINT)/minimal --out $(CURDIR)/build/footprint/minimal
	$(NODE) harness/spike/run-spike.mjs build/footprint/minimal
