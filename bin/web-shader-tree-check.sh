#!/bin/bash
# ブラウザ版の wasm に、3D のシェーダーの字を作るコード（ShaderAst の木と printer・Render3dShaders・光の式の Codegen）が 1 本も無いか。
# 使い方: bin/web-shader-tree-check.sh <名前> <書き出したフォルダ>
#   どれかの関数が残っていれば exit 1（書き出しは字を表で埋めるので、ブラウザの描き手は字を作るコードを辿らない）。
# WhyNot: 大きさの門（web-size-check）に任せない — 数 KB ずつ戻る漏れは +3% の内に隠れ、気づいた時には上限まで太っている。
set -euo pipefail
name="$1"; dir="$2"
fge="$(dirname "$0")/fge"
found=$("$fge" wasm-size "$dir" --by module | awk '{ print $2 }' | grep -E '^(ShaderAst|Render3dShaders|LightModel3d\.Codegen|LightModel3d\.PointShadowCodegen)' || true)
if [ -n "$found" ]; then
  echo "[web-shader-tree] $name: wasm に字を作るコードが残っている: $(echo "$found" | tr '\n' ' ')"
  echo "  次: ブラウザの束から Render3dShaders.makeRuntimeProvider・Render3d.makeRenderer・Render3dGlsl/Render3dWgsl の字の関数を辿る所を探す（bin/fge wasm-size $dir --by name --grep <名前>）"
  exit 1
fi
echo "[web-shader-tree] $name: 字を作るコードの関数 0 本"
