package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/heavy"
	"github.com/ababup1192/flix_game_engine/go/internal/refactor"
)

func init() {
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
	return refactor.Run(out, errOut, root, rest, refactor.Options{Run: heavyRunner, Verify: heavyVerify, Log: os.Stderr})
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
func heavyRunner(stage refactor.Stage, desc, dir string, cmd []string, log string) int {
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
	return heavy.Hold(cmd, dir, heavy.Options{}, func(run heavy.Runner) int {
		return run(dir, "sh", "-c", cmd+" > \""+log+"\" 2>&1")
	})
}
