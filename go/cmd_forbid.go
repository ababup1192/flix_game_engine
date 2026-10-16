package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/forbid"
)

func init() {
	// WhyNot: engineOnly にしないのは、ゲーム固有の古い書き方 (forbid.local.json) を
	// ゲームの足元で止めるため。
	register("forbid",
		"古い書き方を 1 行の正規表現で止め、代わりに使う物を出す (forbid.json + ゲームの forbid.local.json)",
		cmdForbid)
}

func cmdForbid(out, errOut *strings.Builder, rest []string, _ bool) int {
	root, rest := declRootFlag(rest)
	code, err := forbid.Run(out, errOut, root, rest)
	return orAbort(errOut, code, err)
}
