#!/usr/bin/env bash
# check-external.sh — 外のゲームの写しに今の engine_full を当てて flix check し、エラーの中身（ファイル・行・番号）を控える・比べる。
#
#   bin/check-external.sh <出力.tsv> [<ゲームのフォルダ> ...]     写しを型検査して、通った物とエラーを出力へ書く
#                                                                （隣の <出力>.revs に各ゲームの src・test の中身の指紋を控える）
#   bin/check-external.sh --compare <基準.tsv> <今.tsv>           基準で通っていたのに止まった物と、基準に無かったエラーを出す（あれば exit 1）
#
# ゲームのフォルダは汚さない: 一時のフォルダへ src・test・flix.toml・project.json だけ写し、flix.toml の engine の版を
# 今の engine_full の版へ書き換え、lib に engine_full の fpkg（make sync-engine-full が作った物）を置いてから検査する。
# 写しの上げ方: 基準のフォルダの upgrade/<ゲームの名前>.patch があれば写しへ当てる（EXTERNAL_UPGRADES で置き場を替える）。
# 版を固定していて 0.76 の移行を済ませていないゲームも、移行メモどおりに上げた写しで門の中に入れるため（ゲームの本体は変えない）。
# 当たらなくなったら（ゲーム側が直した）、その行を「(upgrade)」として残す。基準を取り直すか patch を作り直す。
# ゲームを省くと下の既定の顔ぶれ（計画書 engine-core-polish.md §7 の「門の対象」）。JVM は 1 つずつ・nice で流す。
# 基準の時点で止まるゲーム（版を固定していて移行をまたぐ物）も入れてある。比べるのは基準からの差だけなので、
# 前から止まっている所は出ない。
#
# 出力の行（タブ区切り）: <ゲーム>  ok                           … 型検査が通った
#                         <ゲーム>  <ファイル>  <番号>  <件数>   … そのファイルのその番号のエラーの数
#
# WhyNot: エラーの数で比べない — 名前の解決で止まると Flix はその先の型のエラーを出さないので、数は物差しにならない。
# WhyNot: 行の字（メッセージ）まで比べない — 版ごとに言い回しが変わり、同じエラーが違う物に見える。
# WhyNot: 行番号を鍵に入れない — 外のゲームは今も直されていて、エラーの無い所を直しただけで行がずれ、増えたエラーに化ける。
# 同じファイル・同じ番号の件数が増えたら出す（同じ組で 1 件直して 1 件増えた時は見逃す。基準で通るゲームでは起きない）。
set -euo pipefail

engine=$(cd "$(dirname "$0")/.." && pwd)
upgrades=${EXTERNAL_UPGRADES:-$engine/bench/baseline/0.76.0/upgrade}  # make check-external は BASELINE の upgrade を渡す
# 写しのフォルダへ移ってから当てるので、相対のパスは今の場所から絶対にしておく。
case "$upgrades" in /*) ;; *) upgrades="$(pwd)/$upgrades" ;; esac
workspace=${FGE_WORKSPACE:-$HOME/Documents/flix_ge_workspace}
default_games=(
	"$workspace/night_apartment"
	"$workspace/fps3d_lab"
	"${FGE_STUDIO:-$HOME/Desktop/flix_ge_studio}/server"
	"${FGE_DESKTOP_GAMES:-$HOME/Desktop}/internet_dungeon"
	"$engine/templates/rpg-starter"
	"$engine/templates/sound-novel-starter"
	"$engine/templates/tidepool-starter"
)
# WhyNot: game-starter を入れない — src に make new-game が埋める字（__WW__ など）が残っていて、写しても型検査に通らない。

if [ "${1:-}" = "--compare" ]; then
	if [ $# -ne 3 ]; then echo "usage: $0 --compare <基準.tsv> <今.tsv>" >&2; exit 2; fi
	base=$2 now=$3
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
	awk -F'\t' '$2 == "ok" { print $1 }' "$base" | sort > "$tmp/base-ok"
	awk -F'\t' '$2 == "ok" { print $1 }' "$now" | sort > "$tmp/now-ok"
	missing=$(awk -F'\t' '$2 == "(missing)" { print $1 }' "$now")
	broke=$(comm -23 "$tmp/base-ok" "$tmp/now-ok" | grep -vxF -f <(printf '%s\n' "$missing") || true)
	[ -n "$missing" ] && printf '%s\n' "$missing" | sed 's/^/[check-external] この機械に無いので比べていない: /'
	# 写しの中身の指紋が基準と違うゲームは、増えたエラーがゲーム側の直しから来ることがある。
	if [ -f "$base.revs" ] && [ -f "$now.revs" ]; then
		join -t "$(printf '\t')" "$base.revs" "$now.revs" | awk -F'\t' '$2 != $3 { print "[check-external] " $1 ": 写しの src・test が基準を取った時と違う（増えたエラーはゲーム側の直しからかもしれない）" }'
	fi
	# 基準より件数が増えた「ゲーム・ファイル・番号」（基準に無い組は 0 件から増えた扱い）。
	added=$(awk -F'\t' 'NR == FNR { if ($2 != "ok") seen[$1 "\t" $2 "\t" $3] = $4; next }
		$2 != "ok" && $2 != "(missing)" { key = $1 "\t" $2 "\t" $3; was = (key in seen) ? seen[key] : 0; if ($4 > was) print key "\t" was " → " $4 }' "$base" "$now")
	if [ -z "$broke" ] && [ -z "$added" ]; then
		echo "[check-external] 基準から増えたエラーは無い（通る $(wc -l < "$tmp/now-ok" | tr -d ' ') 本）"
		exit 0
	fi
	[ -n "$broke" ] && printf '%s\n' "$broke" | sed 's/^/[check-external] 基準で通っていたのに止まった: /'
	[ -n "$added" ] && printf '%s\n' "$added" | sed 's/^/[check-external] 基準に無かったエラー: /'
	echo "[check-external] 増えた物は、移行メモの「ゲームで直す物」で説明がつくかを確かめる" >&2
	exit 1
fi

if [ $# -lt 1 ]; then
	echo "usage: $0 <出力.tsv> [<ゲームのフォルダ> ...] | --compare <基準.tsv> <今.tsv>" >&2
	exit 2
fi

out=$1
shift
if [ $# -gt 0 ]; then games=("$@"); else games=("${default_games[@]}"); fi

version=$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$engine/engine_full/flix.toml" | head -1)
fpkg="$engine/engine_full/artifact/package.fpkg"
"$engine/bin/check-fpkg-fresh.sh"

work=$(mktemp -d)
trap 'rm -rf "$work" "$out.tmp" "$out.revs.tmp"' EXIT
: > "$out.tmp"
: > "$out.revs.tmp"

for game in "${games[@]}"; do
	name=$(basename "$game")
	if [ ! -f "$game/flix.toml" ]; then
		echo "[check-external] $name: $game に flix.toml が無いので飛ばす" >&2
		printf '%s\t(missing)\t-\t1\n' "$name" >> "$out.tmp"
		continue
	fi
	copy="$work/$name"
	mkdir -p "$copy"
	for part in src test flix.toml project.json; do
		[ -e "$game/$part" ] && cp -R "$game/$part" "$copy/"
	done
	sed -i.bak -E "s/(\"github:ababup1192\/flix_game_engine\" *= *\{ *version *= *\")[^\"]*\"/\1${version}\"/" "$copy/flix.toml"
	if ! grep -q "flix_game_engine\" *= *{ *version *= *\"${version}\"" "$copy/flix.toml"; then
		echo "error: $game/flix.toml の engine の版を ${version} へ書き換えられない（依存の書き方が違う）" >&2
		exit 1
	fi
	# 写した src・test の中身の指紋（git でないゲームもあり、コミットだけでは未コミットの直しを区別できない）。
	printf '%s\t%s\n' "$name" "$(cd "$copy" && find src test -type f 2>/dev/null | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -c1-16)" >> "$out.revs.tmp"
	if [ -f "$upgrades/$name.patch" ] && ! (cd "$copy" && patch -p1 -s --no-backup-if-mismatch < "$upgrades/$name.patch") > "$work/$name.patch.log" 2>&1; then
		echo "[check-external] $name: $upgrades/$name.patch が当たらない" >&2
		printf '%s\t(upgrade)\t%s.patch\t1\n' "$name" "$name" >> "$out.tmp"
		continue
	fi
	lib="$copy/lib/github/ababup1192/flix_game_engine/$version"
	mkdir -p "$lib"
	# WhyNot: Maven の依存を毎回取りに行かせない — 7 本続けて取ると repo1.maven.org が 429 を返し、型検査の前に止まる。
	#   今の engine_full が取った写しを置き、ゲームの写しで足りない物を埋める（古い版のゲームの写しには今の依存が欠ける）。
	for from in "$game/lib" "$engine/engine_full/lib"; do
		for dep in cache external; do
			[ -d "$from/$dep" ] && mkdir -p "$copy/lib/$dep" && cp -R "$from/$dep/." "$copy/lib/$dep/"
		done
	done
	cp "$fpkg" "$lib/flix_game_engine-$version.fpkg"
	cp "$engine/engine_full/flix.toml" "$lib/flix_game_engine-$version.toml"
	echo "[check-external] $name（engine $version）"
	log="$work/$name.log"
	if (cd "$copy" && nice "$engine/bin/flix" check) > "$log" 2>&1; then
		printf '%s\tok\n' "$name" >> "$out.tmp"
	else
		# エラーの見出し「-- X Error [E1234] --- path」をファイルと番号の組で数える。
		sed 's/\x1b\[[0-9;]*m//g' "$log" | awk -v game="$name" '
			/^-- .*\[E[0-9]+\]/ { match($0, /\[E[0-9]+\]/); count[$NF "\t" substr($0, RSTART + 1, RLENGTH - 2)]++ }
			END { for (k in count) print game "\t" k "\t" count[k] }
		' >> "$out.tmp"
		if ! grep -q "^$name	" "$out.tmp"; then
			# 見出しの無い止まり方（依存の解決など）も「通らない」として残す。
			# WhyNot: 鍵にログの字を入れない — 止まり方の字が回ごとに変わると、毎回「増えた」に見える。字は標準エラーへ。
			echo "[check-external] $name: 見出しの無い止まり方: $(tail -1 "$log")" >&2
			printf '%s\t(check)\t-\t1\n' "$name" >> "$out.tmp"
		fi
	fi
done

sort "$out.tmp" > "$out"
sort "$out.revs.tmp" > "$out.revs"
rm -f "$out.tmp" "$out.revs.tmp"
echo "[check-external] $(awk -F'\t' '$2 == "ok"' "$out" | wc -l | tr -d ' ') 本が通る・エラー $(awk -F'\t' '$2 != "ok" { n += $4 } END { print n + 0 }' "$out") 件 → $out"
