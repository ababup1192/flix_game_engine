package main

import (
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/f32"
	"github.com/ababup1192/flix_game_engine/go/internal/fallback"
	"github.com/ababup1192/flix_game_engine/go/internal/flixreserved"
	"github.com/ababup1192/flix_game_engine/go/internal/forbid"
	"github.com/ababup1192/flix_game_engine/go/internal/jargon"
	"github.com/ababup1192/flix_game_engine/go/internal/precommit"
	"github.com/ababup1192/flix_game_engine/go/internal/quadratic"
	"github.com/ababup1192/flix_game_engine/go/internal/recordwrap"
	"github.com/ababup1192/flix_game_engine/go/internal/uioverflow"
	"github.com/ababup1192/flix_game_engine/go/internal/valuediscard"
	"github.com/ababup1192/flix_game_engine/go/internal/view"
	"github.com/ababup1192/flix_game_engine/go/internal/ztable"
)

func init() {
	register("precommit", "コミットの直前に走るゲート (bin/ の検査を束ねて裁く)", cmdPrecommit)
}

// lintOf は「(out, errOut, root, 引数) -> (終了コード, エラー)」の検査を precommit へ渡す形にする。
// WhyNot: エラーを握って 0 にしないのは、検査が死んだことを緑と見分けられなくなるため。
func lintOf(fn func(out, errOut *strings.Builder, root string, args []string) (int, error), root string) precommit.Lint {
	return func(out, errOut *strings.Builder, args []string) int {
		code, err := fn(out, errOut, root, args)
		return orAbort(errOut, code, err)
	}
}

// cmdPrecommit はコミット直前のゲート。検査の入口を集めて precommit へ渡す。
//
// WhyNot: 子プロセス (bin/fge-go <サブコマンド>) を起こさないのは、配布先で
// バイナリの置き場を当てにすることになり、fail-open の条件が 1 つ増えるため。
// 出力の並びは precommit 側が決める (検査の出力が先・ゲートの知らせが最後)。
//
// WhyNot: --json を持たないのは、読み手が人 (コミットを止められた人) だけで、
// 機械可読の出力を要る場面が無いため。
func cmdPrecommit(out, errOut *strings.Builder, rest []string, _ bool) int {
	root, rest := declRootFlag(rest)
	abs, err := precommit.ResolveRoot(root)
	if err != nil {
		return orAbort(errOut, 2, err)
	}

	lints := map[string]precommit.Lint{
		"flix-reserved": lintOf(flixreserved.Run, abs),
		"value-discard": lintOf(valuediscard.Run, abs),
		"view":          lintOf(view.Run, abs),
		"fallback":      lintOf(fallback.Run, abs),
		"jargon":        lintOf(jargon.Run, abs),
		"ui-overflow":   lintOf(uioverflow.Run, abs),
		"z-table":       lintOf(ztable.Run, abs),
		"forbid":        lintOf(forbid.Run, abs),
		"quadratic":     lintOf(quadratic.Run, abs),
		"record-wrap":   lintOf(recordwrap.Run, abs),
		"f32": func(o, e *strings.Builder, args []string) int {
			code, err := f32.Run(o, e, abs, args, f32.Options{})
			return orAbort(e, code, err)
		},
		"palette": func(o, _ *strings.Builder, _ []string) int {
			return runPalette(o, abs, false)
		},
	}

	code, err := precommit.Run(out, precommit.Options{
		Root:   abs,
		Args:   rest,
		Stdout: os.Stdout,
		Stderr: os.Stderr,
		Lints:  lints,
		Images: func(root string) int {
			var body strings.Builder
			return runImages(&body, root, false)
		},
	})
	return orAbort(errOut, code, err)
}
