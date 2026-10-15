package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/heavy"
)

func init() {
	register("heavy",
		"重い処理を 1 本ずつ流す鍵 (/tmp/fge-heavy.lock)。heavy <コマンド...> / heavy --status",
		func(out, errOut *strings.Builder, rest []string, asJSON bool) int {
			// WhyNot: out に貯めず heavy が os.Stdout へ直に書くのは、流すコマンドの出力を
			// 数分ぶん溜めてから吐くと、呼ぶ側が進み具合も止まった所も見られないため。
			return heavy.Run(rest, asJSON, heavy.Options{})
		})
}
