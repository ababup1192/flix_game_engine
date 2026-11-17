#!/bin/bash
# キャラの影の案ごとに、止まっている所（コマ STILL_FROM から）と歩いている所（コマ WALK_FROM から 64 コマ）を GPU で撮る → debug/shadow_<案>/
# usage: bin/shadow_shots.sh <案>...（silhouette・soft・dense・denseCast・smallBlob）。SHADOW_MAP・SHADOW_PCF はそのまま通る
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
for v in "$@"; do
  out=debug/shadow_$v
  rm -rf "$out"; mkdir -p "$out"
  for from in ${STILL_FROM:-849} ${WALK_FROM:-490}; do
    CHAR_SHADOW=$v LIMIT=300 HD2D_FRAME_FROM=$from bin/gpu_run.sh build debug/gpu_batch 2>&1 | tail -1
    n=$(ls debug/gpu_batch/frame-*.png 2>/dev/null | wc -l | tr -d ' ')
    for k in $(seq 1 "$n"); do mv "debug/gpu_batch/frame-$k.png" "$out/$(printf 'f%04d.png' $((from + k)))"; done
  done
  echo "[shadow_shots] $v: $(ls "$out" | wc -l | tr -d ' ') コマ"
done
