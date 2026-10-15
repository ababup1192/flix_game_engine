package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/recordwrap"
)

func init() {
	// WhyNot: engineOnly にしないのは、World が大きくなって flix check が伸びるのは
	// 配った先のゲームの側だから。
	register("record-wrap",
		"World が直接持つ大きな record を enum で包んでいるか (包まないと flix check の時間とメモリが伸びる)",
		cmdRecordWrap)
}

func cmdRecordWrap(out, errOut *strings.Builder, rest []string, _ bool) int {
	root, rest := declRootFlag(rest)
	code, err := recordwrap.Run(out, errOut, root, rest)
	return orAbort(errOut, code, err)
}
