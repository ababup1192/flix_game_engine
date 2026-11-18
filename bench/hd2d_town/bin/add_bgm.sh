#!/bin/bash
# 動画に BGM を頭から重ねる（頭 0.5 秒で入り、終わり 3 秒で消す・ピークが −1 dB 前後になるよう（aac で 0.2 dB ほど上がるので −1.2 dB を狙う）音量を合わせる）。
# 曲が無ければ音なしのまま写して 1 行言う（曲は素材の再配布になるので git に入れず、置き場を BGM で受ける）。
# usage: bin/add_bgm.sh <入力の mp4> <出力の mp4> <曲のファイル>
set -uo pipefail
in=$1; out=$2; bgm=$3
if [ ! -f "$bgm" ]; then
  cp "$in" "$out"
  echo "[add_bgm] BGM が無いので音なしで作った（BGM=… で指定）: $bgm"
  exit 0
fi
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$in")
fade=$(echo "$dur - 3" | bc -l)
shape="atrim=0:${dur},afade=t=in:st=0:d=0.5,afade=t=out:st=${fade}:d=3"
peak=$(ffmpeg -hide_banner -i "$bgm" -af "${shape},volumedetect" -f null - 2>&1 | sed -n 's/.*max_volume: \(-*[0-9.]*\) dB.*/\1/p')
gain=$(echo "-1.2 - (${peak:-0})" | bc -l)
ffmpeg -v error -y -i "$in" -i "$bgm" -filter_complex "[1:a]${shape},volume=${gain}dB[a]" -map 0:v -map "[a]" \
  -c:v copy -c:a aac -b:a 192k -t "$dur" -movflags +faststart "$out"
after=$(ffmpeg -hide_banner -i "$out" -map 0:a -af volumedetect -f null - 2>&1 | sed -n 's/.*max_volume: \(-*[0-9.]*\) dB.*/\1/p')
echo "[add_bgm] $out（曲のピーク ${peak} dB → 音量 ${gain} dB を足した・できた動画の音のピーク ${after} dB）"
