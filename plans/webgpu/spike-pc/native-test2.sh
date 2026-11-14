#!/bin/bash
# D: 既定の場所で、Dawn 版が動いている間に wgpu 版を起動する（片方がもう片方の開いている dylib を上書きする形）。
# E: 同じ事を NATIVE_DIR を分けて。
D=$(cd "$(dirname "$0")" && pwd)
cd "$D"
J=${TMPDIR:-/tmp}/jParser$USER
one() { local tag=$1 back=$2; shift 2; env BACK=$back "$@" JOPTS="-Djava.awt.headless=true" ./run.sh Bench sto $back > logs/nt_$tag.log 2>&1; echo "$tag($back) exit=$? $(grep -c RESULT logs/nt_$tag.log) results"; }
for i in 1 2; do
  echo "== D$i"; rm -rf "$J"
  one D${i}a dawn & sleep 1.5; one D${i}b wgpu & wait
  echo "== E$i"
  one E${i}a dawn NATIVE_DIR=$D/native/dawn & sleep 1.5; one E${i}b wgpu NATIVE_DIR=$D/native/wgpu & wait
done
