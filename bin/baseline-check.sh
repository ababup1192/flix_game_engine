#!/usr/bin/env bash
# baseline-check.sh — 今の描き出しの結果を基準（bench/baseline/<版>/）と比べる。違いがあれば exit 1。
#
#   bin/baseline-check.sh <基準のフォルダ> <gl-parity のログ> [--gallery] [--gallery-base <フォルダ>] [--only-2d] [--only-known]
#                         [--compare-max <控えのフォルダ>]
#
# 先に流しておく物（make baseline-check が順に流す）: make gl-parity（ログを渡す）・FGE_RENDER_CACHE=off make scene3d-still。
#   --gallery               テンプレの gallery/*.png（make render-all の後）も reference-gallery.sha256 と比べる
#   --gallery-base <フォルダ> gallery の基準の reference-gallery.sha256 を <基準のフォルダ> でなくこのフォルダから読む（--gallery と一緒に）
#   --only-2d               ログの [parity3d] の名前の行（3D の場面を持つ scene）と E 段階の行（3D の式）を、基準と今の両方から除いて比べる。
#                           CPU と GL の絵の SHA も [parity3d] の名前の物を除き、3D の部屋の room.png は比べない
#   --only-known            基準に無い名前の行と絵は飛ばす（基準を撮った後で足した scene を比べない）
#   --compare-max <フォルダ>  3D の各行（[parity3d] の名前）の「差 N px, max ±M」を、そのフォルダの gl-parity.txt の同じ行と並べて出す（知らせるだけ）。
#                           max が控えの +1 を超えたか差の px が控えの 2 倍を超えた行に印を付ける
#
# 比べる物と強さ:
#   gl-parity の行      … 場面ごとの「一致 / 差 N px」が基準と同じか（減った行も違いとして落とす。良くなったなら基準と上限を取り直す合図）
#                         式の行（E 段階）は基準と比べず並べて見せ、上限を超えた行があれば落とす（測った差の値は GPU ごとに違う）
#   CPU の絵の SHA-256  … gl-parity の soft/・3D の部屋の room.png・テンプレの gallery は GPU に依らないので、同じ JDK・同じ CPU の種類なら違えば退行
#                         （Math.sin などは JIT の組み込みで 1 ulp ずれてよいので、JDK や CPU の種類を替えた時は取り直す）
#   GL の絵の SHA-256   … gl-parity の gl/ は同じ機械でだけ比べられるので、違いは数えて知らせるだけ（exit を変えない）
#
# WhyNot: --only-2d で、3D と 2D を同じ絵に重ねた scene（afterScene3d・windowPass3d・glassPane3d など）の 2D の側を切り出して比べない —
#   比べるのは 1 枚の絵の SHA と 1 行の差の数なので、3D の側が変わると 2D の側だけを取り出せない。その 2D の側は、
#   作業場の project.json の scene3dLinearColor を偽にして 3D の色を前の式に戻し、--only-known で絵ごと基準と比べる確かめで見る。
set -euo pipefail

engine=$(cd "$(dirname "$0")/.." && pwd)
usage="usage: $0 <基準のフォルダ> <gl-parity のログ> [--gallery] [--gallery-base <フォルダ>] [--only-2d] [--only-known] [--compare-max <フォルダ>]"
if [ $# -lt 2 ]; then echo "$usage" >&2; exit 2; fi
base=$1 parity_log=$2
shift 2
gallery=0 gallery_base="" only_2d=0 only_known=0 compare_max=""
while [ $# -gt 0 ]; do
	case $1 in
		--gallery) gallery=1 ;;
		--gallery-base) [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }; gallery_base=$2; shift ;;
		--only-2d) only_2d=1 ;;
		--only-known) only_known=1 ;;
		--compare-max) [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }; compare_max=$2; shift ;;
		*) echo "知らない引数: $1" >&2; echo "$usage" >&2; exit 2 ;;
	esac
	shift
done
if [ -n "$gallery_base" ] && [ "$gallery" = 0 ]; then echo "--gallery-base は --gallery と一緒に使う" >&2; exit 2; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0

"$engine/bin/check-fpkg-fresh.sh"

# 3D の場面を持つ scene の名前（gl_parity の Main が [parity3d] の行で出す）。
grep '^\[parity3d\] ' "$parity_log" | awk '{ print $2 }' | sort -u > "$tmp/names3d" || true
if [ "$only_2d" = 1 ] && [ ! -s "$tmp/names3d" ]; then
	echo "[baseline] --only-2d なのにログに [parity3d] の行が無い（gl_parity が古い？ ${parity_log} を見る）" >&2
	exit 1
fi

# 行の絞り込み: --only-2d は 3D の名前と E 段階の行を除き、--only-known は基準の名前（$2）に無い行を除く。
filter_rows() {
	local known=$1
	awk -v only2d="$only_2d" -v onlyKnown="$only_known" '
		FILENAME == ARGV[1] { n3[$1] = 1; next }
		FILENAME == ARGV[2] { k[$2] = 1; next }
		{
			if (only2d == 1 && ($2 in n3 || $3 == "E")) next
			if (onlyKnown == 1 && !($2 in k)) next
			print
		}' "$tmp/names3d" "$known" -
}

grep -v '^#' "$base/gl-parity.txt" > "$tmp/parity-base-all"
grep '\[parity\]' "$parity_log" | awk '!seen[$0]++' > "$tmp/parity-all" || true
grep -v '^\[parity\] [^ ]* *E  ' "$tmp/parity-all" > "$tmp/parity-now-all" || true
if [ ! -s "$tmp/parity-now-all" ]; then
	echo "[baseline] gl-parity のログに [parity] の行が無い（組めずに止まった？ ${parity_log} を見る）。ほかの比べもしない" >&2
	exit 1
fi
filter_rows "$tmp/parity-base-all" < "$tmp/parity-base-all" > "$tmp/parity-base"
filter_rows "$tmp/parity-base-all" < "$tmp/parity-now-all" > "$tmp/parity-now"
scope=""
[ "$only_2d" = 1 ] && scope="${scope}・2D だけ（3D の名前 $(wc -l < "$tmp/names3d" | tr -d ' ') 個を除く）"
[ "$only_known" = 1 ] && scope="${scope}・基準にある名前だけ"
if diff -u "$tmp/parity-base" "$tmp/parity-now" > "$tmp/parity-diff"; then
	echo "[baseline] gl-parity の行: 基準と同じ（$(wc -l < "$tmp/parity-now" | tr -d ' ') 行${scope}）"
else
	echo "[baseline] gl-parity の行が基準と違う（- が基準・+ が今${scope}）:"; grep '^[-+]\[' "$tmp/parity-diff"; failed=1
fi
if [ "$only_2d" = 0 ]; then
	grep '^\[parity\] [^ ]* *E  ' "$tmp/parity-all" | sed 's/^/[baseline] 式の行（比べない）: /' || true
	if grep -qE '^\[parity\] [^ ]* *E  (違う|比較不能)' "$tmp/parity-all"; then
		echo "[baseline] 式の行に上限を超えた行がある"; failed=1
	fi
fi

# 絵の SHA の行（「<SHA>  soft/<名前>.png」）の絞り込み。
filter_shas() {
	local known=$1
	awk -v only2d="$only_2d" -v onlyKnown="$only_known" '
		FILENAME == ARGV[1] { n3[$1] = 1; next }
		FILENAME == ARGV[2] { k[$2] = 1; next }
		{
			name = $2; sub(/^[^\/]*\//, "", name); sub(/\.png$/, "", name)
			if (only2d == 1 && (name in n3)) next
			if (onlyKnown == 1 && !($2 in k)) next
			print
		}' "$tmp/names3d" "$known" -
}

grep -v '^#' "$base/gl-parity.sha256" > "$tmp/sha-base-all"
(cd "$engine/bench/gl_parity/debug" && shasum -a 256 soft/*.png gl/*.png) > "$tmp/sha-now-all"
filter_shas "$tmp/sha-base-all" < "$tmp/sha-base-all" > "$tmp/sha-base"
filter_shas "$tmp/sha-base-all" < "$tmp/sha-now-all" > "$tmp/sha-now"
soft_diff=$(diff <(grep ' soft/' "$tmp/sha-base") <(grep ' soft/' "$tmp/sha-now") | grep '^[<>]' || true)
gl_diff=$(diff <(grep ' gl/' "$tmp/sha-base") <(grep ' gl/' "$tmp/sha-now") | grep -c '^>' || true)
if [ -z "$soft_diff" ]; then echo "[baseline] gl-parity の CPU の絵: 基準とバイト一致（$(grep -c ' soft/' "$tmp/sha-now" || true) 枚${scope}）"
else echo "[baseline] gl-parity の CPU の絵が基準と違う（< 基準・> 今${scope}）:"; printf '%s\n' "$soft_diff"; failed=1; fi
echo "[baseline] gl-parity の GL の絵: 基準と違う SHA ${gl_diff} 枚（同じ機械で撮った基準とだけ比べる${scope}）"

if [ "$only_2d" = 1 ]; then
	echo "[baseline] 3D の部屋の CPU の絵: --only-2d なので比べない"
else
	room_base=$(awk -F'\t' '$1 == "room.png" { print $2 }' "$base/scene3d.txt")
	room_now=$(shasum -a 256 "$engine/bench/scene3d/debug/room.png" | cut -d' ' -f1)
	if [ "$room_base" = "$room_now" ]; then echo "[baseline] 3D の部屋の CPU の絵: 基準とバイト一致"
	else echo "[baseline] 3D の部屋の CPU の絵が基準と違う（基準 ${room_base} / 今 ${room_now}）"; failed=1; fi
fi

if [ -n "$compare_max" ]; then
	# 行の字（Main の line）: 「[parity] <名前> B  一致 (0 px)…」か「[parity] <名前> B  差 <N> px, max ±<M>…」。一致は 0 px・±0 と読む。
	px_max() {
		awk -v want="$1" '$1 == "[parity]" && $2 == want && $3 != "E" && $4 != "描いた数" {
			if ($4 == "一致") { print "0 0"; exit }
			if ($4 == "差") { px = $5; m = $8; sub(/^±/, "", m); sub(/[^0-9].*$/, "", m); print px, m; exit }
		}' "$2"
	}
	echo "[baseline] 3D の行の差の数と max（控え ${compare_max} → 今。! = max が控えの +1 を超えたか、差の px が控えの 2 倍を超えた）:"
	while read -r name; do
		was=$(px_max "$name" <(grep -v '^#' "$compare_max/gl-parity.txt"))
		now=$(px_max "$name" "$tmp/parity-now-all")
		if [ -z "$was" ]; then printf '[baseline]   %-20s 控え なし → 今 %s px, max ±%s\n' "$name" ${now:-"? ?"}; continue; fi
		if [ -z "$now" ]; then printf '[baseline]   %-20s 控え %s px, max ±%s → 今 なし\n' "$name" $was; continue; fi
		set -- $was $now
		mark=""
		if [ "$4" -gt $(($2 + 1)) ] || [ "$3" -gt $((2 * $1)) ]; then mark="  !"; fi
		printf '[baseline]   %-20s 控え %6s px, max ±%-3s → 今 %6s px, max ±%-3s%s\n' "$name" "$1" "$2" "$3" "$4" "$mark"
	done < "$tmp/names3d"
fi

if [ "$gallery" = 1 ]; then
	gallery_from=${gallery_base:-$base}
	grep -v '^#' "$gallery_from/reference-gallery.sha256" > "$tmp/gallery-base"
	for t in $(awk '{ split($2, p, "/"); print p[1] }' "$tmp/gallery-base" | sort -u); do
		(cd "$engine/templates/$t/gallery" && shasum -a 256 *.png | sed "s|  |  $t/|")
	done > "$tmp/gallery-now"
	if diff -u "$tmp/gallery-base" "$tmp/gallery-now" > "$tmp/gallery-diff"; then
		echo "[baseline] テンプレの gallery: 基準（${gallery_from}）とバイト一致（$(wc -l < "$tmp/gallery-now" | tr -d ' ') 枚）"
	else
		echo "[baseline] テンプレの gallery が基準（${gallery_from}）と違う:"; grep '^[-+][0-9a-f]' "$tmp/gallery-diff"; failed=1
	fi
fi

exit $failed
