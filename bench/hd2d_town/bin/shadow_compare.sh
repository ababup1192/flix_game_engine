#!/bin/bash
# 影の案を、止まっている所（静止画）と歩いている所（動画）で横に並べる（左上に案の名前・下に 1 行で濃さと大きさ）。
# usage: bin/shadow_compare.sh <出す名前> "<下の 1 行>" <案>:<ラベル> ...（案は debug/shadow_<案>/ のコマ）
set -euo pipefail
cd "$(dirname "$0")/../debug" || exit 1
name=$1; line=$2; shift 2
JF="/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"
k=0; still_in=(); walk_in=(); still_f=""; walk_f=""; pads=""
for pair in "$@"; do
  v=${pair%%:*}; lab=${pair#*:}
  still_in+=(-i "shadow_$v/f0860.png")
  walk_in+=(-framerate 30 -start_number 491 -i "shadow_$v/f%04d.png")
  still_f+="[$k]crop=360:240:460:200,scale=720:480:flags=neighbor,drawtext=fontfile='$JF':text='$lab':x=16:y=14:fontsize=36:fontcolor=white:box=1:boxcolor=black@0.65:boxborderw=10[s$k];"
  walk_f+="[$k]crop=480:320:400:200,scale=720:480:flags=neighbor,drawtext=fontfile='$JF':text='$lab':x=16:y=14:fontsize=36:fontcolor=white:box=1:boxcolor=black@0.65:boxborderw=10[s$k];"
  pads+="[s$k]"
  k=$((k + 1))
done
tail="${pads}hstack=inputs=$k,pad=iw:ih+70:0:0:color=0x202020,drawtext=fontfile='$JF':text='$line':x=20:y=h-50:fontsize=24:fontcolor=white"
ffmpeg -v error -y "${still_in[@]}" -filter_complex "${still_f}${tail}" "${name}.png"
ffmpeg -v error -y "${walk_in[@]}" -filter_complex "${walk_f}${tail}" -frames:v 64 -c:v libx264 -pix_fmt yuv420p -crf 20 "${name}.mp4"
echo "debug/${name}.png debug/${name}.mp4"
