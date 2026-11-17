#!/bin/bash
# 前・後・Blender の 3 枚を、日本語の大きなラベルつきで横に並べ、下に 1 行の説明を付ける。
# usage: bin/three_up.sh <前の PNG> <後の PNG> <Blender の PNG> <出す PNG> "<下の 1 行>"
set -euo pipefail
JF="/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"
lab() { echo "scale=960:540,drawtext=fontfile='$JF':text='$1':x=18:y=16:fontsize=44:fontcolor=white:box=1:boxcolor=black@0.65:boxborderw=12"; }
ffmpeg -v error -y -i "$1" -i "$2" -i "$3" -filter_complex \
  "[0]$(lab '前')[a];[1]$(lab '後')[b];[2]$(lab 'Blender の試作')[c];[a][b][c]hstack=inputs=3,pad=iw:ih+90:0:0:color=0x202020,drawtext=fontfile='$JF':text='$5':x=24:y=h-66:fontsize=27:fontcolor=white" \
  "$4"
echo "$4"
