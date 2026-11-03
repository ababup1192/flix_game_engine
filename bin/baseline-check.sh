#!/usr/bin/env bash
# baseline-check.sh — 今の描き出しの結果を基準（bench/baseline/<版>/）と比べる。違いがあれば exit 1。
#
#   bin/baseline-check.sh <基準のフォルダ> <gl-parity のログ> [--gallery]
#
# 先に流しておく物（make baseline-check が順に流す）: make gl-parity（ログを渡す）・FGE_RENDER_CACHE=off make scene3d-still。
# --gallery を付けると、テンプレの gallery/*.png（make render-all の後）も reference-gallery.sha256 と比べる。
#
# 比べる物と強さ:
#   gl-parity の行      … 場面ごとの「一致 / 差 N px」が基準と同じか（減った行も違いとして落とす。良くなったなら基準と上限を取り直す合図）
#                         式の行（E 段階）は基準と比べず並べて見せ、上限を超えた行があれば落とす（測った差の値は GPU ごとに違う）
#   CPU の絵の SHA-256  … gl-parity の soft/・3D の部屋の room.png・テンプレの gallery は GPU に依らないので、同じ JDK・同じ CPU の種類なら違えば退行
#                         （Math.sin などは JIT の組み込みで 1 ulp ずれてよいので、JDK や CPU の種類を替えた時は取り直す）
#   GL の絵の SHA-256   … gl-parity の gl/ は同じ機械でだけ比べられるので、違いは数えて知らせるだけ（exit を変えない）
set -euo pipefail

engine=$(cd "$(dirname "$0")/.." && pwd)
if [ $# -lt 2 ]; then echo "usage: $0 <基準のフォルダ> <gl-parity のログ> [--gallery]" >&2; exit 2; fi
base=$1 parity_log=$2 gallery=${3:-}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0

"$engine/bin/check-fpkg-fresh.sh"

grep -v '^#' "$base/gl-parity.txt" > "$tmp/parity-base"
grep '\[parity\]' "$parity_log" | awk '!seen[$0]++' > "$tmp/parity-all" || true
grep -v '^\[parity\] [^ ]* *E  ' "$tmp/parity-all" > "$tmp/parity-now" || true
if [ ! -s "$tmp/parity-now" ]; then
	echo "[baseline] gl-parity のログに [parity] の行が無い（組めずに止まった？ ${parity_log} を見る）。ほかの比べもしない" >&2
	exit 1
fi
if diff -u "$tmp/parity-base" "$tmp/parity-now" > "$tmp/parity-diff"; then
	echo "[baseline] gl-parity の行: 基準と同じ（$(wc -l < "$tmp/parity-now" | tr -d ' ') 行）"
else
	echo "[baseline] gl-parity の行が基準と違う（- が基準・+ が今）:"; grep '^[-+]\[' "$tmp/parity-diff"; failed=1
fi
grep '^\[parity\] [^ ]* *E  ' "$tmp/parity-all" | sed 's/^/[baseline] 式の行（比べない）: /' || true
if grep -qE '^\[parity\] [^ ]* *E  (違う|比較不能)' "$tmp/parity-all"; then
	echo "[baseline] 式の行に上限を超えた行がある"; failed=1
fi

grep -v '^#' "$base/gl-parity.sha256" > "$tmp/sha-base"
(cd "$engine/bench/gl_parity/debug" && shasum -a 256 soft/*.png gl/*.png) > "$tmp/sha-now"
soft_diff=$(diff <(grep ' soft/' "$tmp/sha-base") <(grep ' soft/' "$tmp/sha-now") | grep '^[<>]' || true)
gl_diff=$(diff <(grep ' gl/' "$tmp/sha-base") <(grep ' gl/' "$tmp/sha-now") | grep -c '^>' || true)
if [ -z "$soft_diff" ]; then echo "[baseline] gl-parity の CPU の絵: 基準とバイト一致"
else echo "[baseline] gl-parity の CPU の絵が基準と違う（< 基準・> 今）:"; printf '%s\n' "$soft_diff"; failed=1; fi
echo "[baseline] gl-parity の GL の絵: 基準と違う SHA ${gl_diff} 枚（同じ機械で撮った基準とだけ比べる）"

room_base=$(awk -F'\t' '$1 == "room.png" { print $2 }' "$base/scene3d.txt")
room_now=$(shasum -a 256 "$engine/bench/scene3d/debug/room.png" | cut -d' ' -f1)
if [ "$room_base" = "$room_now" ]; then echo "[baseline] 3D の部屋の CPU の絵: 基準とバイト一致"
else echo "[baseline] 3D の部屋の CPU の絵が基準と違う（基準 ${room_base} / 今 ${room_now}）"; failed=1; fi

if [ "$gallery" = "--gallery" ]; then
	grep -v '^#' "$base/reference-gallery.sha256" > "$tmp/gallery-base"
	for t in $(awk '{ split($2, p, "/"); print p[1] }' "$tmp/gallery-base" | sort -u); do
		(cd "$engine/templates/$t/gallery" && shasum -a 256 *.png | sed "s|  |  $t/|")
	done > "$tmp/gallery-now"
	if diff -u "$tmp/gallery-base" "$tmp/gallery-now" > "$tmp/gallery-diff"; then
		echo "[baseline] テンプレの gallery: 基準とバイト一致（$(wc -l < "$tmp/gallery-now" | tr -d ' ') 枚）"
	else
		echo "[baseline] テンプレの gallery が基準と違う:"; grep '^[-+][0-9a-f]' "$tmp/gallery-diff"; failed=1
	fi
fi

exit $failed
