package main

import (
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/migrate"
)

func init() {
	register("migrate",
		"ゲームを新しいテンプレートへ移す前と後の記録を突き合わせる: migrate diff <baseline> <new>（tape.json・world の層のコマ・古いセーブの読み戻し・カバー率 → 頁）・migrate shoot <名前> <flow>...（flow を並べて流し記録を撮る）・migrate video --old --new --out（2 本を左右に並べた mp4）",
		func(_, _ *strings.Builder, rest []string, _ bool) int {
			return migrate.Run(rest, os.Stdout, os.Stderr)
		})
}
