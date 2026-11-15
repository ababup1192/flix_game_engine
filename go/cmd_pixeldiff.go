package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/compare"
)

func init() {
	register("pixel-diff",
		"2 枚の PNG を前乗せしない色のまま成分ごとに比べ、違う画素の数と差の最大を出す。--tolerance <tsv> の許す差を超えたら exit 1 (make webgpu-v1-check)",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			return compare.RunPixelDiff(rest, out, errOut)
		})
}
