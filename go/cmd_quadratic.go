package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/quadratic"
)

func init() {
	// WhyNot: engineOnly にしないのは、N を決めるのはゲームで、二乗が効いてくるのも
	// 配った先のゲームの側だから。
	register("quadratic",
		"fold の中で蓄積を作り直す二乗の形 (List.append(acc, …) / 文字列を 1 回ごとに足す) が無いか",
		cmdQuadratic)
}

func cmdQuadratic(out, errOut *strings.Builder, rest []string, _ bool) int {
	root, rest := declRootFlag(rest)
	code, err := quadratic.Run(out, errOut, root, rest)
	return orAbort(errOut, code, err)
}
