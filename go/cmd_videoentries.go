package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/videoentries"
)

func init() {
	register("video-entries",
		"動画の見回りが流す入口の一覧を Makefile の $(call video,…) から書き出す (--check で食い違いを止める)",
		cmdVideoEntries)
}

func cmdVideoEntries(out, errOut *strings.Builder, rest []string, _ bool) int {
	root, rest := declRootFlag(rest)
	code, err := videoentries.Run(out, root, hasFlag(rest, "--check"))
	return orAbort(errOut, code, err)
}
