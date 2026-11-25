#!/usr/bin/env bash
# multi-parity.sh — 描き手ごとに「MultiMesh の場面 ＝ 同じ物を instances に置いた場面」の絵が画素まで同じかを見る（自分自身との比べ）。
#
#   bench/scene3d/multi-parity.sh [pc|web|all]   既定 all（どこから流してもよい・engine の根へ移って流す）
#
# pc  = bin/gl-capture.sh で bench/scene3d の field を GL と WebGPU（Dawn）で撮り、MULTI=0 と MULTI=1 の 3 コマ目の SHA を比べる
# web = make bench-web-export で書き出した bench/scene3d を web-capture で WebGPU と WebGL2 で撮り、multi=0 と multi=1 の SHA を比べる
# 場面は 3 つ: 不透明（opaque）・cutout の材質（cutout）・太陽の影（shadow）。どれも MATS=1 SHAPES=1 ALPHA=0（MultiMesh は形と材質が 1 つ）。
# 違えば exit 1。撮った物は build/multi-parity/ に残す。
set -euo pipefail
engine=$(cd "$(dirname "$0")/../.." && pwd)
cd "$engine"
which=${1:-all}
out="$engine/build/multi-parity"
rm -rf "$out"
mkdir -p "$out"
cases=("opaque|" "cutout|CUTOUT=1" "shadow|SHADOW=1")
fail=0

# WhyNot: 物の数を crowd の 1 万にしない — 比べるのは絵の一致だけで、撮る時間を短く保つ（400 体で全部が画面に入る）。
knobs_of() { echo "SCENE=field COUNT=400 MATS=1 SHAPES=1 MOVING=100 ALPHA=0 $1"; }

compare() { # $1 = 名前  $2 = MULTI=0 の絵  $3 = MULTI=1 の絵
	local a b
	a=$(shasum -a 256 "$2" | cut -d' ' -f1)
	b=$(shasum -a 256 "$3" | cut -d' ' -f1)
	if [ "$a" = "$b" ]; then echo "[multi-parity] 一致: $1"; else echo "[multi-parity] 違う: $1（$2 と $3）" >&2; fail=1; fi
}

if [ "$which" = pc ] || [ "$which" = all ]; then
	for backend in gl webgpu; do
		for c in "${cases[@]}"; do
			name=${c%%|*}; extra=${c#*|}
			for m in 0 1; do
				dir="$out/pc-$backend-$name-multi$m"
				env $(knobs_of "$extra") MULTI=$m FRAMES=3 bin/gl-capture.sh --backend "$backend" "$dir" "bench/scene3d:" > "$dir.log" 2>&1 || { echo "[multi-parity] 撮れなかった: $dir.log" >&2; exit 1; }
			done
			compare "pc $backend $name" "$out/pc-$backend-$name-multi0/scene3d/frame-3.png" "$out/pc-$backend-$name-multi1/scene3d/frame-3.png"
		done
	done
fi

if [ "$which" = web ] || [ "$which" = all ]; then
	make --no-print-directory bench-web-export BENCH=scene3d > "$out/web-export.log" 2>&1 || { echo "[multi-parity] 書き出せなかった: $out/web-export.log" >&2; exit 1; }
	for backend in webgpu webgl2; do
		for c in "${cases[@]}"; do
			name=${c%%|*}; extra=${c#*|}
			query="scene=field&n=400&mats=1&shapes=1&moving=100&alpha=0"
			[ -n "$extra" ] && query="$query&$(echo "$extra" | tr 'A-Z' 'a-z')"
			dev="capture:30"; [ "$backend" = webgl2 ] && dev="capture:30,webgl2"
			for m in 0 1; do
				bin/fge web-capture "index.html?$query&multi=$m" "$out/web-$backend-$name-multi$m.png" --dir build/bench-web/scene3d --dev "$dev" --size 960x540 --wait 120 \
					> "$out/web-$backend-$name-multi$m.log" 2>&1 || { echo "[multi-parity] 撮れなかった: $out/web-$backend-$name-multi$m.log" >&2; exit 1; }
			done
			compare "web $backend $name" "$out/web-$backend-$name-multi0.png" "$out/web-$backend-$name-multi1.png"
		done
	done
fi
exit $fail
