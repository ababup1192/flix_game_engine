package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/hugemethod"
)

func init() {
	register("huge-methods",
		"ビルドした jar か class の中に、JVM が JIT しない大きさ（8,000 バイト超）の Flix の関数が無いか（超えている物は除外の一覧に）",
		cmdHugeMethods)
}

func cmdHugeMethods(out, errOut *strings.Builder, rest []string, _ bool) int {
	root, rest := declRootFlag(rest)
	code, err := hugemethod.Run(out, errOut, root, rest)
	return orAbort(errOut, code, err)
}
