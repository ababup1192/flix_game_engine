package main

import (
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/px"
)

func init() {
	register("px", "ドット絵の指定 (*.pxsrc.json) を描いて検査する (build / check / ops / schema / help)", cmdPx)
}

func cmdPx(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	cwd, err := os.Getwd()
	if err != nil {
		errOut.WriteString(err.Error() + "\n")
		return 1
	}
	return px.Run(out, errOut, repoRoot(), cwd, dropJSONFlag(rest), asJSON)
}
