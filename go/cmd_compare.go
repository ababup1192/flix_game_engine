package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/compare"
)

func init() {
	register("compare",
		"基準の版 (--base <ref>) と今の作業場を同じ描き出しで並べ、差を debug/compare/ に書く (make compare)",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			// WhyNot: out に貯めないのは、2 回の描き出し（数分）の間も進み具合を流すため。
			return compare.Run(rest, compare.Options{})
		})
}
