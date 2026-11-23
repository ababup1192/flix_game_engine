// Package claudeopen は fge open の本体。ゲームのフォルダの Claude Code を deep link（claude-cli://open）で新しい端末に開く。
// 決まりの本文は plans/onboarding.md の 2.6。
package claudeopen

import (
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

const (
	exitDone     = 0
	exitBadUsage = 2
)

// MaxPromptRunes は deep link の q に載せる字数の上限。
const MaxPromptRunes = 5000

const usage = "使い方: fge open <ゲームのフォルダ> [--prompt <文>]"

// BuildURL は claude-cli://open?cwd=<絶対パス>&q=<文> を組む。
func BuildURL(dir, prompt string) (string, error) {
	if !filepath.IsAbs(dir) {
		return "", fmt.Errorf("cwd は絶対パスだけです: %s", dir)
	}
	if n := utf8.RuneCountInString(prompt); n > MaxPromptRunes {
		return "", fmt.Errorf("--prompt が長すぎます（%d 字・上限 %d 字）", n, MaxPromptRunes)
	}
	q := url.Values{}
	q.Set("cwd", dir)
	if prompt != "" {
		q.Set("q", prompt)
	}
	// WhyNot: url.Values の Encode のまま渡さない — 空白が + になり、+ を空白と読まない受け手では文に + が混ざる。
	return "claude-cli://open?" + strings.ReplaceAll(q.Encode(), "+", "%20"), nil
}

// OpenCommand は OS に URL を渡すコマンド。知らない OS なら ok=false。
func OpenCommand(goos, link string) (name string, args []string, ok bool) {
	switch goos {
	case "darwin":
		return "open", []string{link}, true
	case "linux", "freebsd", "openbsd", "netbsd":
		return "xdg-open", []string{link}, true
	case "windows":
		// WhyNot: start の最初の引数に空の "" を置く — 引用符付きの最初の引数をウィンドウの題として食べる。
		return "cmd", []string{"/c", "start", "", link}, true
	}
	return "", nil, false
}

// CopyLine は deep link が開かない時に人が端末へ貼る 1 行。
func CopyLine(dir, prompt string) string {
	line := "cd " + shellQuote(dir) + " && claude"
	if prompt != "" {
		line += " " + shellQuote(prompt)
	}
	return line
}

func shellQuote(s string) string {
	if s != "" && strings.IndexFunc(s, func(r rune) bool {
		return !(r == '/' || r == '.' || r == '_' || r == '-' || r == '~' ||
			(r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9'))
	}) < 0 {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// Deps は外の世界（網・make・置き場）とつなぐ所。
type Deps struct {
	GOOS string
	Run  func(name string, args ...string) error
}

// DefaultDeps は本物のコマンドを流す。
func DefaultDeps(goos string) Deps {
	return Deps{GOOS: goos, Run: func(name string, args ...string) error {
		cmd := exec.Command(name, args...)
		cmd.Stdout = io.Discard
		cmd.Stderr = io.Discard
		return cmd.Run()
	}}
}

// Run は fge open の本体。
func Run(out, errOut *strings.Builder, args []string, d Deps) int {
	var prompt string
	fs := flag.NewFlagSet("open", flag.ContinueOnError)
	fs.SetOutput(errOut)
	fs.StringVar(&prompt, "prompt", "", "開いた Claude Code の下書きに入れる文")
	var positional []string
	for {
		if err := fs.Parse(args); err != nil {
			fmt.Fprintln(errOut, usage)
			return exitBadUsage
		}
		if fs.NArg() == 0 {
			break
		}
		positional = append(positional, fs.Arg(0))
		args = fs.Args()[1:]
	}
	if len(positional) != 1 {
		fmt.Fprintln(errOut, usage)
		return exitBadUsage
	}
	dir, err := filepath.Abs(positional[0])
	if err != nil {
		fmt.Fprintf(errOut, "!! %v\n", err)
		return exitBadUsage
	}
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		fmt.Fprintf(errOut, "!! %s はフォルダではありません\n", dir)
		return exitBadUsage
	}
	link, err := BuildURL(dir, prompt)
	if err != nil {
		fmt.Fprintf(errOut, "!! %v\n", err)
		return exitBadUsage
	}
	if name, cmdArgs, ok := OpenCommand(d.GOOS, link); ok {
		if err := d.Run(name, cmdArgs...); err == nil {
			fmt.Fprintf(out, "[fge open] %s の Claude Code を新しい端末で開きました。そちらで Enter を押して続けてください\n", dir)
			return exitDone
		}
	}
	// WhyNot: 開けなかった時に失敗で終わらない — 登録の無い機械や WSL では開けないのが普通で、人には貼る 1 行があれば足りる。
	fmt.Fprintln(out, "[fge open] Claude Code を開けませんでした（一度 claude を起動して何か送った後でないと開かないことがあります）。端末で次の 1 行を打ってください:")
	fmt.Fprintln(out, CopyLine(dir, prompt))
	return exitDone
}
