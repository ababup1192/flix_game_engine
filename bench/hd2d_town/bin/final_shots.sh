#!/bin/bash
# 人が決めた物（長い人形の影・3 人目の女の子・息遣いのコマ・夜の霧 中・夜の板の明るさ）で撮り直す:
# 出来ていく動画（昼）と、夜（霧 中）の出来上がった町を歩いて止まる 10 秒（出来ていく台本のコマ 591〜889）。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
rm -rf debug/gpu_build_frames
bin/gpu_frames.sh 889 | tail -1
make buildup-video | tail -1
out=debug/gpu_night_walk_frames
rm -rf "$out"; mkdir -p "$out"
for from in 590 654 718 782 846; do
  LOOK=assets/town_night_fog_mid.json LIMIT=300 HD2D_FRAME_FROM=$from bin/gpu_run.sh build debug/gpu_batch | tail -1
  n=$(ls debug/gpu_batch/frame-*.png 2>/dev/null | wc -l | tr -d ' ')
  for k in $(seq 1 "$n"); do f=$((from + k)); [ "$f" -le 889 ] && mv "debug/gpu_batch/frame-$k.png" "$out/$(printf 'f%04d.png' "$f")"; done
done
ffmpeg -v error -y -framerate 30 -start_number 591 -i "$out/f%04d.png" -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart debug/hd2d_town_night_fog_mid_walk.mp4
echo done
