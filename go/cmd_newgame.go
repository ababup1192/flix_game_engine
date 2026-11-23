package main

import (
	"flag"
	"fmt"
	"os"
	"runtime"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/gamesteps"
	"github.com/ababup1192/flix_game_engine/go/internal/reference"
	"github.com/ababup1192/flix_game_engine/go/internal/scaffold"
	"github.com/ababup1192/flix_game_engine/go/internal/upgradegame"
)

func init() {
	// WhyNot: new-game と sync-fge-go を engineOnly にするのは、写す元（templates/・engine_full の束・配る fge-go）が engine にしか無いため。
	// 全体の fge の `fge new` は scaffold を直に呼ぶので、こちらを通らない。
	registerEngineOnly("new-game",
		"--game <絶対パス> --name <名前> [--title] [--w] [--h] [--template] [--no-pack-note] でテンプレートから新しいゲームを作る（make new-game の中身）",
		cmdNewGame)
	registerEngineOnly("sync-fge-go",
		"--game <dir> で機械に合う fge-go を 1 つだけゲームの bin/ へ置く（Windows は今の物を .old に退けてから）",
		cmdSyncFgeGo)
	register("reference",
		"check | update [BUDGET=accept] で gallery/ の絵をリファレンス画像（reference/SHA256SUMS.txt）と比べる / 基準を作り直す",
		cmdReference)
	register("engine-upgrade",
		"[TO=<版>] [REFERENCE=1] でゲームの engine の版に追随する / TO= の版へ上げる（make engine-upgrade の中身）",
		cmdEngineUpgrade)
}

// WhyNot: 出力を Builder に溜めずに os.Stdout へ直に流す — 作るのは数分かかり、溜めると止まったと見分けられない。
func cmdNewGame(_, errOut *strings.Builder, rest []string, _ bool) int {
	fs := flag.NewFlagSet("new-game", flag.ContinueOnError)
	fs.SetOutput(errOut)
	var r scaffold.Request
	noPackNote := false
	fs.StringVar(&r.Engine, "engine", repoRoot(), "写す元の engine")
	fs.StringVar(&r.Game, "game", "", "作る先（無いフォルダの絶対パス）")
	fs.StringVar(&r.Name, "name", "", "Flix のパッケージ名")
	fs.StringVar(&r.Title, "title", "", "ウィンドウの題（既定は名前）")
	fs.StringVar(&r.W, "w", "", "design の幅（既定 480）")
	fs.StringVar(&r.H, "h", "", "design の高さ（既定 300）")
	fs.StringVar(&r.Template, "template", "", "写すテンプレート（既定 "+scaffold.DefaultTemplate+"）")
	fs.BoolVar(&noPackNote, "no-pack-note", false, "最後の「配られた物は版上げで上書きされる」の 1 行を出さない")
	if err := fs.Parse(dropJSONFlag(rest)); err != nil {
		return 2
	}
	r.PackNote = !noPackNote
	r.NextSteps = true
	r.GOOS, r.GOARCH = runtime.GOOS, runtime.GOARCH
	if err := scaffold.Create(r, scaffold.DefaultDeps(os.Stdout, gamesteps.New(r.Engine))); err != nil {
		fmt.Fprintf(errOut, "error: %v\n", err)
		return 1
	}
	return 0
}

func cmdSyncFgeGo(out, errOut *strings.Builder, rest []string, _ bool) int {
	game, _, ok := declValueFlag(rest, "--game")
	if !ok || game == "" {
		fmt.Fprintln(errOut, "error: --game を指定してください")
		return 2
	}
	line, err := scaffold.SyncFgeGo(repoRoot(), game, runtime.GOOS, runtime.GOARCH)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	fmt.Fprintln(out, line)
	return 0
}

func cmdReference(_, _ *strings.Builder, rest []string, _ bool) int {
	dir, _ := os.Getwd()
	return reference.Run(dir, dropJSONFlag(rest), reference.DefaultDeps(os.Stdout, os.Stderr))
}

func cmdEngineUpgrade(_, _ *strings.Builder, rest []string, _ bool) int {
	return upgradegame.RunEngineUpgrade(dropJSONFlag(rest), upgradegame.DefaultEngineUpgradeDeps())
}
