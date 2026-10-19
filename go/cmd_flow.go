package main

import (
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/flow"
)

func init() {
	register("flow",
		"e2e/<名前>.flow を読む（check・JVM なし）・画面なしで流す（run）・語彙を書き直す（vocab）",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			// WhyNot: repoRoot（fge-go の置き場）を使わないのは、engine の中の雛形で流すと engine の根を指すため。
			// flow はゲームの根（make を流す所）で読む。
			root, _ := os.Getwd()
			code, err := flow.Run(out, errOut, root, rest)
			return orAbort(errOut, code, err)
		})
}
