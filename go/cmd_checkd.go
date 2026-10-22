package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/checkd"
)

func init() {
	register("checkd", "make check の速い道: check を flixlint の常駐で・答えの版をディスクと比べて使う (test は素の flix test。詳細は docs/checkd.md)",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			code, err := checkd.Run(out, errOut, repoRoot(), rest)
			return orAbort(errOut, code, err)
		})
}
