package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/checkd"
	"github.com/ababup1192/flix_game_engine/go/internal/heavy"
	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
	"github.com/ababup1192/flix_game_engine/go/internal/refactorhost"
	"github.com/ababup1192/flixlint/go/refactor"
)

func init() {
	// 道具の本体は flixlint（flix-search・flix-refactor）。エンジンの決まり（engine の置き場・doc-refs・呼び方）を差し込む。
	refactor.SetHost(refactorhost.Hooks())
	// WhyNot: engineOnly にしないのは、直したい Flix のコードが配った先のゲームにあるため（engine の src にも効く）。
	register("refactor",
		"Flix の名前の位置の索引（flixlint --spans）で探す（usages: 使われ所・呼び手の階層・--unused）・数える（refs・match-sites・field-sites）・書き換える（expand-wildcard・remove-dead・field-to-accessor・remove-field・fix-construction・rewrite（式を型紙で書き替える）。既定は dry-run）。refactor --help",
		cmdRefactor)
}

func cmdRefactor(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	root, rest, ok := declValueFlag(rest, "--root")
	if !ok {
		root = refactorRoot()
	}
	if asJSON {
		rest = append(dropJSONFlag(rest), "--json")
	}
	return refactor.Run(out, errOut, root, rest, refactor.Options{Run: heavyRunner, Verify: heavyVerify, Log: os.Stderr, Shared: sharedServer(root)})
}

// sharedServer は make check（checkd の server の道）の常駐と同じ jar・ヒープ・寿命。ゲームの hooks.json に checkd.server が
// 無いか jar を用意できなければ空（flixlint の既定の jar で、索引だけの常駐になる）。
func sharedServer(root string) refactor.Shared {
	r, err := hooks.LoadRules(root)
	if err != nil {
		return refactor.Shared{}
	}
	s, err := checkd.SharedServer(r, repoRoot(), root)
	if err != nil {
		return refactor.Shared{}
	}
	return refactor.Shared{FlixJar: s.FlixJar, ShimJar: s.ShimJar, HeapMB: s.HeapMB, IdleMinutes: s.IdleMinutes}
}

// refactorRoot は --root が無い時の根: FGE_ROOT → 今の所から上へ flix.toml のある所 → repoRoot（bin/fge-go の親の親）。
// WhyNot: repoRoot だけにしないのは、engine の bin/fge-go を名指しして流すと engine の根になり、ゲームの中で
// 打っても --root が要ったため。
func refactorRoot() string {
	if v := os.Getenv("FGE_ROOT"); v != "" {
		return v
	}
	if dir, err := os.Getwd(); err == nil {
		for d := dir; ; d = filepath.Dir(d) {
			if info, err := os.Stat(filepath.Join(d, "flix.toml")); err == nil && !info.IsDir() {
				return d
			}
			if filepath.Dir(d) == d {
				break
			}
		}
	}
	return repoRoot()
}

// heavyRunner は索引を作る flixlint を heavy の枠の中で流す。resolved（2 GB・数秒）は短い物、typed（4〜5 GB・20〜60 秒）は長い物。
// log が空でなければ出力をそのファイルへ書く（--verbose でない時。画面には refactor の 1 行だけ）。
// WhyNot: typed を短い物にしないのは、短い物の枠は make test と同時に走り、5 GB の JVM が 2 本並ぶとマシンが詰まるため。
// 常駐で作る索引（--resident）は heavy の枠を取らない: 仕事は常駐の JVM 1 本が並べて流し、ここで立つのは話すだけの JVM。
// WhyNot: 枠を取ると、make test などの長い物が枠を持っている間、索引が常駐は空いているのに待つ。
func heavyRunner(stage refactor.Stage, desc, dir string, cmd []string, log string) int {
	if containsArg(cmd, "--resident") {
		return runDirect(dir, cmd, log, nil)
	}
	return heavy.Hold(desc, dir, heavy.Options{Long: stage == refactor.Typed, Short: stage != refactor.Typed}, func(run heavy.Runner) int {
		if log == "" {
			return run(dir, cmd...)
		}
		quoted := make([]string, len(cmd))
		for i, c := range cmd {
			quoted[i] = "'" + strings.ReplaceAll(c, "'", `'\''`) + "'"
		}
		return run(dir, "sh", "-c", strings.Join(quoted, " ")+" > '"+strings.ReplaceAll(log, "'", `'\''`)+"' 2>&1")
	})
}

// heavyVerify は書き換えの後の確かめ（make check・make test など）を heavy の枠で流し、出力を全部 log へ書く
// （最初の誤りを拾うため。枠の長短は heavy が名前で決める）。
func heavyVerify(cmd, dir, log string) int {
	fmt.Fprintf(os.Stderr, "[refactor] 確かめ: %s（出力は %s）\n", cmd, log)
	if strings.TrimSpace(cmd) == "make check" {
		// make check は checkd の server の道で、索引と同じ常駐に頼む（heavy の枠を取らず、heavy が入れる CHECKD=0 も避ける）。
		return runDirect(dir, []string{"sh", "-c", cmd}, log, []string{"CHECKD=1", "CHECKD_BACKEND=server"})
	}
	return heavy.Hold(cmd, dir, heavy.Options{}, func(run heavy.Runner) int {
		return run(dir, "sh", "-c", cmd+" > \""+log+"\" 2>&1")
	})
}

func containsArg(cmd []string, a string) bool {
	for _, c := range cmd {
		if c == a {
			return true
		}
	}
	return false
}

// runDirect は cmd を dir で流す（heavy の枠の外）。log が空でなければ出力をそのファイルへ、env は足す環境変数。
func runDirect(dir string, cmd []string, log string, env []string) int {
	c := exec.Command(cmd[0], cmd[1:]...)
	c.Dir = dir
	c.Env = append(os.Environ(), env...)
	if log == "" {
		c.Stdout, c.Stderr = os.Stdout, os.Stderr
	} else {
		f, err := os.Create(log)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[refactor] %s を書けない: %v\n", log, err)
			return 2
		}
		defer f.Close()
		c.Stdout, c.Stderr = f, f
	}
	if err := c.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode()
		}
		fmt.Fprintf(os.Stderr, "[refactor] %s を起動できない: %v\n", cmd[0], err)
		return 2
	}
	return 0
}
