#!/bin/bash
# コマのフォルダを横に並べた短い動画（隊列のまわりを切り抜き・左上に日本語のラベル）。
# usage: bin/side_by_side.sh <出す mp4> <頭のコマ番号> <コマ数> <フォルダ>:<ラベル> ...（フォルダは debug/ からの相対）
set -euo pipefail
cd "$(dirname "$0")/../debug" || exit 1
out=$1; start=$2; count=$3; shift 3
JF="/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"
CROP=${CROP:-320:300:480:180}
ins=(); f=""; pads=""; k=0
for pair in "$@"; do
  dir=${pair%%:*}; lab=${pair#*:}
  ins+=(-framerate 30 -start_number "$start" -i "$dir/f%04d.png")
  f+="[$k]crop=$CROP,scale=iw*2:ih*2:flags=neighbor,drawtext=fontfile='$JF':text='$lab':x=14:y=14:fontsize=34:fontcolor=white:box=1:boxcolor=black@0.65:boxborderw=10[v$k];"
  pads+="[v$k]"; k=$((k + 1))
done
ffmpeg -v error -y "${ins[@]}" -filter_complex "${f}${pads}hstack=inputs=$k" -frames:v "$count" -c:v libx264 -pix_fmt yuv420p -crf 20 "$out"
echo "debug/$out"
