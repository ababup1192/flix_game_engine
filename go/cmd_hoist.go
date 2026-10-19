package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/hoist"
)

func init() {
	// WhyNot: engineOnly にしないのは、画素やコマごとのループはゲームの描き出しにもあり、
	// 同じ書き写しを踏むため (fn-return だけは規約の fnReturnScope でエンジンの塗りの道に絞る)。
	register("hoist",
		"ループの外に置いたつもりの式がループの中へ書き写される形 (関数を返す def・ループのラムダが使う let) が無いか",
		cmdHoist)
}

func cmdHoist(out, errOut *strings.Builder, rest []string, _ bool) int {
	root, rest := declRootFlag(rest)
	code, err := hoist.Run(out, errOut, root, rest)
	return orAbort(errOut, code, err)
}
