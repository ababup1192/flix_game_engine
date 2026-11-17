#!/bin/bash
# GPU（隠しウィンドウ）で町を描く: build = 町が出来ていく動画のコマを <出力のフォルダ>/frame-N.png へ・bench = 1 コマの重さを測る。
# usage: bin/gpu_run.sh build|walk <出力のフォルダ> | bin/gpu_run.sh bench <ログ>（walk = 地図の walk の台本で歩いて止まる場面）   （環境変数 POST・SHADOW・FLIX_GE_BACKEND はそのまま通る）
# 起動した JVM はプロセスの組ごと PID で止め、ps で消えたのを確かめてから抜ける（窓を残さない）。上限 LIMIT 秒（既定 900）。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
mode=$1; out=$2
engine=$(cd ../.. && pwd)
limit=${LIMIT:-900}
"$engine/bin/headless-run" --build-only > /tmp/hd2d_gpu_build.log 2>&1 || { tail -20 /tmp/hd2d_gpu_build.log; exit 1; }
if [ "$mode" = build ] || [ "$mode" = walk ]; then
  rm -rf "$out"; mkdir -p "$out"
  export FLIX_GE_FRAME_SHOT="$out"
  log="$out/run.log"
else
  unset FLIX_GE_FRAME_SHOT
  log="$out"
fi
export FLIX_GE_HIDDEN=1 FLIX_GE_MUTE=1 FLIX_GE_FIXED_DT=0.03333333333333333 HD2D_MODE="$mode"
[ "$mode" = bench ] && { unset FLIX_GE_FIXED_DT; export FLIX_GE_NO_VSYNC=1; }
perl -e '
  my $limit = shift;
  my $pid = fork;
  if (!$pid) { setpgrp(0, 0); exec @ARGV; die "exec: $!" }
  print STDERR "[gpu_run] pid $pid\n";
  $SIG{INT} = $SIG{TERM} = sub { kill "TERM", -$pid; sleep 1; kill "KILL", -$pid; exit 130 };
  my $waited = 0;
  while ($waited < $limit * 10) {
    if (waitpid($pid, 1) > 0) { exit($? >> 8) }
    select(undef, undef, undef, 0.1); $waited++;
  }
  kill "TERM", -$pid; sleep 1; kill "KILL", -$pid; waitpid($pid, 0);
  exit 4;
' "$limit" "$engine/bin/headless-run" --window main > "$log" 2>&1
code=$?
sleep 1
left=$(pgrep -f "bench/hd2d_town.*headless" || true)
if [ -n "$left" ]; then echo "[gpu_run] 残ったプロセスを止める: $left"; kill -9 $left; sleep 1; fi
echo "[gpu_run] 終わり（コード $code）・残ったプロセス: $(pgrep -f 'bench/hd2d_town.*headless' | wc -l | tr -d ' ')"
exit $code
