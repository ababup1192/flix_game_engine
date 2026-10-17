package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/verbnames"
)

func init() {
	// WhyNot: engineOnly にしないのは、止めたい書き方が配った先のゲームで起きるため。
	register("verb-names",
		"def の名前の頭の動詞と型のずれ (is/has/can なのに Bool でない・get なのに効果を持つ)",
		cmdVerbNames)
}

func cmdVerbNames(out, errOut *strings.Builder, rest []string, _ bool) int {
	root, rest := declRootFlag(rest)
	code, err := verbnames.Run(out, errOut, root, rest)
	return orAbort(errOut, code, err)
}
