package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/docshape"
)

func init() {
	// WhyNot: engineOnly にしないのは、止めたい書き方が配った先のゲームで起きるため。
	register("doc-shape",
		"ゲームデータの Doc (assets/ の <名前>.<種類>.json) が version・note・スキーマ・スキーマの label を持つか",
		cmdDocShape)
}

func cmdDocShape(out, errOut *strings.Builder, rest []string, _ bool) int {
	root, rest := declRootFlag(rest)
	code, err := docshape.Run(out, errOut, root, rest)
	return orAbort(errOut, code, err)
}
