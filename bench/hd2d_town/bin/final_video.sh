#!/bin/bash
# 通しの台本（assets/final.json）の全部のコマを GPU（GL）で 64 コマずつ撮り、最終動画と確かめの絵にする:
#   debug/hd2d_town_final.mp4（30 fps・crf 20・1280×720）・debug/hd2d_town_final_sheet.png（1 秒ごとのコマ）・
#   debug/hd2d_town_final_flash.png（白飛びの境目ごとに、白くなる前・真っ白・消えた後の 3 コマ）
# usage: bin/final_video.sh   （KEEP=1 で撮ったコマを残したまま、無いコマだけ撮り直す）
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
export FLIX_GE_BACKEND=gl
out=debug/final_gpu_frames
total=$(python3 -c 'import json; print(sum(s["frames"] for s in json.load(open("assets/final.json"))["scenes"]))')
starts=$(python3 -c '
import json
d = json.load(open("assets/final.json")); a = 0
for s in d["scenes"][:-1]:
    a += s["frames"]; print(a)')
[ "${KEEP:-0}" = 1 ] || rm -rf "$out"
mkdir -p "$out"
for from in $(seq 0 64 $((total - 1))); do
  last=$((from + 64)); [ "$last" -gt "$total" ] && last=$total
  [ -f "$out/$(printf 'f%04d.png' "$last")" ] && continue
  tmp=debug/gpu_batch
  LIMIT=300 HD2D_FRAME_FROM=$from bin/gpu_run.sh final "$tmp" 2>&1 | tail -1
  n=$(ls "$tmp"/frame-*.png 2>/dev/null | wc -l | tr -d ' ')
  for k in $(seq 1 "$n"); do
    f=$((from + k))
    [ "$f" -le "$total" ] && mv "$tmp/frame-$k.png" "$out/$(printf 'f%04d.png' "$f")"
  done
  echo "[final_video] $from から $n コマ"
done
got=$(ls "$out"/f*.png | wc -l | tr -d ' ')
echo "[final_video] コマ $got / $total・残った TownGpu: $(pgrep -f TownGpu | wc -l | tr -d ' ')"
ffmpeg -v error -y -framerate 30 -i "$out/f%04d.png" -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart debug/hd2d_town_final.mp4
secs=$(( (total + 29) / 30 ))
rows=$(( (secs + 7) / 8 ))
ffmpeg -v error -y -i debug/hd2d_town_final.mp4 -vf "fps=1,scale=320:180,tile=8x${rows}" -frames:v 1 debug/hd2d_town_final_sheet.png
inputs=(); filters=""; i=0
for b in $starts; do
  for f in $((b - 30)) $b $((b + 1)) $((b + 40)); do
    inputs+=(-i "$out/$(printf 'f%04d.png' "$f")")
    filters="${filters}[$i]scale=480:270[s$i];"; i=$((i + 1))
  done
done
rowsf=""; r=0
for b in $starts; do
  k=$((r * 4)); filters="${filters}[s$k][s$((k + 1))][s$((k + 2))][s$((k + 3))]hstack=4[r$r];"; rowsf="${rowsf}[r$r]"; r=$((r + 1))
done
ffmpeg -v error -y "${inputs[@]}" -filter_complex "${filters}${rowsf}vstack=$r" debug/hd2d_town_final_flash.png
ls -la debug/hd2d_town_final.mp4 debug/hd2d_town_final_sheet.png debug/hd2d_town_final_flash.png
