package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/launcher"
)

// ゲームの根で流す作業（make の run・debug・render・render-all・check・test と、project.json の tasks）。
// make のターゲットはここを呼ぶ 1 行の別名で、Windows では make 無しでこれを打つ（plans/windows.md の 5 節 #4〜#6）。
//
// WhyNot: 出力を out・errOut に溜めない — ゲームのウィンドウ・描き出し・テストは数分走るので、溜めると終わるまで何も見えない。
// 子の出力は端末へそのまま流す。

const launchUsage = `使い方（ゲームの根で）:
  bin/fge run [SHOT=<場面>] [K=V…]        ゲームを起動する（SHOT はギャラリーの 1 枚と同じ World から F8 で止めた状態で開く）
  bin/fge debug [K=V…]                    保存即反映（watchFile）と F8 を有効にして起動する
  bin/fge render <場面>… [K=V…]           1 枚ずつ debug/<場面>.png へ描き出す
  bin/fge render --all [K=V…]             全部 gallery/ へ描き出す（決定的）
  bin/fge render --list                   場面の名前（project.json の shots）
  bin/fge headless <Mod.entry> [K=V…]     ヘッドレスの入口を 1 つ流す（K=V は環境変数）
  bin/fge task [<名前> [K=V…]]            project.json の tasks を流す（名前なしで一覧）
  bin/fge check [CHECKD=0] [QUIET=0]      型検査だけ（全文は .test-logs/check.log）
  bin/fge test                            テストを headless で流す（記録は .test-logs/）
`

func init() {
	register("run", "ゲームを起動する（make run。SHOT=<場面> で F8 で止めた場面から）", launchCmd(runPlay(false)))
	register("debug", "保存即反映と F8 を有効にして起動する（make debug）", launchCmd(runPlay(true)))
	register("render", "場面を描き出す: <場面>… は debug/・--all は gallery/（make render・render-all）", launchCmd(runRender))
	register("headless", "ヘッドレスの入口を 1 つ流す: <Mod.entry> [K=V…]（make の HEADLESS_RUN と同じ）", launchCmd(runHeadless))
	register("task", "project.json の tasks（ゲーム固有の作業）を流す: <名前> [K=V…]・名前なしで一覧", launchCmd(runTask))
	register("lint-flixlint", "lint/rules.flix の規則を型つきの AST で見る（make lint-flixlint・FLIXLINT_STAGE=typed）", launchCmd(func(l *launcher.Launcher, args []string) int {
		vars, rest := launcher.SplitVars(args)
		if len(rest) > 0 {
			fmt.Fprint(os.Stderr, launchUsage)
			return 2
		}
		return l.LintFlixlint(vars)
	}))
	register("test", "テストを headless で流す（make test・記録は .test-logs/）", launchCmd(func(l *launcher.Launcher, args []string) int {
		vars, rest := launcher.SplitVars(args)
		if len(rest) > 0 {
			fmt.Fprint(os.Stderr, launchUsage)
			return 2
		}
		return l.Test(vars)
	}))
}

// launchCmd はゲームの根（今の場所）で Launcher を作って fn を流す Handler。
//
// WhyNot: repoRoot（fge-go の置き場）を根にしない — engine の中のテンプレートで流すと engine の根を指す。make と同じく今の場所で流す。
func launchCmd(fn func(*launcher.Launcher, []string) int) Handler {
	return func(_, errOut *strings.Builder, rest []string, _ bool) int {
		if hasFlag(rest, "--help") || hasFlag(rest, "-h") {
			fmt.Fprint(os.Stdout, launchUsage)
			return 0
		}
		root, err := os.Getwd()
		if err != nil {
			return orAbort(errOut, 2, err)
		}
		l, err := launcher.New(root)
		if err != nil {
			return orAbort(errOut, 2, err)
		}
		return fn(l, rest)
	}
}

func runPlay(debug bool) func(*launcher.Launcher, []string) int {
	return func(l *launcher.Launcher, args []string) int {
		vars, rest := launcher.SplitVars(args)
		if len(rest) > 0 {
			fmt.Fprint(os.Stderr, launchUsage)
			return 2
		}
		shot := vars["SHOT"]
		delete(vars, "SHOT")
		return l.Play(shot, debug, vars)
	}
}

func runRender(l *launcher.Launcher, args []string) int {
	vars, rest := launcher.SplitVars(args)
	switch {
	case hasFlag(rest, "--list"):
		fmt.Println(strings.Join(l.Project.Shots, " "))
		return 0
	case hasFlag(rest, "--all"):
		if len(rest) > 1 {
			fmt.Fprint(os.Stderr, launchUsage)
			return 2
		}
		return l.RenderAll(vars)
	}
	shots := rest
	if s := vars["SHOT"]; s != "" {
		shots = append(strings.Fields(s), shots...)
		delete(vars, "SHOT")
	}
	if len(shots) == 0 {
		fmt.Fprintln(os.Stderr, "使い方: bin/fge render <場面>…   1 枚ずつ debug/<場面>.png へ描き出す")
		fmt.Fprintln(os.Stderr, "        bin/fge render --all     全部 gallery/ へ描き出す")
		if len(l.Project.Shots) > 0 {
			fmt.Fprintf(os.Stderr, "  場面: %s\n", strings.Join(l.Project.Shots, " "))
		}
		return 1
	}
	return l.Render(shots, vars)
}

func runHeadless(l *launcher.Launcher, args []string) int {
	vars, rest := launcher.SplitVars(args)
	if len(rest) != 1 || strings.HasPrefix(rest[0], "-") {
		fmt.Fprintln(os.Stderr, "使い方: bin/fge headless <Mod.entry> [K=V…]   例: bin/fge headless SceneRender.all")
		return 2
	}
	return l.Headless(rest[0], vars)
}

func runTask(l *launcher.Launcher, args []string) int {
	vars, rest := launcher.SplitVars(args)
	if len(rest) == 0 {
		fmt.Println("使い方: bin/fge task <名前> [K=V…]   project.json の tasks:")
		l.ListTasks(os.Stdout)
		return 0
	}
	if len(rest) > 1 {
		fmt.Fprint(os.Stderr, launchUsage)
		return 2
	}
	return l.Task(rest[0], vars)
}
