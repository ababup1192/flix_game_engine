package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/heavy"
	"github.com/ababup1192/flix_game_engine/go/internal/refactor"
)

func init() {
	// WhyNot: engineOnly にしないのは、直したい Flix のコードが配った先のゲームにあるため（engine の src にも効く）。
	register("refactor",
		"Flix の名前の位置の索引（flixlint --spans）で数える（refs・match-sites・field-sites）・書き換える（expand-wildcard・remove-dead・field-to-accessor。既定は dry-run）。refactor --help",
		cmdRefactor)
}

func cmdRefactor(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	root, rest := declRootFlag(rest)
	if asJSON {
		rest = append(dropJSONFlag(rest), "--json")
	}
	return refactor.Run(out, errOut, root, rest, refactor.Options{Run: heavyRunner, Verify: heavyVerify, Log: os.Stderr})
}

// heavyRunner は索引を作る flixlint を heavy の枠の中で流す。resolved（2 GB・数秒）は短い物、typed（4〜5 GB・20〜60 秒）は長い物。
// WhyNot: typed を短い物にしないのは、短い物の枠は make test と同時に走り、5 GB の JVM が 2 本並ぶとマシンが詰まるため。
func heavyRunner(stage refactor.Stage, desc, dir string, cmd []string) int {
	return heavy.Hold(desc, dir, heavy.Options{Long: stage == refactor.Typed, Short: stage != refactor.Typed}, func(run heavy.Runner) int {
		return run(dir, cmd...)
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
