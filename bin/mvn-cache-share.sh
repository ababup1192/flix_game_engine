#!/bin/sh
# mvn-cache-share.sh — <根> の下の Flix のパッケージごとの lib/cache（Maven の取り物の置き場）を、共有の置き場 1 か所へ移し、
# lib/cache をそこへの symlink にする。
#
#     bin/mvn-cache-share.sh <根>
#     bin/mvn-cache-share.sh --pkg <パッケージ>  そのパッケージ 1 つだけ。lib/cache が symlink なら何もせず、何かした時だけ標準エラーへ 1 行
#                                              （bin/flix・mk/game.mk・make new-game が flix を起こす前に通す）
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
# 移し方の規則は go/internal/mvncache（bin/fge の go 側が flix を起こす前に通す）と同じ。片方を直したらもう片方も直す。
#
# WhyNot: パッケージごとに置かない — 同じ LWJGL の POM と jar を 20 か所で別々に取り、worktree や新しいゲームを作るたびに
# Maven Central が HTTP 429 を返す。
set -u

root=${1:?使い方: bin/mvn-cache-share.sh <根> | --pkg <パッケージ> | --print-dir}

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
one=
if [ "$root" = --pkg ]; then
	one=${2:?使い方: bin/mvn-cache-share.sh --pkg <パッケージ>}
	# 毎回の代金を test 1 回に収める（指す先は辿らない。別の所を指す symlink は make status が知らせる）。
	[ -L "$one/lib/cache" ] && exit 0
	[ -f "$one/flix.toml" ] || exit 0
	# WhyNot: Git Bash（MSYS）では張らない — 既定の ln -s は symlink でなく丸写しを作り、置き場をまるごと写してしまう。
	case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) exit 0 ;; esac
	root=$one
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

# $1 = 根からの相対パス（lib/cache）。1 つのパッケージの lib/cache の中身を置き場へ移して symlink にし、どうしたかを note に書く。
share_one() {
	rel=$1
	cache="$root/$rel"
	if [ -L "$cache" ]; then
		if [ "$(cd "$cache" 2>/dev/null && pwd -P)" = "$shared" ]; then
			note "済み      $rel"
		else
			note "飛ばした  $rel（別の所を指す symlink: $(readlink "$cache")）"
		fi
		return
	fi
	if [ -d "$cache" ]; then
		# WhyNot: 開いているプロセスがある間は動かさない — 取っている最中の .part とロックを置き場の外に置き去りにする。
		if [ -n "$(lsof +D "$cache" 2>/dev/null | sed 1d)" ]; then
			note "飛ばした  $rel（使用中。flix を止めてからもう一度）"
			return
		fi
		if [ -e "$cache.unmerged" ]; then
			note "飛ばした  $rel（前の $rel.unmerged が残っている。中を見て片付けてからもう一度）"
			return
		fi
		# WhyNot: 先に張れるかを試す — 中身を移した後で張れないと分かると、lib/cache が無いまま取り直しになる。
		probe="$cache.link-$$"
		if ! ln -s "$shared" "$probe" 2>/dev/null; then
			note "飛ばした  $rel（symlink を張れない）"
			return
		fi
		conflicts=$(merge_into_shared "$cache")
		# WhyNot: 消すのは中にファイルが残っていない時だけ — 残っているのは置き場と中身の違う物で、捨てると戻せない。
		if [ -z "$(find "$cache" -type f ! -name '*.lock' ! -name '*.part' | head -1)" ]; then
			rm -rf "$cache"
			mv "$probe" "$cache" && note "移した    $rel"
		else
			mv "$cache" "$cache.unmerged"
			mv "$probe" "$cache" && note "移した    $rel（置き場と中身の違う ${conflicts} 件を $rel.unmerged に残した）"
		fi
		return
	fi
	mkdir -p "$(dirname "$cache")" && ln -s "$shared" "$cache" 2>/dev/null && note "張った    $rel"
}

if [ -n "$one" ]; then
	share_one lib/cache
	sed "s|^|[mvn-cache] $root/: |" "$report" >&2
	exit 0
fi

for pkg in $("$(dirname "$0")/flix-packages.sh" "$root"); do
	rel="$pkg/lib/cache"
	[ "$pkg" = . ] && rel=lib/cache
	share_one "$rel"
done

echo "[mvn-cache-share] $root → $shared"
cat "$report"
exit 0
