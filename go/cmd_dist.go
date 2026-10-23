package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/dist"
)

func init() {
	register("dist",
		"ゲームの jar・その OS の JRE・起動を 1 本の配布物にまとめる。dist <linux|macos|windows|all>。ゲームの根で make dist-<OS> から呼ぶ",
		func(out, errOut *strings.Builder, rest []string, asJSON bool) int {
			return dist.Run(out, errOut, dropJSONFlag(rest))
		})
}
