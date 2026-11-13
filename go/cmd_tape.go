package main

import (
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/tape"
)

func init() {
	register("tape",
		"flow の動画に注釈を付ける頁を束ねる: tape --dir <フォルダ>（tape.json と video.mp4 → strip.jpg と index.html）・tape --group <フォルダ>…（分岐した複数のテープを分岐のカードでつなぐ）・tape publish <フォルダ>…（Pages の置き場へ置いて URL を出す）",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			return tape.Run(rest, os.Stdout, os.Stderr)
		})
}
