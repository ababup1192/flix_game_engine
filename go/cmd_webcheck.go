package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

const webCheckUsage = `使い方: fge web-check <書き出したフォルダ | 束の中のファイル…> [--browser]
  bin/fge export-web の書き出し（gh-pages の根・site/・play/ に写した物も）を、束のファイルだけから計算し直して門に掛ける。
  見る物: 遊べるまで（すぐ押した時・4G）と bundle.json の startupBudget（無ければ既定 16 秒）・sums.json と中身の食い違い・
          wasm に残ったパスの形・draft のマーカー・書き出しの時の 4G のタイトルの確かめ（bundle.json の checks）
  ファイルの道を渡すと、上へ辿って bundle.json と sums.json がそろうフォルダを見る（同じフォルダは 1 回。束の外のファイルは飛ばす）
  --browser  ヘッドレスの Chrome で 4G のタイトルの確かめと押した後の測りを流し直し、その結果で決める（Chrome が要る）
  終わりの番号: 0 通す / 1 止める / 2 呼び方の誤りか、書き出しのフォルダでない`

func init() {
	register("web-check", "ブラウザ版の書き出しを公開の前に門に掛ける（遊べるまでの予算・束の食い違い・パス）。web-check --help", cmdWebCheck)
}

func cmdWebCheck(out, errOut *strings.Builder, rest []string, _ bool) int {
	browser := false
	var args []string
	for _, a := range rest {
		switch {
		case a == "--help" || a == "-h":
			fmt.Fprintln(out, webCheckUsage)
			return 0
		case a == "--browser":
			browser = true
		case strings.HasPrefix(a, "--"):
			fmt.Fprintf(errOut, "fge web-check: 知らない引数 %s\n%s\n", a, webCheckUsage)
			return 2
		default:
			args = append(args, a)
		}
	}
	if len(args) == 0 {
		fmt.Fprintf(errOut, "fge web-check: 書き出したフォルダを渡してください\n%s\n", webCheckUsage)
		return 2
	}
	dirs, err := webCheckDirs(args)
	if err != nil {
		fmt.Fprintf(errOut, "fge web-check: %v\n", err)
		return 2
	}
	code := 0
	for _, dir := range dirs {
		r, err := runWebCheck(dir, browser)
		if err != nil {
			fmt.Fprintf(errOut, "fge web-check: %s: %v\n", dir, err)
			return 2
		}
		writeWebCheck(out, r)
		if !r.Gate.green() {
			code = 1
		}
	}
	return code
}

// webCheckDirs は引数（フォルダかファイル）から見る束のフォルダを選ぶ。フォルダは束でなければ誤り・ファイルは束の外なら飛ばす。
// WhyNot: ステージした中身でなく作業ツリーを読む — pre-commit から呼ばれた時、束の一部だけをステージするとずれるが、
// 束は書き出しの一式で、一部だけを入れる手順は無い。ステージの中身を写して計算し直すと wasm を毎回取り出すことになる。
func webCheckDirs(args []string) ([]string, error) {
	seen := map[string]bool{}
	var dirs []string
	for _, a := range args {
		info, err := os.Stat(a)
		if err != nil {
			return nil, err
		}
		var dir string
		if info.IsDir() {
			if !isWebBundleDir(a) {
				return nil, fmt.Errorf("%s に bundle.json が無い（bin/fge export-web の書き出しのフォルダを渡す）", a)
			}
			dir = a
		} else if dir = webBundleDirOf(a); dir == "" {
			continue
		}
		if abs, err := filepath.Abs(dir); err == nil {
			dir = abs
		}
		if !seen[dir] {
			seen[dir] = true
			dirs = append(dirs, dir)
		}
	}
	sort.Strings(dirs)
	return dirs, nil
}

func isWebBundleDir(dir string) bool {
	return fileExists(filepath.Join(dir, "bundle.json"))
}

// webBundleDirOf はファイルの道から上へ辿り、bundle.json と sums.json がそろう最初のフォルダ（無ければ空）。
// WhyNot: bundle.json だけで決めない — テストの入力や Doc に同じ名前の JSON があり、書き出しの束でない物を門に掛ける。
func webBundleDirOf(file string) string {
	abs, err := filepath.Abs(file)
	if err != nil {
		return ""
	}
	for dir := filepath.Dir(abs); ; dir = filepath.Dir(dir) {
		if isWebBundleDir(dir) && fileExists(filepath.Join(dir, webSumsFile)) {
			return dir
		}
		if parent := filepath.Dir(dir); parent == dir {
			return ""
		}
	}
}

// rerunWebBrowserChecks は ?net=4g のタイトルの確かめと押した後の測りを流し直し、b.Checks を置き替える（--browser）。
func rerunWebBrowserChecks(dir string, b *webBundle) error {
	if _, err := cdp.FindChrome(); err != nil {
		fmt.Fprintln(os.Stderr, "web-check: Chrome が見つからないので --browser の確かめは飛ばした（bundle.json の checks を使う）")
		return nil
	}
	checks := webBundleChecks{Title4g: "ok"}
	if len(b.Deferred) > 0 {
		r, err := checkWebMissingTitle(dir, webTitleFrames, webLoadCheckWait())
		checks.Title4g, checks.SkippedWhy = webTitle4gOf(r, err)
	}
	if webTapNeedsMeasure(b) {
		budget := defaultWebStartupBudget()
		if b.StartupBudget != nil {
			budget = *b.StartupBudget
		}
		m, why, err := measureWebTapWait(dir, budget.startKeys(), webLoadCheckWait())
		switch {
		case err != nil:
			// WhyNot: 測れない束で止めない — 古い fge-web.js の書き出しは待ちの記録を持たず、測れないのは束の誤りではない（書き出しと同じく見積もりと ★）。
			checks.TapSkippedWhy = "測れなかった: " + err.Error()
			fmt.Fprintf(os.Stderr, "web-check: 押した後を測れなかった: %v\n", err)
		case why != "":
			checks.TapSkippedWhy = why
		default:
			checks.TapWaitSeconds, checks.TapNoRecord = m.tapSeconds(), m.NoRecord
			var w strings.Builder
			writeWebTapMeasure(&w, &m, "")
			fmt.Fprint(os.Stderr, strings.ReplaceAll(w.String(), "  押した後", "web-check: 押した後"))
		}
	}
	b.Checks = &checks
	return nil
}
