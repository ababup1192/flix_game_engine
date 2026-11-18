package main

import (
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/worktreegc"
)

func init() {
	register("worktree-gc",
		"取り込み済み・変更なし・使っているプロセスなしの git worktree を一覧にする（--apply で git worktree remove・枝は残す）",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			dir, _ := os.Getwd()
			code, err := worktreegc.Run(out, errOut, dir, rest)
			return orAbort(errOut, code, err)
		})
}
