package makefiledup

import (
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
)

const gameMk = `.PHONY: run render
run:
	@echo run
render render-all:
	@echo render
$(PALETTE): x
	@echo pal
`

func run(t *testing.T, root string, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, args)
	if err != nil {
		t.Fatal(err)
	}
	return code, out.String() + errOut.String()
}

// game.mk を include するゲームの Makefile が共通の口にレシピを書いたら止める。
// 前提を足すだけの行・ターゲット別の変数・固有の口は止めない。
func TestRecipeOnCommonTargetFires(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"engine/mk/game.mk": gameMk,
		"local.mk":          "ENGINE := engine\n",
		"Makefile": `include $(ENGINE)/mk/game.mk
render-all: extra-art
render: SHOTS = title
lab:
	@echo lab
run:
	@echo my run
`,
	})
	t.Setenv("ENGINE", "")
	code, msg := run(t, root, "Makefile")
	if code != 1 || !strings.Contains(msg, "Makefile:6 run は engine の mk/game.mk") || strings.Count(msg, "!! ") != 1 ||
		!strings.Contains(msg, "変数（SHOTS") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// engine のリポでは隣に mk/game.mk がある Makefile (engine 自身) と、game.mk を
// include しない Makefile (bench) を見ない。templates/*/Makefile は見る。
func TestEngineRepoScope(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"mk/game.mk":           gameMk,
		"Makefile":             "run:\n\t@echo engine\n",
		"bench/b/Makefile":     "run:\n\t@echo bench\n",
		"templates/t/Makefile": "include $(ENGINE)/mk/game.mk\nrender: ; @echo x\n",
	})
	code, msg := run(t, root, "Makefile", "bench/b/Makefile", "templates/t/Makefile")
	if code != 1 || strings.Count(msg, "!! ") != 1 || !strings.Contains(msg, "templates/t/Makefile:2 render") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// game.mk が見つからなければ止めない (fail-open)・ゲームの除外で黙る。
func TestFailOpenAndExempt(t *testing.T) {
	t.Setenv("ENGINE", "")
	root := lintconf.TestRepo(t, Name, map[string]string{
		"Makefile": "include $(ENGINE)/mk/game.mk\nrun:\n\t@echo x\n",
	})
	if code, msg := run(t, root, "Makefile"); code != 0 || !strings.Contains(msg, "見つからないので飛ばします") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
	root = lintconf.TestRepo(t, Name, map[string]string{
		"engine/mk/game.mk":                      gameMk,
		"local.mk":                               "ENGINE := engine\n",
		"Makefile":                               "include $(ENGINE)/mk/game.mk\nrun:\n\t@echo x\n",
		"bin/lint-rules/makefile-dup.local.json": `{"exempt":{"Makefile::run":"起動の前に音を焼く"}}`,
	})
	if code, msg := run(t, root, "Makefile"); code != 0 {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}
