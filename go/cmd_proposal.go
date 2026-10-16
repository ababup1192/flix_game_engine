package main

import (
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/proposal"
)

func init() {
	register("proposal",
		"案を並べて選んでもらうページ: proposal build <proposal.json> / proposal knobs [proposal.json...]",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			return proposal.Run(rest, os.Stdout, os.Stderr)
		})
}
