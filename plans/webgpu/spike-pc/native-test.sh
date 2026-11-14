#!/bin/bash
# jWebGPU がネイティブを開く場所の癖を確かめる（Offscreen の三角形を読み戻す所まで）。
#  A: 既定の場所（$TMPDIR/jParser$USER）で wgpu 版 → Dawn 版を続けて（前の試作で JVM が止まった形）
#  B: 版ごとに NATIVE_DIR を分けて wgpu 版 → Dawn 版
#  C1: 既定の場所を消してから Dawn 版を 2 つ同時に（書き出しの取り合い）
#  C2: 書き出し済みの既定の場所で Dawn 版を 2 つ同時に
D=$(cd "$(dirname "$0")" && pwd)
cd "$D"
T=${TMPDIR:-/tmp}
J=$T/jParser$USER
run() { local tag=$1; shift; env "$@" ./run.sh Offscreen ${BACKARG} shots/nt_$tag.png > logs/nt_$tag.log 2>&1; echo "$tag exit=$? $(grep -o 'center=[0-9a-f]*' logs/nt_$tag.log)"; }
echo "== A"; rm -rf "$J"
BACKARG=wgpu run A1 BACK=wgpu
BACKARG=dawn run A2 BACK=dawn
for i in 1 2 3; do
  BACKARG=dawn run A3_$i BACK=dawn
  BACKARG=wgpu run A4_$i BACK=wgpu
done
echo "== B"
BACKARG=wgpu run B1 BACK=wgpu NATIVE_DIR=$D/native/wgpu
BACKARG=dawn run B2 BACK=dawn NATIVE_DIR=$D/native/dawn
BACKARG=wgpu run B3 BACK=wgpu NATIVE_DIR=$D/native/wgpu
echo "== C1"; rm -rf "$J"
(BACKARG=dawn run C1a BACK=dawn) & (BACKARG=dawn run C1b BACK=dawn) & wait
echo "== C2"
(BACKARG=dawn run C2a BACK=dawn) & (BACKARG=dawn run C2b BACK=dawn) & wait
