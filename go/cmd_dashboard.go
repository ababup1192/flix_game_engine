package main

import (
	"os"
	"runtime"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/dashboard"
	"github.com/ababup1192/flix_game_engine/go/internal/fgeinstall"
)

func init() {
	// WhyNot: engineOnly にしないのは、全体の fge（~/.flix_ge/bin/fge）からどこで打っても同じサーバーを立てる物だから（plans/dashboard.md 13 節）。
	register("dashboard",
		"[--port <番号>] [--no-open] [--dir <フォルダ>] で 127.0.0.1:8790 にワークスペースの頁を前面で立てる（ゲームのフォルダで打つとそのゲームを一覧に足して開く）",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			// WhyNot: out に貯めず os.Stdout へ直に書く — 居座るサーバーで、貯めると止めるまで 1 行も出ない。
			return dashboard.Run(dropJSONFlag(rest), os.Stdout, os.Stderr, dashboard.DefaultDeps(runtime.GOOS, fgeinstall.DefaultEnv()))
		})
}
