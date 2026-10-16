package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxkit"
)

func init() {
	register("pxkit", "形の指定 (*.spritesrc.json) からドット絵を打ち起こす (build / watch / snap)", cmdPxkit)
}

func cmdPxkit(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	// watch は止めるまで戻らないので、1 回ごとの結果をその場で流す。
	live := func(s string) { fmt.Fprint(os.Stdout, s) }
	return pxkit.Run(out, errOut, repoRoot(), dropJSONFlag(rest), live)
}
