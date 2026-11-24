// Package gamesteps はゲームの作業（check・test・描き出し・lint-flixlint・絵の比較）を、new-game と upgrade-game から起こす所。
//
// fge が check・test・render を持っていれば（plans/windows.md 5 節の #4〜#6）その fge を起こし、まだ持っていなければ
// 今までどおりゲームの make を起こす。make を起こす道は macOS と Linux の今の形のため。
package gamesteps

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Runner はゲームの作業を起こす。
type Runner struct {
	// Exe は起こす fge（os.Executable()）。
	Exe string
	// Engine はゲームに渡す engine のフォルダ（環境変数と make の ENGINE）。
	Engine  string
	MakeBin string
	Out     io.Writer
	Err     io.Writer
	// テストが差し替える所。
	Run      func(c *exec.Cmd) error
	List     func(exe string) []string
	LookPath func(name string) (string, error)

	fgeChecked bool
	fgeHas     bool
	gameHas    map[string]bool
}

// New は本物の exec・PATH を使う Runner。
func New(engine string) *Runner {
	exe, _ := os.Executable()
	return &Runner{
		Exe: exe, Engine: engine, MakeBin: "make",
		Out: os.Stdout, Err: os.Stderr,
		Run:      func(c *exec.Cmd) error { return c.Run() },
		List:     listCommands,
		LookPath: exec.LookPath,
	}
}

func listCommands(exe string) []string {
	out, err := exec.Command(exe, "--list").Output()
	if err != nil {
		return nil
	}
	return strings.Fields(string(out))
}

// UsesFge は fge が check・test・render を持つか（無ければ make を起こす）。
//
// WhyNot: check の有無で見ない — 今の fge の check は検査の code の表で、ゲームの型検査ではない。
// test と render は同じ担当が一緒に足すので、2 つそろった時に check もゲームの型検査になっている。
func (r *Runner) UsesFge() bool {
	if !r.fgeChecked {
		r.fgeChecked = true
		names := map[string]bool{}
		if r.Exe != "" {
			for _, n := range r.List(r.Exe) {
				names[n] = true
			}
		}
		r.fgeHas = names["test"] && names["render"]
	}
	return r.fgeHas
}

// Check はゲームの型検査。
func (r *Runner) Check(game string) error { return r.step(game, []string{"check"}, "check") }

// Test はゲームのテスト。
func (r *Runner) Test(game string) error { return r.step(game, []string{"test"}, "test") }

// RenderAll は全部の場面を gallery/ へ描き出す。
func (r *Runner) RenderAll(game string) error {
	return r.step(game, []string{"render", "--all"}, "render-all")
}

// LintFlixlint は lint/rules.flix の規則を流す（lint/rules.flix の無いゲームでは何もしない）。
func (r *Runner) LintFlixlint(game string) error {
	if _, err := os.Stat(filepath.Join(game, "lint", "rules.flix")); err != nil {
		return nil
	}
	return r.step(game, []string{"lint-flixlint"}, "lint-flixlint")
}

// HasReferenceCheck はそのゲームで絵の比較を流せるか。
func (r *Runner) HasReferenceCheck(game string) bool {
	if r.UsesFge() {
		return true
	}
	if _, err := r.LookPath(r.MakeBin); err != nil {
		return false
	}
	c := exec.Command(r.MakeBin, "-C", game, "-n", "reference-check", "ENGINE="+r.Engine)
	return r.Run(c) == nil
}

// ReferenceCheck は全部描き出してから、リファレンス画像と比べる。
func (r *Runner) ReferenceCheck(game string) error {
	exe := gameExe(game)
	if !(exe != "" && r.gameUsesFge(exe)) && !r.UsesFge() {
		return r.runMake(game, "reference-check")
	}
	if err := r.RenderAll(game); err != nil {
		return err
	}
	return r.step(game, []string{"reference", "check"}, "reference-check")
}

// gameExe はゲームの中の bin/fge-go（Windows は fge-go.exe）。無ければ空。
//
// WhyNot: いつも自分（os.Executable()）で流さない — 全体の fge（~/.flix_ge/bin/fge）の隣には規約のファイル（bin/lint-rules）が無く、
// check がすぐ止まる。ゲームの bin/fge-go はそのゲームの engine の版にそろっていて、規約のファイルもゲームの中にある。
func gameExe(game string) string {
	for _, name := range []string{"fge-go", "fge-go.exe"} {
		p := filepath.Join(game, "bin", name)
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return ""
}

// gameUsesFge はゲームの bin/fge-go が check・test・render を持つか。
func (r *Runner) gameUsesFge(exe string) bool {
	if r.gameHas == nil {
		r.gameHas = map[string]bool{}
	}
	if has, ok := r.gameHas[exe]; ok {
		return has
	}
	names := map[string]bool{}
	for _, n := range r.List(exe) {
		names[n] = true
	}
	r.gameHas[exe] = names["test"] && names["render"]
	return r.gameHas[exe]
}

func (r *Runner) step(game string, fgeArgs []string, makeTarget string) error {
	if exe := gameExe(game); exe != "" && r.gameUsesFge(exe) {
		return r.runExe(exe, game, fgeArgs...)
	}
	if r.UsesFge() {
		return r.runFge(game, fgeArgs...)
	}
	if _, err := r.LookPath(r.MakeBin); err != nil {
		return fmt.Errorf("make が無く、%s も `%s` を持っていません（fge を新しくしてください）", r.Exe, strings.Join(fgeArgs, " "))
	}
	return r.runMake(game, makeTarget)
}

func (r *Runner) runFge(game string, args ...string) error {
	return r.runExe(r.Exe, game, args...)
}

func (r *Runner) runExe(exe, game string, args ...string) error {
	c := exec.Command(exe, args...)
	c.Dir = game
	c.Env = append(os.Environ(), "ENGINE="+r.Engine)
	c.Stdout, c.Stderr = r.Out, r.Err
	return r.Run(c)
}

func (r *Runner) runMake(game, target string) error {
	c := exec.Command(r.MakeBin, "--no-print-directory", "-C", game, target, "ENGINE="+r.Engine)
	c.Stdout, c.Stderr = r.Out, r.Err
	return r.Run(c)
}
