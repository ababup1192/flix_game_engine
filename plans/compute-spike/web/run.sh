#!/bin/bash
# ブラウザの compute スパイク: TeaVM 0.16.0（export-web と同じ版・同じ WasmGC の設定）で wasm にして、bin/fge web-bench でヘッドレスの Chrome に流す。
# TeaVM の jar は export-web が置く ~/Library/Caches/flix_game_engine/teavm/0.16.0 を読む（取りに行かない。無ければ一度 export-web を流す）。
# usage: plans/compute-spike/web/run.sh [web-bench の旗…]
set -e
D=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$D/../../.." && pwd)
export PATH=/Users/abab/Desktop/flix_game_engine/.devbox/nix/profile/default/bin:$PATH
T=${FLIX_GE_TEAVM_DIR:-$HOME/Library/Caches/flix_game_engine/teavm/0.16.0}
TCP=$(ls "$T"/*.jar | tr '\n' ':')
OUT="$D/out"
rm -rf "$OUT" && mkdir -p "$OUT/classes" "$OUT/tools" "$OUT/site"
javac -nowarn --release 21 -d "$OUT/classes" -cp "$TCP" "$D/src/ComputeSpikeWeb.java"
javac -nowarn -d "$OUT/tools" -cp "$TCP" "$D/tools/BuildSpikeWasm.java"
java -cp "$OUT/tools:$TCP:$OUT/classes" BuildSpikeWasm ComputeSpikeWeb "$OUT/site" classes.wasm
ls "$OUT/site"
unzip -p "$T/teavm-core-0.16.0.jar" org/teavm/backend/wasm/wasm-gc-runtime.js > "$OUT/site/wasm-gc-runtime.js"
cp "$D/index.html" "$OUT/site/"
"$ROOT/bin/fge" web-bench "$OUT/site" --wait 120 "$@"
