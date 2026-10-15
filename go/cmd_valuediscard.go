package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/valuediscard"
)

func init() {
	// WhyNot: engineOnly にしないのは、配った先のゲームでも同じ穴を踏むため
	// (知らせと bug! が黙って消える)。
	register("value-discard",
		"値を let _ = で捨てていないか (純粋な式だと Flix が呼び出しごと消す)",
		cmdValueDiscard)
}

func cmdValueDiscard(out, errOut *strings.Builder, rest []string, _ bool) int {
	root, rest := declRootFlag(rest)
	code, err := valuediscard.Run(out, errOut, root, rest)
	return orAbort(errOut, code, err)
}
