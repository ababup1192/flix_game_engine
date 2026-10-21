#!/usr/bin/env bash
# watchlag.sh — 混んだ機械で、JDK の見回りが保存を flix に届けるまでの秒を測る（docs/checkd.md の作り直しの段 C-0・測る道具 3）。
#
#   bench/checkd/watchlag.sh <パッケージ> [回数=30]
#
# パッケージの src/ の木を、flix の repl と同じく下のディレクトリまで全部見張り（WatchProbe.java）、src/ に置いた 1 ファイル
# （watch-probe.flix。測り終えたら消す）を書き換えては知らせまでの秒を測る。java は flix の呼び口 bin/flix と同じ PATH の java。
# 今の checkd は macOS でこの遅れを最長 11 秒と見て待つ（sources.go の watchLag）。checkd の常駐と同時に流さない（src/ に書くため）。
set -u
pkg=$(cd "${1:?パッケージのディレクトリを渡す}" && pwd)
rounds=${2:-30}
here=$(cd "$(dirname "$0")" && pwd)
out="$pkg/.checkd-c0"; mkdir -p "$out"
java -version 2>&1 | head -1
java "$here/WatchProbe.java" "$pkg/src" "$rounds" | tee "$out/watchlag.tsv"
