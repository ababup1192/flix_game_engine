package main

import (
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/yarn"
)

func init() {
	register("yarn", "会話のシナリオ (*.yarn・Yarn Spinner の部分集合) を読んで検査し、木の JSON を書く (build / check / help)", cmdYarn)
}

func cmdYarn(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	cwd, err := os.Getwd()
	if err != nil {
		errOut.WriteString(err.Error() + "\n")
		return 1
	}
	return yarn.Run(out, errOut, cwd, dropJSONFlag(rest))
}
