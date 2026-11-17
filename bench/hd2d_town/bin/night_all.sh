#!/bin/bash
# 夜と霧の撮りと計測をまとめて流す（GPU・隠しウィンドウ）: 歩いて止まる場面を 霧なし・中・強 で撮り、重さを点光源の数と霧で分けて測る。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
for v in night night_fog_mid night_fog_strong; do
  rm -rf "debug/gpu_${v}_frames"
  LOOK=assets/town_$v.json bin/gpu_frames.sh 279 walk "debug/gpu_${v}_frames" | tail -1
  ffmpeg -v error -y -framerate 30 -i "debug/gpu_${v}_frames/f%04d.png" -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart "debug/hd2d_town_${v}_walk.mp4"
done
rm -f debug/gpu_night_bench.log
for v in night night_fog_mid night_fog_strong; do
  for extra in 0 18; do
    LOOK=assets/town_$v.json EXTRA_LAMPS=$extra LIMIT=300 bin/gpu_run.sh bench "debug/gpu_bench_${v}_$extra.log" | tail -1
    grep '\[bench\] result' "debug/gpu_bench_${v}_$extra.log" >> debug/gpu_night_bench.log
  done
done
echo done
