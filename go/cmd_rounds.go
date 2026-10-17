package main

import (
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/rounds"
)

func init() {
	register("rounds",
		"絵の周回を debug/history/<名前>/ に積み、止まって依頼主に聞く所を案内する。rounds snap <名前> <PNG か sprite.json> <台本> / rounds restore <名前> rN <台本>",
		cmdRounds)
}

// WhyNot: ゲームのルートを repoRoot ではなくカレントディレクトリにするのは、
// engine のリポから templates/ の下のゲームで流すときも、積む先が流した場所になるため。
// 規約データ (bin/lint-rules/rounds.json) は配られた先にもあるので repoRoot から読む。
func cmdRounds(out, errOut *strings.Builder, rest []string, _ bool) int {
	cwd, err := os.Getwd()
	if err != nil {
		return orAbort(errOut, 2, err)
	}
	code, err := rounds.Run(out, errOut, repoRoot(), cwd, rest)
	return orAbort(errOut, code, err)
}
