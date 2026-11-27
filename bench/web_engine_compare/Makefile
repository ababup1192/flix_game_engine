# web_engine_compare — 比べる相手のベンチ（WebGPU Engine Bench の 9 場面）を engine のブラウザ版で同じ条件で測る。計画は plans/engine-web-bench.md（git の外）。
#   make check          … 型検査だけ（この場面の app と、配る大きさを測る 2 つの app）
#   make test           … Rng・Geometry・Scenes のテスト
#   make upstream       … 比べる相手のリポを harness/upstream.sha で build/upstream へ取り、npm ci と素材を取る（git の外・Sponza は CRYENGINE のライセンスなので配らない）
#   make upstream-quick … 比べる相手の 6 つの adapter を Chrome の WebGPU と WebGL2 で quick（1 回）で回す（結果は build/upstream/results/<session>）
#   make compare ONLY='engine=flix,three;scenario=k1' [PROFILE=smoke|quick|full] … 比べる相手の harness に flix の adapter を足して回す
#                       （patch を当て・本番で書き出して public/flix へ写す・結果は build/upstream/results/<session>）。engine の根の make web-engine-compare は同じ物
#   make k4-export      … K4 の Sponza（比べる相手の .gltf を harness/pack-glb.mjs で glb にまとめ直す）を入れた別の書き出しを public/flix-k4 へ（make compare が ONLY に k4 がある時に流す）
#   make compare-table [SESSION=<session>] … 回した結果から README の行の表（flix の CPU は場面の更新を差し引いた値）
#   make scene-compare… Flix の場面（SceneDump）と比べる相手の buildScene の値を比べる（Float32 で相対 1e-5・整数は完全一致）
#   make compare-assets … K6 の狐（Fox.glb・CC-BY）・K9 の字（Roboto・Apache-2.0）と icon の atlas（比べる相手の canvas が描く物の PNG）を assets/ へ置く（git の外。make compare が先に流す・make bench-web の前にも要る）
#   make footprint      … ../web_engine_compare_minimal（光の当たる箱）と ../web_engine_compare_featured（glTF・骨・影・bloom）を本番で書き出し、配る大きさ（brotli・quality 11）を出す
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
MINIMAL   := ../web_engine_compare_minimal
FEATURED  := ../web_engine_compare_featured

.PHONY: k4-export compare-assets compare compare-setup compare-table check test upstream upstream-quick scene-compare footprint footprint-export featured-assets spike common-fresh

check: common-fresh
	$(FLIX) check
	cd $(MINIMAL) && $(FLIX) check
	cd $(FEATURED) && $(FLIX) check

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
	@mkdir -p $(FEATURED)/assets
	cp $(UPSTREAM)/public/assets/Fox/Fox.glb $(FEATURED)/assets/Fox.glb

footprint-export: featured-assets
	$(FGE) export-web $(MINIMAL) --out $(CURDIR)/build/footprint/minimal
	$(FGE) export-web $(FEATURED) --out $(CURDIR)/build/footprint/featured

footprint: footprint-export
	$(NODE) harness/footprint.mjs build/footprint/minimal build/footprint/featured

spike:
	@test -f build/footprint/minimal/classes.wasm || $(FGE) export-web $(MINIMAL) --out $(CURDIR)/build/footprint/minimal
	$(NODE) harness/spike/run-spike.mjs build/footprint/minimal

compare-assets:
	@test -f $(UPSTREAM)/public/assets/fonts/Roboto-Regular.ttf || { echo "Roboto が無い。先に make upstream"; exit 1; }
	@mkdir -p assets
	cp $(UPSTREAM)/public/assets/fonts/Roboto-Regular.ttf assets/Roboto-Regular.ttf
	cp $(UPSTREAM)/public/assets/Fox/Fox.glb assets/Fox.glb
	@test -f assets/hud-atlas.png || $(NODE) harness/hud-atlas.mjs $(UPSTREAM) assets/hud-atlas.png

# 当たっていれば（逆に当てられれば）飛ばす。2 回当てると git apply が止まる。
compare-setup: compare-assets
	@test -d $(UPSTREAM)/node_modules || { echo "比べる相手のリポが無い。先に make upstream"; exit 1; }
	cd $(UPSTREAM) && (git apply --reverse --check ../../harness/upstream.patch 2>/dev/null || git apply ../../harness/upstream.patch)
	@mkdir -p $(UPSTREAM)/src/engines/flix $(UPSTREAM)/public/flix
	cp harness/flix-adapter.ts $(UPSTREAM)/src/engines/flix/index.ts
	$(FGE) export-web . --out $(CURDIR)/build/web-flix
	cp -R build/web-flix/. $(UPSTREAM)/public/flix/
	$(NODE) -e "$$RAW_WASM" $(UPSTREAM)/public/flix/bundle.json
	$(if $(K4_NEEDED),$(MAKE) --no-print-directory k4-export)

# 比べる相手の dev サーバーは .br を Content-Encoding: br で配らない。他の engine と同じく生のまま読む道（compileStreaming）にする（計画の 4.1）。
define RAW_WASM
const f = process.argv[1], fs = require('fs'), b = JSON.parse(fs.readFileSync(f, 'utf8')); delete b.wasmBrotli; fs.writeFileSync(f, JSON.stringify(b));
endef
export RAW_WASM

# K4 の Sponza（約 53 MB）は別の書き出しに入れる。
# WhyNot: assets/ に置いて 1 つの書き出しにしない — 書き出しの素材は起動で全部取るので、K1 の TTFF まで Sponza を取る時間が乗る。
# 場面で絞らない時（ONLY に scenario= が無い）も K4 は回るので書き出す。
K4_NEEDED := $(if $(findstring scenario=,$(ONLY)),$(findstring k4,$(ONLY)),k4)
K4_GAME := build/k4-game
k4-export: compare-assets
	@test -f build/sponza/Sponza.glb || $(NODE) harness/pack-glb.mjs $(UPSTREAM)/public/assets/Sponza/Sponza.gltf build/sponza/Sponza.glb
	@rm -rf $(K4_GAME) && mkdir -p $(K4_GAME)
	rsync -a src web flix.toml packages.lock project.json lib assets $(K4_GAME)/
	cp build/sponza/Sponza.glb $(K4_GAME)/assets/Sponza.glb
	$(FGE) export-web $(K4_GAME) --out $(CURDIR)/build/web-flix-k4
	@mkdir -p $(UPSTREAM)/public/flix-k4
	cp -R build/web-flix-k4/. $(UPSTREAM)/public/flix-k4/
	$(NODE) -e "$$RAW_WASM" $(UPSTREAM)/public/flix-k4/bundle.json

PROFILE ?= smoke
compare: compare-setup
	cd $(UPSTREAM) && PATH=$(NODE_PATH_DIR):$$PATH npm run bench -- --browser chrome --profile $(PROFILE) $(if $(ONLY),--only "$(ONLY)")

compare-table:
	cd $(UPSTREAM) && PATH=$(NODE_PATH_DIR):$$PATH npm run report -- --sessions $${SESSION:-$$(/bin/ls -t results | grep -v smoke | head -1)} > /dev/null
	cd $(UPSTREAM) && PATH=$(NODE_PATH_DIR):$$PATH npx tsx ../../harness/table.ts webgpu
	cd $(UPSTREAM) && PATH=$(NODE_PATH_DIR):$$PATH npx tsx ../../harness/table.ts webgl2
