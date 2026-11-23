// Package cmdhint は、人と AI へ案内する「打つ形」を作業の名前から作る。
//
// make がある macOS と Linux では `make <作業>`、Windows（と make の無い機械）では
// `bin/fge <作業>` を返す。bin/fge にまだ無い作業は、Windows では make の形に
// 「macOS か Linux で」を添える（plans/windows.md 3 節の 5）。
package cmdhint

import (
	"os/exec"
	"runtime"
	"strings"
	"sync"
)

// OutOfScope は bin/fge にまだ無い作業を Windows で案内する時に添える字。
const OutOfScope = "（macOS か Linux で）"

// fgeForms は make のターゲットの名前 → bin/fge の引数。ここに無い作業は make にしか無い。
// WhyNot: make の名前と bin/fge の名前を同じと決め打ちしないのは、reference-update のように
// bin/fge では 2 語に分かれる物があるため。
var fgeForms = map[string]string{
	"status":           "status",
	"check":            "check",
	"test":             "test",
	"run":              "run",
	"debug":            "debug",
	"render":           "render",
	"render-all":       "render --all",
	"headless":         "headless",
	"task":             "task",
	"flow":             "flow",
	"new":              "new",
	"reference-check":  "reference check",
	"reference-update": "reference update",
	"engine-upgrade":   "engine-upgrade",
	"api":              "api",
	"module":           "module",
	"src":              "src",
	"notes-rotate":     "notes-rotate",
}

// rawForms は bin/fge を通さずに打てる作業の、Windows での形（make のレシピが 1 行で済む物）。
var rawForms = map[string]string{
	"hooks": "git config core.hooksPath bin/githooks",
}

var (
	makeOnce  sync.Once
	makeFound bool
)

func hasMake() bool {
	makeOnce.Do(func() {
		_, err := exec.LookPath("make")
		makeFound = err == nil
	})
	return makeFound
}

// Command は作業 task（make のターゲットの名前）を、いま走っている OS で打つ形にする。
// args は K=V の並びなどで、どちらの形にもそのまま後ろへ付く。
func Command(task string, args ...string) string {
	return buildFor(runtime.GOOS, hasMake(), task, args...)
}

// CommandFor は Command の OS を外から渡す形（fge new のように、作る先の OS を注文で受ける所のため）。
// make の有無はこの機械の PATH で見る。
func CommandFor(goos, task string, args ...string) string {
	return buildFor(goos, hasMake(), task, args...)
}

// buildFor は OS と make の有無を外から渡して打つ形を作る（テストが OS を差し替えるため）。
func buildFor(goos string, makeAvailable bool, task string, args ...string) string {
	tail := ""
	if len(args) > 0 {
		tail = " " + strings.Join(args, " ")
	}
	if goos != "windows" && makeAvailable {
		return "make " + task + tail
	}
	if form, ok := fgeForms[task]; ok {
		return "bin/fge " + form + tail
	}
	if form, ok := rawForms[task]; ok {
		return form + tail
	}
	return "make " + task + tail + OutOfScope
}
