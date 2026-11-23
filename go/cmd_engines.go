package main

import (
	"runtime"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/claudeopen"
	"github.com/ababup1192/flix_game_engine/go/internal/fgeinstall"
	"github.com/ababup1192/flix_game_engine/go/internal/newgame"
)

func init() {
	// WhyNot: engineOnly にしないのは、どれも全体の fge（~/.flix_ge/bin/fge）とゲームの bin/fge から
	// 打つ物で、engine のリポの外で使うのが本来の形だから（plans/onboarding.md 2.7）。
	register("engines",
		"手元の engine の版と Release の最新 / install <版|latest> で engine と JDK を取る / remove <版> で消す",
		cmdEngines)
	register("new",
		"<フォルダ名> [--template] [--name] [--title] [--engine] で配った engine から新しいゲームを作る / --list でテンプレートの一覧",
		cmdNew)
	register("self-update",
		"全体の fge（~/.flix_ge/bin/fge）を Release の最新に差し替える",
		cmdSelfUpdate)
	register("open",
		"<ゲームのフォルダ> [--prompt <文>] でそのフォルダの Claude Code を新しい端末に開く",
		cmdOpen)
}

func cmdEngines(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	return fgeinstall.RunEngines(out, errOut, dropJSONFlag(rest), asJSON, fgeinstall.DefaultEnv())
}

func cmdNew(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	return newgame.Run(out, errOut, dropJSONFlag(rest), asJSON, newgame.DefaultDeps(fgeinstall.DefaultEnv()))
}

func cmdSelfUpdate(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	return fgeinstall.RunSelfUpdate(out, errOut, dropJSONFlag(rest), asJSON, fgeinstall.DefaultEnv())
}

func cmdOpen(out, errOut *strings.Builder, rest []string, _ bool) int {
	return claudeopen.Run(out, errOut, dropJSONFlag(rest), claudeopen.DefaultDeps(runtime.GOOS))
}
