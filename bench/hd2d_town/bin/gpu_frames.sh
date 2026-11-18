#!/bin/bash
# 町が出来ていく動画の全部のコマを GPU で撮る（1 回の起動で 64 コマずつ・起動ごとに頭のコマを替える）→ debug/gpu_build_frames/f0001.png …
# usage: bin/gpu_frames.sh <全部のコマ数> [build|walk|final] [出力のフォルダ]   （FIRST = 撮り始める頭のコマ・既定 0）
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
total=$1
mode=${2:-build}
out=${3:-debug/gpu_build_frames}
mkdir -p "$out"
for from in $(seq "${FIRST:-0}" 64 $((total - 1))); do
  tmp=debug/gpu_batch
  LIMIT=300 HD2D_FRAME_FROM=$from bin/gpu_run.sh "$mode" "$tmp" 2>&1 | tail -1
  n=$(ls "$tmp"/frame-*.png 2>/dev/null | wc -l | tr -d ' ')
  for k in $(seq 1 "$n"); do
    f=$((from + k))
    [ "$f" -le "$total" ] && mv "$tmp/frame-$k.png" "$out/$(printf 'f%04d.png' "$f")"
  done
  echo "[gpu_frames] $from から $n コマ"
done
ls "$out" | wc -l
