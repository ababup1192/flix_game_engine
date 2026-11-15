package main

import (
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/yarn"
)

func init() {
	register("yarn", "会話のシナリオ (*.yarn・Yarn Spinner の部分集合) を読んで検査し、木の JSON を書く (build / check / graph / script / help)", cmdYarn)
}

func cmdYarn(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	cwd, err := os.Getwd()
	if err != nil {
		errOut.WriteString(err.Error() + "\n")
		return 1
	}
	// WhyNot: graph は asJSON の道へ入れない —— graph の --json は書き先を取る引数で、Report の 1 行とは別の物。
	if asJSON && (len(rest) == 0 || rest[0] != "graph") {
		rep, code := yarn.RunJSON(cwd, dropJSONFlag(rest))
		emitJSON(out, rep)
		return code
	}
	if len(rest) > 0 && rest[0] == "graph" {
		return yarn.Run(out, errOut, cwd, rest)
	}
	return yarn.Run(out, errOut, cwd, dropJSONFlag(rest))
}
