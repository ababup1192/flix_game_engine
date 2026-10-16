package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/heavy"
)

func init() {
	register("heavy",
		"重い処理を枠 (既定 3 本・長い物は枠 1〜2 の 2 本まで・枠 3 は短い物だけ) で流す鍵 (/tmp/fge-heavy.lock)。heavy [--long|--short] <コマンド...> / heavy --status",
		func(out, errOut *strings.Builder, rest []string, asJSON bool) int {
			// WhyNot: out に貯めず heavy が os.Stdout へ直に書くのは、流すコマンドの出力を
			// 数分ぶん溜めてから吐くと、呼ぶ側が進み具合も止まった所も見られないため。
			return heavy.Run(rest, asJSON, heavy.Options{})
		})
}
