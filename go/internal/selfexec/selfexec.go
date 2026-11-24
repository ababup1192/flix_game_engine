// Package selfexec は、今走っている fge 自身のサブコマンドを子のプロセスとして起こす形を組む。
//
// talk の shot・flow の run のように、中で描き出しの入口を流す道具は、`bin/fge headless <入口>` があればそれを起こす。
// 無い版（headless を持たない fge）では呼ぶ側が今までの起こし方を続ける。
//
// WhyNot: bin/headless-run や make を直に起こさない — Windows では make が無く、headless-run は Git Bash で起こす必要があり、
// その決まりは headless の 1 か所に置く（plans/windows.md 5 節 #10・#12）。
// WhyNot: PATH の fge や bin/fge（sh）を起こさない — os.Executable() なら版の食い違いも sh も挟まない。
package selfexec

import (
	"os"
	"os/exec"
	"sync"
)

var (
	mu     sync.Mutex
	lookup func(name string) bool
)

// SetLookup はサブコマンドがこの fge にあるかを答える関数を置く（main が自分の一覧で置く）。
func SetLookup(fn func(name string) bool) {
	mu.Lock()
	defer mu.Unlock()
	lookup = fn
}

// Has はこの fge がサブコマンド name を持つか。
func Has(name string) bool {
	mu.Lock()
	fn := lookup
	mu.Unlock()
	return fn != nil && fn(name)
}

// Headless は `fge headless <entry>` を起こす *exec.Cmd を返す。この fge が headless を持たない・自分の場所が引けない時は ok=false。
func Headless(entry string, args ...string) (cmd *exec.Cmd, ok bool) {
	if !Has("headless") {
		return nil, false
	}
	exe, err := os.Executable()
	if err != nil {
		return nil, false
	}
	return exec.Command(exe, append([]string{"headless", entry}, args...)...), true
}
