#!/bin/sh
# flix-packages.sh — <根> の下で flix.toml を持ち、lib/ が育っている Flix のパッケージを、根からの相対パスで 1 行ずつ出す。
# 根そのものがパッケージなら `.` を出す。worktree-seed.sh と mvn-cache-share.sh が使う。
#
#     bin/flix-packages.sh <根>
#
# WhyNot: ./build の直下は拾う — build/engine_full_web は make が組み立てるパッケージで、lib を持つ。
# それより深い build/ は組んだ class の山か、配る版の組み立ての写し (build/bundle) なので歩かない。
# WhyNot: lib/ の無い flix.toml は出さない — testdata の見本や artifact/ の写しで、依存を解決しない。
set -u
root=${1:?使い方: bin/flix-packages.sh <根>}
cd "$root" || exit 2
find . \
	\( -path ./.git -o -path ./.claude -o -path ./.devbox -o -path './*/build' -o \( -path './build/*/*' -type d \) \
	   -o -name node_modules -o -name src -o -name test -o -name artifact \) -prune \
	-o -name flix.toml -print 2>/dev/null | sed 's|/flix.toml$||; s|^\./||' | sort |
while read -r pkg; do
	[ -d "$pkg/lib" ] && echo "$pkg"
done
exit 0
