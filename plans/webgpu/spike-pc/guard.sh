#!/bin/bash
# 性能の測りが走っていたら待つ。flixlint の常駐 server（--root に bench/ を含むだけ）と、
# 同時に走るこの試作の guard・run.sh 自身（pgrep の式を引数に持つ）は外す。
busy() { pgrep -fl "bench/(sprite_stress|scene3d|crowd2d)|jfr-run|bench-ab" | grep -v -e flixlint.Resident -e pgrep -e guard.sh -e run.sh -e native-test; }
n=0
while busy >/dev/null; do
  [ $n -eq 0 ] && { echo "[guard] 測りが走っているので待つ:"; busy; }
  n=$((n+1)); sleep 15
done
