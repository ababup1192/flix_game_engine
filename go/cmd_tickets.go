package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/tickets"
)

func init() {
	register("tickets",
		"F8 のチケットを閉じる（直したコミット・どの前の直しで生まれたか）・前の直しの候補・直しが次の不具合を生んだ率: tickets close / suspects / stats",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			code, err := tickets.Run(out, errOut, repoRoot(), rest)
			return orAbort(errOut, code, err)
		})
}
