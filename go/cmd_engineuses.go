package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/engineuses"
)

func init() {
	// WhyNot: engineOnly にしないのは、直すのが配った先のゲームのソースだから。
	register("engine-uses",
		"engine の名前を取り込む `use fge::{...}` を mod ごとに足す (mount 名は flix.toml から。--check で検査だけ)",
		cmdEngineUses)
}

func cmdEngineUses(out, errOut *strings.Builder, rest []string, _ bool) int {
	root, rest := declRootFlag(rest)
	mount, rest, _ := declValueFlag(rest, "--mount")
	src, rest, _ := declValueFlag(rest, "--engine-src")
	check := false
	for _, a := range rest {
		if a == "--check" {
			check = true
		}
	}
	code, err := engineuses.Run(out, errOut, engineuses.Options{
		Root: root, Mount: mount, EngineSrc: src, Check: check,
	})
	return orAbort(errOut, code, err)
}
