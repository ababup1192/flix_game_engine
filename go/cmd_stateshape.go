package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/stateshape"
)

func init() {
	// WhyNot: engineOnly にしないのは、止めたい状態の持ち方が配った先のゲームで起きるため。
	register("state-shape",
		"状態の持ち方 (record の Bool の欄の数・Option[Bool]・名指しした enum への case _・View の効果)",
		cmdStateShape)
}

func cmdStateShape(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	root, rest := declRootFlag(rest)
	rest = dropJSONFlag(rest)
	if asJSON {
		rest = append(rest, "--json")
	}
	code, err := stateshape.Run(out, errOut, root, rest)
	return orAbort(errOut, code, err)
}
