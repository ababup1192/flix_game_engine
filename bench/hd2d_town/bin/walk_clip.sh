#!/bin/bash
# 地図の walk.path で歩く場面の一部（コマ FIRST から LAST まで）を GPU（GL）で撮る → <出力のフォルダ>/fNNNN.png（場面のコマ番号・1 から）。
# 前後を並べる動画（陽炎・火の粉・雪と空気の直しの前と後）の材料。
# usage: bin/walk_clip.sh <地図の Doc> <Look の Doc> <出力のフォルダ>   （FIRST・LAST = 撮るコマ・既定 64 と 192）
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
map=$1; look=$2; out=$3
first=${FIRST:-64}; last=${LAST:-192}
export FLIX_GE_BACKEND=gl
rm -rf "$out"
WALK_MAP=$map LOOK=$look FIRST=$first bin/gpu_frames.sh "$last" build "$out" | tail -1
echo "[walk_clip] $out・残った TownGpu: $(pgrep -f TownGpu | wc -l | tr -d ' ')"
