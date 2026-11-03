package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/maxlines"
)

func init() {
	registerEngineOnly("max-lines",
		"engine の 4 パッケージの src の .flix が上限の行数を超えていないか（超えている物は除外の一覧に）",
		cmdMaxLines)
}

func cmdMaxLines(out, errOut *strings.Builder, rest []string, _ bool) int {
	root, rest := declRootFlag(rest)
	code, err := maxlines.Run(out, errOut, root, rest)
	return orAbort(errOut, code, err)
}
