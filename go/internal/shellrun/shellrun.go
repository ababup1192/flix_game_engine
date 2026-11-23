// Package shellrun は、engine の sh のスクリプト（bin/flix・bin/headless-run・bin/with-sample-tests など）を Go から起こす所を 1 か所に持つ。
//
// macOS と Linux はスクリプトを直に起こす。Windows は Git for Windows の bash.exe に渡す（plans/windows.md の 3 節 2・12 節）。
// bash の場所は CLAUDE_CODE_GIT_BASH_PATH → Git for Windows の bin\bash.exe（既定の置き場・PATH の git.exe の隣）の順で探す。
//
// WhyNot: PATH から bash.exe を探さない — System32\bash.exe は WSL を起こす物で、Windows のパスを読めない別の機械の bash になる。
// WhyNot: Git の usr\bin\bash.exe を使わない — bin\bash.exe は PATH に Git の道具（usr\bin・mingw64\bin）を足してから起こす入口で、
// usr\bin の物を直に起こすと sed・perl・cygpath が PATH に無いまま走る。
package shellrun

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

// GitBashEnv は Claude Code が Git Bash の場所に読む環境変数（code.claude.com の setup）。同じ物を読んで、AI と人の bash をそろえる。
const GitBashEnv = "CLAUDE_CODE_GIT_BASH_PATH"

// Host は bash を探すのに見る外の物。テストが GOOS・環境変数・ファイルを差し替える。
type Host struct {
	GOOS     string
	Getenv   func(string) string
	IsFile   func(string) bool
	LookPath func(string) (string, error)
}

// Native は今の機械の Host。
func Native() Host {
	return Host{GOOS: runtime.GOOS, Getenv: os.Getenv, IsFile: isFile, LookPath: exec.LookPath}
}

// ErrNoBash は Windows で Git for Windows の bash が見つからない時の誤り。
var ErrNoBash = errors.New("Git for Windows の bash.exe が見つかりません（Git for Windows を入れるか、" + GitBashEnv + " に bash.exe の場所を書いてください）")

// FindBash は Windows でスクリプトを渡す bash.exe の場所。Windows でなければ "" と nil（直に起こす）。
func (h Host) FindBash() (string, error) {
	if h.GOOS != "windows" {
		return "", nil
	}
	if p := strings.TrimSpace(h.Getenv(GitBashEnv)); p != "" {
		if h.IsFile(p) {
			return p, nil
		}
		return "", fmt.Errorf("%s が指す %s がありません", GitBashEnv, p)
	}
	for _, c := range h.bashCandidates() {
		if h.IsFile(c) {
			return c, nil
		}
	}
	return "", ErrNoBash
}

// bashCandidates は Git for Windows の bin\bash.exe を探す順（既定の置き場 → PATH の git.exe の隣）。
func (h Host) bashCandidates() []string {
	var out []string
	for _, env := range []string{"ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"} {
		if d := h.Getenv(env); d != "" {
			out = append(out, winJoin(d, "Git", "bin", "bash.exe"))
		}
	}
	if d := h.Getenv("LocalAppData"); d != "" {
		out = append(out, winJoin(d, "Programs", "Git", "bin", "bash.exe"))
	}
	// git.exe は <Git>\cmd\git.exe か <Git>\bin\git.exe（mingw64\bin の物もある）。どれでも <Git>\bin\bash.exe へ戻れる。
	if h.LookPath != nil {
		if git, err := h.LookPath("git"); err == nil {
			dir := winDir(git)
			for i := 0; i < 3 && dir != ""; i++ {
				out = append(out, winJoin(dir, "bin", "bash.exe"))
				dir = winDir(dir)
			}
		}
	}
	return out
}

// Command はスクリプト script を args で起こす *exec.Cmd。Windows では bash.exe に script を渡す。
func (h Host) Command(script string, args ...string) (*exec.Cmd, error) {
	bash, err := h.FindBash()
	if err != nil {
		return nil, err
	}
	if bash == "" {
		return exec.Command(script, args...), nil
	}
	return exec.Command(bash, append([]string{filepath.ToSlash(script)}, args...)...), nil
}

// Command は今の機械で script を起こす *exec.Cmd（Native().Command）。
func Command(script string, args ...string) (*exec.Cmd, error) {
	return Native().Command(script, args...)
}

// IsRunnable は path がスクリプトとして起こせる普通のファイルか。Windows は実行ビットを持たないので、在るかだけを見る。
func IsRunnable(path string) bool {
	return isRunnable(runtime.GOOS, path)
}

func isRunnable(goos, path string) bool {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return false
	}
	return goos == "windows" || info.Mode().Perm()&0o111 != 0
}

var msysDriveRe = regexp.MustCompile(`^/([A-Za-z])(/|$)`)

// NativePath は bash が出したパスを、その OS の java.exe・Go が読める形にする。Windows では MSYS の /c/x/y を C:/x/y に。
// ほかの OS と、もう C:/ の形のパスはそのまま返す（bin/flix が cygpath -m を通した物と、通す前の物の両方を読む）。
func NativePath(goos, p string) string {
	if goos != "windows" {
		return p
	}
	if m := msysDriveRe.FindStringSubmatch(p); m != nil {
		return strings.ToUpper(m[1]) + ":/" + strings.TrimPrefix(p[len(m[0]):], "/")
	}
	return p
}

func isFile(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.Mode().IsRegular()
}

// winJoin・winDir は Windows のパスを、Linux で走るテストでも同じ字で組む（filepath は走っている OS の区切りを使う）。
func winJoin(parts ...string) string {
	out := strings.TrimRight(parts[0], `\/`)
	for _, p := range parts[1:] {
		out += `\` + strings.Trim(p, `\/`)
	}
	return out
}

func winDir(p string) string {
	p = strings.TrimRight(p, `\/`)
	i := strings.LastIndexAny(p, `\/`)
	if i <= 0 {
		return ""
	}
	return p[:i]
}
