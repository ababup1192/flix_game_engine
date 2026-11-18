#!/bin/bash
# 町を北へ歩きながら時刻が替わる所（歩き出しから門の手前で止まって 1 秒まで）を GPU（GL）で撮り、動画と境目の前後のコマを並べた絵にする。
#   debug/timeofday_trans_<名前>.mp4・debug/timeofday_trans_<名前>_switch.png（境目の行 47・30・12.5 ごとに 1 段・前後 step コマおきに 7 コマ）
# usage: bin/timeofday_trans.sh <名前> <台本の Doc> <並べるコマの間>   （例: bin/timeofday_trans.sh A assets/buildup_center.json 3）
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
name=$1; plan=$2; step=$3
first=576; last=1095
out=debug/timeofday_trans_${name}_frames
export FLIX_GE_BACKEND=gl
rm -rf "$out"
BUILDUP=$plan FIRST=$first bin/gpu_frames.sh $last build "$out" | tail -1
echo "[timeofday_trans] 残った TownGpu: $(pgrep -f TownGpu | wc -l | tr -d ' ')"
ffmpeg -v error -y -framerate 30 -start_number $((first + 1)) -i "$out/f%04d.png" -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart "debug/timeofday_trans_${name}.mp4"
rows=$(BUILDUP=$plan ../../bin/flix run --entrypoint BuildVideo.leaderRows 2>/dev/null | grep '^row' | awk '{r=$3} prev>47 && r<=47 {print $2} prev>30 && r<=30 {print $2} prev>12.5 && r<=12.5 {print $2} {prev=r}')
inputs=(); filters=""; i=0; rowsf=""; r=0
for b in $rows; do
  line=""
  for k in -3 -2 -1 0 1 2 3; do
    inputs+=(-i "$out/$(printf 'f%04d.png' $((b + k * step)))")
    filters="${filters}[$i]scale=320:180[s$i];"; line="${line}[s$i]"; i=$((i + 1))
  done
  filters="${filters}${line}hstack=7[r$r];"; rowsf="${rowsf}[r$r]"; r=$((r + 1))
done
ffmpeg -v error -y "${inputs[@]}" -filter_complex "${filters}${rowsf}vstack=$r" "debug/timeofday_trans_${name}_switch.png"
echo "[timeofday_trans] 境目のコマ: $(echo $rows | tr '\n' ' ')"
ls -la "debug/timeofday_trans_${name}.mp4" "debug/timeofday_trans_${name}_switch.png"
