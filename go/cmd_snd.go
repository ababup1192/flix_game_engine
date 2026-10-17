package main

import (
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/snd"
)

func init() {
	register("snd", "音の指定 (*.sndsrc.json・台本 *.snd.star) を鳴らして検査する (build / gen / snap / compare / ops / schema)", cmdSnd)
}

func cmdSnd(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	cwd, err := os.Getwd()
	if err != nil {
		errOut.WriteString(err.Error() + "\n")
		return 1
	}
	return snd.Run(out, errOut, repoRoot(), cwd, dropJSONFlag(rest), asJSON)
}
