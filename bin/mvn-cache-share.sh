#!/bin/sh
# mvn-cache-share.sh — <根> の下の Flix のパッケージごとの lib/cache（Maven の取り物の置き場）を、共有の置き場 1 か所へ移し、
# lib/cache をそこへの symlink にする。
#
#     bin/mvn-cache-share.sh <根>
#     bin/mvn-cache-share.sh --print-dir   共有の置き場のパスを出すだけ（make clean-locks が使う）
#
# 共有の置き場は bin/fge export-web と同じ <ユーザーの cache>/flix_game_engine/mvn-cache（MVN_CACHE で差し替え）。
# 中のファイルは置き場へ mv する。置き場に同じパスがあって中身も同じなら、手元の方を消す。中身が違えば手元を残し、
# lib/cache.unmerged へ名前を変えて symlink を張る（何も捨てない）。使用中の lib/cache は触らない。
#
# 同時に読み書きしても壊れない根拠（flix.jar 0.78.0 の中を読んだ）:
# Flix は coursier の FileCache を withLocation(lib/cache) だけ替えて使う。coursier は取り物ごとに <名前>.lock を
# FileChannel.tryLock で OS のロックにし、取る間は .<名前>.part に書いてから本来の名前へ移す。読む側は本来の名前しか見ないので、
# 途中まで書いたファイルを別のプロセスが読むことは無い。ロックは OS が持つので、落ちたプロセスのロックはファイルが残っても外れる。
# ~/.cache/coursier が sbt・mill・scala-cli の複数のプロセスで共有されているのと同じ作り。
#
# WhyNot: パッケージごとに置かない — 同じ LWJGL の POM と jar を 20 か所で別々に取り、worktree や新しいゲームを作るたびに
# Maven Central が HTTP 429 を返す。
set -u

root=${1:?使い方: bin/mvn-cache-share.sh <根> | --print-dir}

if [ -z "${MVN_CACHE:-}" ]; then
	# Go の os.UserCacheDir と同じ場所（export-web の linkSharedMavenCache と同じ置き場にする）。
	case "$(uname -s)" in
		Darwin) MVN_CACHE="$HOME/Library/Caches/flix_game_engine/mvn-cache" ;;
		MINGW*|MSYS*|CYGWIN*) MVN_CACHE="${LOCALAPPDATA:?}/flix_game_engine/mvn-cache" ;;
		*) MVN_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/flix_game_engine/mvn-cache" ;;
	esac
fi
if [ "$root" = --print-dir ]; then
	echo "$MVN_CACHE"
	exit 0
fi
root=$(cd "$root" && pwd -P) || exit 2
mkdir -p "$MVN_CACHE" || exit 1
shared=$(cd "$MVN_CACHE" && pwd -P)

report=$(mktemp)
trap 'rm -f "$report"' EXIT
note() { printf '%s\n' "$*" >> "$report"; }

# $1 = 移す lib/cache（実体のフォルダ）。置き場と違う中身のファイルの数を出す。
merge_into_shared() {
	dir=$1
	conflicts=0
	# WhyNot: .lock と .part は移さない — 使っていないことは lsof で確かめた後なので、どちらも落ちたプロセスの残り。
	files=$(cd "$dir" && find . -type f ! -name '*.lock' ! -name '*.part' | sed 's|^\./||')
	for f in $files; do
		# WhyNot: lib/cache/cache/ の下は 1 階層上げる — 在る lib/cache へ cp -R で写すと 1 階層深く入り、coursier からは見えない。
		# main の作業ツリーで実際に 60 件あった（中身は全部上の階層と同じ）。
		to="$shared/${f#cache/}"
		if [ ! -e "$to" ]; then
			mkdir -p "$(dirname "$to")" && mv "$dir/$f" "$to"
		elif cmp -s "$dir/$f" "$to"; then
			rm -f "$dir/$f"
		else
			conflicts=$((conflicts + 1))
		fi
	done
	echo "$conflicts"
}

for pkg in $("$(dirname "$0")/flix-packages.sh" "$root"); do
	rel="$pkg/lib/cache"
	[ "$pkg" = . ] && rel=lib/cache
	cache="$root/$rel"
	if [ -L "$cache" ]; then
		if [ "$(cd "$cache" 2>/dev/null && pwd -P)" = "$shared" ]; then
			note "済み      $rel"
		else
			note "飛ばした  $rel（別の所を指す symlink: $(readlink "$cache")）"
		fi
		continue
	fi
	if [ -d "$cache" ]; then
		# WhyNot: 開いているプロセスがある間は動かさない — 取っている最中の .part とロックを置き場の外に置き去りにする。
		if [ -n "$(lsof +D "$cache" 2>/dev/null | sed 1d)" ]; then
			note "飛ばした  $rel（使用中。flix を止めてからもう一度）"
			continue
		fi
		if [ -e "$cache.unmerged" ]; then
			note "飛ばした  $rel（前の $rel.unmerged が残っている。中を見て片付けてからもう一度）"
			continue
		fi
		conflicts=$(merge_into_shared "$cache")
		# WhyNot: 消すのは中にファイルが残っていない時だけ — 残っているのは置き場と中身の違う物で、捨てると戻せない。
		if [ -z "$(find "$cache" -type f ! -name '*.lock' ! -name '*.part' | head -1)" ]; then
			rm -rf "$cache"
			ln -s "$shared" "$cache" && note "移した    $rel"
		else
			mv "$cache" "$cache.unmerged"
			ln -s "$shared" "$cache" && note "移した    $rel（置き場と中身の違う ${conflicts} 件を $rel.unmerged に残した）"
		fi
		continue
	fi
	ln -s "$shared" "$cache" && note "張った    $rel"
done

echo "[mvn-cache-share] $root → $shared"
cat "$report"
exit 0
