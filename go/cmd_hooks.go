package main

// エージェントのフックの入口。配線は .claude/settings.json（ゲームへ配る形は
// agents-pack/settings.json と agents-pack/codex-hooks.json）。
//
// WhyNot: どのフックも 0 か 2 しか返さないのは、それ以外の終了コードが
// エージェント側で「フックが壊れた」扱いになり、フックの都合で作業を止めるため。
// 2 は「stderr を Claude へ返す」の意味で、作業そのものは進む。

import (
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/anim"
	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
	"github.com/ababup1192/flix_game_engine/go/internal/sprite"
	"github.com/ababup1192/flix_game_engine/go/internal/uioverflow"
	"github.com/ababup1192/flix_game_engine/go/internal/view"
)

func init() {
	register("hook-art-edit", "絵に関わるファイルを書いた直後の検査 (PostToolUse)", cmdHookArtEdit)
	register("hook-flix-touch", "このセッションが .flix を触った印を置く (PostToolUse)", cmdHookFlixTouch)
	register("hook-flix-work", "作業の区切りで Flix を型検査する (Stop / SubagentStop)", cmdHookFlixWork)
	register("hook-flix-edit", "保存 1 回ぶんを常駐へ投げて型検査する (手動確認用)", cmdHookFlixEdit)
	register("hook-asset-guard", "ゲームの assets/ の素材へ直に書くのを止め atelier/ を指す (PreToolUse)", cmdHookAssetGuard)
	register("hook-read-guard", "大きな .flix の丸読み (Read の範囲なし・cat) を止める (PreToolUse)", cmdHookReadGuard)
	register("hook-search-nudge", ".flix の名前を grep で探した後に、索引で引く道具（refactor search・show・usages）を 1 回だけ案内する (PostToolUse)", cmdHookSearchNudge)
	register("hook-session-diet", "廃止・何もしない (古い settings.json の呼び出しを壊さないため口だけ残す)", cmdHookSessionDiet)
}

// hookRoot はフックが規約データ・bin/checkd を探す根。
// WhyNot: repoRoot() をそのまま使わないのは、ゲームのリポジトリで走るとき
// バイナリの置き場ではなくエージェントが開いているリポジトリを見たいため。
func hookRoot() string {
	if v := os.Getenv("CLAUDE_PROJECT_DIR"); v != "" {
		return v
	}
	return repoRoot()
}

func cmdHookArtEdit(_, errOut *strings.Builder, _ []string, _ bool) int {
	root := hookRoot()
	lints := map[string]hooks.Lint{
		"view": func(o, e *strings.Builder, args []string) int {
			code, err := view.Run(o, e, root, args)
			return orAbort(e, code, err)
		},
		"ui-overflow": func(o, e *strings.Builder, args []string) int {
			code, err := uioverflow.Run(o, e, root, args)
			return orAbort(e, code, err)
		},
		"palette": func(o, _ *strings.Builder, _ []string) int {
			return runPalette(o, root, false)
		},
		"sprite": func(o, e *strings.Builder, args []string) int {
			code, err := sprite.Run(o, e, root, args)
			return orAbort(e, code, err)
		},
		"anim": func(o, e *strings.Builder, args []string) int {
			code, err := anim.Run(o, root, args)
			return orAbort(e, code, err)
		},
	}
	return hooks.RunArtEdit(errOut, root, os.Stdin, lints)
}

func cmdHookFlixTouch(_, errOut *strings.Builder, _ []string, _ bool) int {
	return hooks.RunFlixTouch(errOut, hookRoot(), os.Stdin)
}

func cmdHookFlixWork(_, errOut *strings.Builder, _ []string, _ bool) int {
	return hooks.RunFlixWork(errOut, hookRoot(), os.Stdin)
}

func cmdHookFlixEdit(_, errOut *strings.Builder, _ []string, _ bool) int {
	return hooks.RunFlixEdit(errOut, hookRoot(), os.Stdin)
}

func cmdHookSessionDiet(_, errOut *strings.Builder, _ []string, _ bool) int {
	return hooks.RunSessionDiet(errOut, hookRoot(), os.Stdin)
}

// WhyNot: 第 3 引数に repoRoot() を渡すのは、ゲームの hooks.json がまだ古く
// assetGuard・readGuard の節が無いとき、バイナリと一緒に来た規約で門を開けたままにしないため。
func cmdHookAssetGuard(_, errOut *strings.Builder, _ []string, _ bool) int {
	return hooks.RunAssetGuard(errOut, hookRoot(), repoRoot(), os.Stdin)
}

func cmdHookSearchNudge(out, _ *strings.Builder, _ []string, _ bool) int {
	return hooks.RunSearchNudge(out, hookRoot(), repoRoot(), os.Stdin)
}

func cmdHookReadGuard(_, errOut *strings.Builder, _ []string, _ bool) int {
	return hooks.RunReadGuard(errOut, hookRoot(), repoRoot(), os.Stdin)
}
