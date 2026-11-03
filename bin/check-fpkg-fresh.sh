#!/bin/sh
# check-fpkg-fresh.sh — engine のソース（.flix）が engine_full の fpkg より新しければ exit 1。
# 基準と比べる口（baseline-check・check-external）が、make sync-engine-full を忘れた古い engine を検査して偽の緑を出さないため。
engine=$(cd "$(dirname "$0")/.." && pwd)
fpkg="$engine/engine_full/artifact/package.fpkg"
if [ ! -f "$fpkg" ]; then
	echo "error: $fpkg が無い。先に make sync-engine-full" >&2
	exit 1
fi
stale=$(cd "$engine" && find engine/src render_gl/src engine_world/src engine_tools/src -name '*.flix' -newer "$fpkg" 2>/dev/null | head -1)
if [ -n "$stale" ]; then
	echo "error: engine_full の fpkg が engine のソースより古い（${stale} が新しい）。先に make sync-engine-full" >&2
	exit 1
fi
