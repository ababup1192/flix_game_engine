#!/bin/bash
# 人が決めた影（長い人形の影）と夜の板の明るさで撮り直す: 影の前後の比べ・出来ていく動画・夜（霧 中）の歩く動画。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
[ -d debug/shadow_silhouette55 ] || mv debug/shadow_silhouette debug/shadow_silhouette55
bin/shadow_shots.sh silhouette | tail -1
bin/shadow_compare.sh char_shadow_long "前＝太陽 55°（影は背の 0.7 倍） ／ 後＝太陽 40°（影は背の 1.2 倍・街灯と木と建物の影も同じ向きと長さで伸びる）・影の地図 4096・縁のならし 2" "silhouette55:前（太陽 55°）" "silhouette:後（太陽 40°・長い影）"
rm -rf debug/gpu_build_frames
bin/gpu_frames.sh 889 | tail -1
make buildup-video | tail -1
rm -rf debug/gpu_night_fog_mid_frames
LOOK=assets/town_night_fog_mid.json bin/gpu_frames.sh 279 walk debug/gpu_night_fog_mid_frames | tail -1
ffmpeg -v error -y -framerate 30 -i debug/gpu_night_fog_mid_frames/f%04d.png -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart debug/hd2d_town_night_fog_mid_walk.mp4
echo done
