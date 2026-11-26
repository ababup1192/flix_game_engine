#!/bin/bash
# 群れの測り（ブラウザ）: engine の fge.webgpu（render_gl/java）と BrowserWebGpu（engine_web/java）を一緒に TeaVM 0.16.0 で wasm にし、
# bin/fge web-bench でヘッドレスの Chrome に流す。TeaVM の jar は export-web が置く置き場を読む（取りに行かない）。
# usage: plans/compute-spike/web/flock.sh [web-bench の旗…]
set -e
D=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$D/../../.." && pwd)
export PATH="${DEVBOX_BIN:-$(cd "$(dirname "$0")/../../.." && pwd)/.devbox/nix/profile/default/bin}:$PATH"
T=${FLIX_GE_TEAVM_DIR:-$HOME/Library/Caches/flix_game_engine/teavm/0.16.0}
TCP=$(ls "$T"/*.jar | tr '\n' ':')
OUT="$D/out/flock"
rm -rf "$OUT" && mkdir -p "$OUT/classes" "$OUT/tools" "$OUT/site"
javac -nowarn --release 21 -d "$OUT/classes" -cp "$TCP" \
  "$ROOT"/render_gl/java/fge/webgpu/*.java "$ROOT"/engine_web/java/fge/web/webgpu/*.java \
  "$D/../desktop/src/FlockKernels.java" "$D/../desktop/src/FlockState.java" "$D/src/FlockBenchWeb.java"
javac -nowarn -d "$OUT/tools" -cp "$TCP" "$D/tools/BuildSpikeWasm.java"
java -cp "$OUT/tools:$TCP:$OUT/classes" BuildSpikeWasm FlockBenchWeb "$OUT/site" classes.wasm
unzip -p "$T/teavm-core-0.16.0.jar" org/teavm/backend/wasm/wasm-gc-runtime.js > "$OUT/site/wasm-gc-runtime.js"
cp "$D/index.html" "$OUT/site/"
"$ROOT/bin/fge" web-bench "$OUT/site" --wait 180 "$@"
