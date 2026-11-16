#!/bin/sh
# worktree-seed.sh — git の外にある依存（Flix の lib・コンパイラ jar・fge-go・GL の jar・fpkg）を、
# main の作業ツリーから新しい worktree へ張る。
#
#     bin/worktree-seed.sh <worktree の絶対パス> [main の作業ツリー]
#
# main の作業ツリーを省くと、worktree の属するリポジトリの最初の worktree（git worktree list の先頭）を使う。
# engine 以外のリポジトリ（Studio など）の worktree を渡しても、そのリポジトリの main から張る。
# 既にある物は触らない。main に無い物と git に入ってしまう物は飛ばす。最後に 1 行ずつ結果を出す。
#
# WhyNot: Flix の依存を worktree で解決させ直さない — Maven Central が HTTP 429 で止まり、
# GitHub の fpkg も API の回数制限に当たる。
set -u

wt=${1:-}
if [ -z "$wt" ]; then
	echo "使い方: bin/worktree-seed.sh <worktree の絶対パス> [main の作業ツリー]" >&2
	exit 2
fi
if [ ! -d "$wt" ]; then
	echo "error: $wt がありません" >&2
	exit 2
fi
wt=$(cd "$wt" && pwd -P)

main=${2:-}
if [ -z "$main" ]; then
	main=$(git -C "$wt" worktree list --porcelain | sed -n '1s/^worktree //p')
fi
if [ -z "$main" ] || [ ! -d "$main" ]; then
	echo "error: main の作業ツリーが分かりません（2 つ目の引数で渡してください）" >&2
	exit 2
fi
main=$(cd "$main" && pwd -P)
if [ "$main" = "$wt" ]; then
	echo "error: $wt は main の作業ツリーそのものです。新しい worktree を渡してください" >&2
	exit 2
fi

report=$(mktemp)
trap 'rm -f "$report"' EXIT

note() { printf '%s\n' "$*" >> "$report"; }

# APFS なら clone（中身を共有し、書いた所だけ別になる）。他のファイルシステムでは普通の写しに落ちる。
clone() {
	/bin/cp -cR "$1" "$2" 2>/dev/null || { rm -rf "$2"; /bin/cp -R "$1" "$2"; }
}

# $1 = symlink | clone、$2 = リポジトリの根からの相対パス
seed() {
	how=$1
	rel=$2
	src="$main/$rel"
	dst="$wt/$rel"
	if [ ! -e "$src" ]; then
		note "飛ばした  $rel（main に無い）"
		return
	fi
	if [ -e "$dst" ] || [ -L "$dst" ]; then
		note "飛ばした  $rel（既にある）"
		return
	fi
	# WhyNot: 張る前に git の無視を確かめる — 張った lib を git add すると、別の枝の取り込みで
	# 消えたり main の lib を指す symlink がコミットされたりする。
	# 末尾の / は、まだ worktree に無いフォルダを `bin/dist/` のような dir だけの行に当てるため。
	probe=$rel
	[ -d "$src" ] && probe="$rel/"
	if ! git -C "$wt" check-ignore -q "$probe"; then
		note "飛ばした  $rel（.gitignore に無い。張ると git に入る）"
		return
	fi
	mkdir -p "$(dirname "$dst")"
	if [ "$how" = symlink ]; then
		ln -s "$src" "$dst" && note "張った    $rel（symlink）"
	else
		clone "$src" "$dst" && note "張った    $rel（clone）"
	fi
}

# Flix のパッケージ（flix.toml を持ち、main で lib/ が育っている所）を拾う。
# WhyNot: ./build の直下は拾う — build/engine_full_web は make が組み立てるパッケージで、lib を持つ。
# それより深い build/ は組んだ class の山か、配る版の組み立ての写し (build/bundle) なので歩かない。
pkgs=$(cd "$main" && find . \
	\( -path ./.git -o -path ./.claude -o -path ./.devbox -o -path './*/build' -o \( -path './build/*/*' -type d \) \
	   -o -name node_modules -o -name src -o -name test -o -name artifact \) -prune \
	-o -name flix.toml -print 2>/dev/null | sed 's|/flix.toml$||; s|^\./||' | sort)

for pkg in $pkgs; do
	lib="$pkg/lib"
	[ "$pkg" = . ] && lib=lib
	[ -d "$main/$lib" ] || continue
	# WhyNot: worktree に無いパッケージへは張らない — main にだけある作りかけのフォルダを worktree に生やすと、
	# 中身の無い lib だけが残る。.layers と build は make が後から作る場所なので先に張ってよい。
	case "$pkg" in
		.layers/*|build/*) ;;
		*) [ -d "$wt/$pkg" ] || continue ;;
	esac
	for entry in "$main/$lib"/*; do
		[ -e "$entry" ] || continue
		name=$(basename "$entry")
		case "$name" in
			# WhyNot: Maven の cache は symlink — 中身は版ごとの置き場で、書かれるのは足りない物の追加だけ。
			# main と共有すれば、どちらかで取った物がもう一方でも Maven へ行かずに済む。
			# make clean-locks の find は symlink の先へ降りないので、worktree から main の lock は消えない。
			cache) seed symlink "$lib/$name" ;;
			# WhyNot: external・github は symlink にしない — make gl-jar が lib/external の fge-gl-*.jar を消して置き直し、
			# github の fpkg は make sync が張り直す。symlink だと worktree の作業が main の lib を書き換える。
			# github の中の相対 symlink は写した先でも相対のまま残り、worktree の engine_full を指す。
			*) seed clone "$lib/$name" ;;
		esac
	done
done

# WhyNot: flix.jar は symlink — 手で置くコンパイラで、make のどのターゲットも書き換えない。
seed symlink bin/flix.jar
# WhyNot: fge-go と dist は clone — make go-build が worktree の go/ から組み直す。symlink だと main の検査の中身を
# worktree の go/ で上書きし、macOS は中身の変わった実行ファイルを次の起動で止める。
seed clone bin/fge-go
seed clone bin/dist
# WhyNot: gl-jar は clone — make gl-jar が classes/ を消して組み直す。clone の時刻は今になるので、
# worktree の render_gl/java が main と同じなら組み直しは起きない。
seed clone build/gl-jar
# WhyNot: package.fpkg は clone — make sync-engine-full の build-pkg が書く。テンプレの lib/github の相対 symlink がこれを指す。
seed clone engine_full/artifact/package.fpkg
# WhyNot: engine_full.fpkg は symlink — 作業コピーでは誰も書かない（check-docs-sync が有無を見るだけ）。
seed symlink engine_full/artifact/engine_full.fpkg

echo "[worktree-seed] $main → $wt"
grep '^張った' "$report"
grep '^飛ばした' "$report" | grep -v '（main に無い）'
missing=$(grep -c '（main に無い）' "$report")
[ "$missing" -eq 0 ] || echo "飛ばした  main に無い物 ${missing} 件: $(grep '（main に無い）' "$report" | sed 's/^飛ばした  //; s/（main に無い）//' | tr '\n' ' ')"
exit 0
