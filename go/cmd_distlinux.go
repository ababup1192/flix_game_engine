package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/distlinux"
)

func init() {
	register("dist-linux",
		"ゲームの jar・Linux x64 の JRE・run.sh を 1 本の tar.gz にまとめる (Steam Deck 向け)。ゲームの根で make dist-linux から呼ぶ",
		func(out, errOut *strings.Builder, rest []string, asJSON bool) int {
			return distlinux.Run(out, errOut, dropJSONFlag(rest))
		})
}
