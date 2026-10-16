package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/agenteval"
)

func init() {
	// WhyNot: engineOnly にしないのは、お題はゲームごとにも置き、ゲームの足元で
	// そのゲームの AGENTS.md を読む新しいエージェントを測るため。
	register("agent-eval",
		"何も教えていないエージェントがお題に正しい道具を選べるか (claude -p で測って表にする)",
		cmdAgentEval)
}

func cmdAgentEval(out, errOut *strings.Builder, rest []string, _ bool) int {
	code, err := agenteval.Run(out, errOut, rest)
	return orAbort(errOut, code, err)
}
