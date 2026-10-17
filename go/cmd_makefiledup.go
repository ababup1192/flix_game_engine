package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/makefiledup"
)

func init() {
	// WhyNot: engineOnly にしないのは、止めたい書き方が配った先のゲームで起きるため。
	register("makefile-dup",
		"ゲームの Makefile が engine の mk/game.mk にある共通の口を作り直していないか",
		cmdMakefileDup)
}

func cmdMakefileDup(out, errOut *strings.Builder, rest []string, _ bool) int {
	root, rest := declRootFlag(rest)
	code, err := makefiledup.Run(out, errOut, root, rest)
	return orAbort(errOut, code, err)
}
