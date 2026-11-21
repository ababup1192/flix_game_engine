package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

const webCheckUsage = `使い方: fge web-check <書き出したフォルダ | 束の中のファイル…> [--browser [--cpu <倍>] [--tap-delay <秒>]]
  bin/fge export-web の書き出し（gh-pages の根・site/・play/ に写した物も）を、束のファイルだけから計算し直して門に掛ける。
  見る物: 遊べるまで（すぐ押した時・4G）と bundle.json の startupBudget（無ければ既定 16 秒）・sums.json と中身の食い違い・
          wasm に残ったパスの形・draft のマーカー・書き出しの時の 4G のタイトルの確かめ（bundle.json の checks）
  ファイルの道を渡すと、上へ辿って bundle.json と sums.json がそろうフォルダを見る（同じフォルダは 1 回。束の外のファイルは飛ばす）
  --browser  ヘッドレスの Chrome で 4G のタイトルの確かめと押した後の測りを流し直し、その結果で決める（Chrome が要る）。
             押した後の速さの表（押してから最初のコマ・押してから波紋まで・Service Worker が付いた後の 2 回目の起動）も出す
  --cpu <倍>        CPU を絞った測りを表と知らせに足す（例 4。門の数字は替えない）
  --tap-delay <秒>  「タッチして開始」が出てから押すまでの間を空けた測りを表と知らせに足す（例 1.5。門の数字は替えない）
  終わりの番号: 0 通す / 1 止める / 2 呼び方の誤りか、書き出しのフォルダでない`

func init() {
	register("web-check", "ブラウザ版の書き出しを公開の前に門に掛ける（遊べるまでの予算・束の食い違い・パス）。web-check --help", cmdWebCheck)
}

func cmdWebCheck(out, errOut *strings.Builder, rest []string, _ bool) int {
	browser := false
	var cond webMeasureConditions
	var args []string
	for i := 0; i < len(rest); i++ {
		a := rest[i]
		switch {
		case a == "--help" || a == "-h":
			fmt.Fprintln(out, webCheckUsage)
			return 0
		case a == "--browser":
			browser = true
		case a == "--cpu" || a == "--tap-delay":
			v, ok := 0.0, i+1 < len(rest)
			if ok {
				var err error
				v, err = strconv.ParseFloat(rest[i+1], 64)
				ok = err == nil && v >= 0 && (a == "--tap-delay" || v >= 1)
			}
			if !ok {
				fmt.Fprintf(errOut, "fge web-check: %s の値は数（--cpu は 1 以上の倍率・--tap-delay は 0 以上の秒）\n%s\n", a, webCheckUsage)
				return 2
			}
			i++
			if a == "--cpu" {
				cond.CPU = v
			} else {
				cond.TapDelay = time.Duration(v * float64(time.Second))
			}
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
	if !browser && !cond.isGate() {
		fmt.Fprintf(errOut, "fge web-check: --cpu と --tap-delay は --browser と一緒に使う\n%s\n", webCheckUsage)
		return 2
	}
	dirs, err := webCheckDirs(args)
	if err != nil {
		fmt.Fprintf(errOut, "fge web-check: %v\n", err)
		return 2
	}
	code := 0
	for _, dir := range dirs {
		r, err := runWebCheck(dir, browser, cond)
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

// rerunWebBrowserChecks は ?fge=4g のタイトルの確かめと押した後の測りを流し直し、b.Checks を置き替える（--browser）。
// 押した後の速さの表（2 回目の起動を含む）も出す。cond が門の条件でなければ、同じ確かめを cond でもう 1 回流して表と知らせに足す（b.Checks は替えない）。
func rerunWebBrowserChecks(dir string, b *webBundle, cond webMeasureConditions) error {
	if _, err := cdp.FindChrome(); err != nil {
		fmt.Fprintln(os.Stderr, "web-check: Chrome が見つからないので --browser の確かめは飛ばした（bundle.json の checks を使う）")
		return nil
	}
	keys := webBundleBudget(b).startKeys()
	r := runWebBrowserChecks(dir, b, keys, webBrowserCheckOptions{Warm: true}, webCheckBrowserLog(webMeasureConditions{}))
	b.Checks = &r.Checks
	rows := r.Timing
	if !cond.isGate() {
		extra := runWebBrowserChecks(dir, b, keys, webBrowserCheckOptions{Cond: cond, Warm: true}, webCheckBrowserLog(cond))
		if len(b.Deferred) > 0 {
			fmt.Fprintf(os.Stderr, "web-check: 知らせ（%s）: 4G のタイトルの確かめ %s\n", cond.label(), extra.Checks.Title4g)
		}
		rows = append(rows, extra.Timing...)
	}
	writeWebTapTimingRows(os.Stderr, rows)
	return nil
}

// webCheckBrowserLog は web-check --browser の押した後の待ちの出し方（門の条件でない時は条件を頭に付けて知らせにする）。
func webCheckBrowserLog(cond webMeasureConditions) webBrowserCheckLog {
	head := "web-check: "
	if !cond.isGate() {
		head = "web-check: 知らせ（" + cond.label() + "）: "
	}
	return webBrowserCheckLog{
		TapFailed: func(err error) { fmt.Fprintf(os.Stderr, "%s押した後を測れなかった: %v\n", head, err) },
		TapMeasured: func(m webTapMeasure) {
			var w strings.Builder
			writeWebTapMeasure(&w, &m, "")
			fmt.Fprint(os.Stderr, strings.ReplaceAll(w.String(), "  押した後", head+"押した後"))
		},
	}
}

// webBundleBudget は束に写した予算（無ければ既定の 16 秒）。束に予算があれば書いた扱い（Declared）。
func webBundleBudget(b *webBundle) webStartupBudget {
	if b.StartupBudget == nil {
		return defaultWebStartupBudget()
	}
	budget := *b.StartupBudget
	budget.Declared = true
	return budget
}

// webSumsReport は束のファイルと sums.json の照らし合わせ。
type webSumsReport struct {
	Mismatch     []string // 中身が合わない
	MissingUsed  []string // 載っているのに無い・頁が取る物
	MissingSpare []string // 載っているのに無い・頁が取らない控え（Opus の代わりの元の wav など）
	VersionBad   bool
	NoSums       bool
}

// checkWebSums は dir の sums.json と中身・version.txt を照らす。
func checkWebSums(dir string, b *webBundle) webSumsReport {
	var r webSumsReport
	raw, err := os.ReadFile(filepath.Join(dir, webSumsFile))
	if err != nil {
		r.NoSums = true
		return r
	}
	sums := map[string]string{}
	if json.Unmarshal(raw, &sums) != nil {
		r.NoSums = true
		return r
	}
	h := sha256.Sum256(raw)
	if v, err := os.ReadFile(filepath.Join(dir, "version.txt")); err == nil && strings.TrimSpace(string(v)) != hex.EncodeToString(h[:])[:12] {
		r.VersionBad = true
	}
	used := webServedPaths(b)
	keys := make([]string, 0, len(sums))
	for k := range sums {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, rel := range keys {
		data, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(rel)))
		if err != nil {
			if used[rel] {
				r.MissingUsed = append(r.MissingUsed, rel)
			} else {
				r.MissingSpare = append(r.MissingSpare, rel)
			}
			continue
		}
		got := sha256.Sum256(data)
		if hex.EncodeToString(got[:]) != sums[rel] {
			r.Mismatch = append(r.Mismatch, rel)
		}
	}
	return r
}

// webServedPaths は頁が取る物の道（書き出し先から・/ 区切り）。
func webServedPaths(b *webBundle) map[string]bool {
	used := map[string]bool{"bundle.json": true, "fge-web.js": true, "wasm-gc-runtime.js": true}
	if b.WasmBrotli != "" {
		used[b.WasmBrotli] = true
		used[webBrotliDecoderFile] = true
	} else {
		used["classes.wasm"] = true
	}
	for _, rel := range b.copyList() {
		used["assets/"+b.served(rel)] = true
	}
	return used
}

// webCheckResult は web-check の 1 束の結果。
type webCheckResult struct {
	Dir   string
	Gate  webGate
	Sums  webSumsReport
	Leaks int
}

// runWebCheck は書き出し済みの束 dir を、束のファイルだけから計算し直して門に掛ける。
// cond は --browser の時に門とは別に流す測りの条件（零の値なら流さない）。
func runWebCheck(dir string, browser bool, cond webMeasureConditions) (webCheckResult, error) {
	res := webCheckResult{Dir: dir}
	b, err := loadWebBundle(dir)
	if err != nil {
		return res, err
	}
	if browser {
		if err := rerunWebBrowserChecks(dir, &b, cond); err != nil {
			return res, err
		}
	}
	budget := webBundleBudget(&b)
	g := webGateOf(newWebSizeTable(dir), &b, budget)
	g.BudgetDefault = b.StartupBudget == nil
	if err := budget.validate("bundle.json の startupBudget"); err != nil {
		g.Red = append(g.Red, strings.SplitN(err.Error(), "\n", 2)[0])
	}
	if b.Draft {
		g.Red = append(g.Red, "draft の書き出し（"+strings.Join(b.DraftReasons, "・")+"）— --draft を付けずに書き出し直す")
	}
	g.Red = append(g.Red, webChecksRed(&b)...)
	switch {
	case b.Checks == nil:
		g.Notes = append(g.Notes, "★ 4G のタイトルの確かめの記録が無い（0.105.0 までの書き出し）— web-check --browser で流す")
	case b.Checks.Title4g == "skipped":
		g.Notes = append(g.Notes, "★ 4G のタイトルの確かめを飛ばした書き出し（"+b.Checks.SkippedWhy+"）— web-check --browser で流す")
	}
	res.Sums = checkWebSums(dir, &b)
	s := res.Sums
	if s.NoSums {
		g.Red = append(g.Red, "sums.json が無い（bin/fge export-web の書き出しでない・古い書き出し）— 書き出し直す")
	}
	if s.VersionBad {
		g.Red = append(g.Red, "version.txt が sums.json と合わない — 書き出した後に束を替えた。書き出し直す")
	}
	if n := len(s.Mismatch); n > 0 {
		g.Red = append(g.Red, fmt.Sprintf("書き出した後に中身が替わったファイル %d 本（%s）— 書き出し直す（Service Worker もキャッシュしない）", n, headList(s.Mismatch, 3)))
	}
	if n := len(s.MissingUsed); n > 0 {
		g.Red = append(g.Red, fmt.Sprintf("頁が取るのに無いファイル %d 本（%s）", n, headList(s.MissingUsed, 3)))
	}
	if n := len(s.MissingSpare); n > 0 {
		g.Notes = append(g.Notes, fmt.Sprintf("頁が取らない控え %d 本が無い（%s・消しても動く）", n, headList(s.MissingSpare, 2)))
	}
	finder := newWebLeakFinder(os.Getenv("HOME"), os.Getenv("USERPROFILE"))
	for _, name := range []string{"classes.wasm", webWasmNamesFile} {
		if data, err := os.ReadFile(filepath.Join(dir, name)); err == nil {
			res.Leaks += len(finder.find(data))
		}
	}
	if res.Leaks > 0 {
		g.Red = append(g.Red, fmt.Sprintf("作業フォルダかホームのパスの形が wasm に %d 件 — bin/fge export-web で書き出し直す", res.Leaks))
	}
	res.Gate = g
	return res, nil
}

func headList(list []string, n int) string {
	if len(list) <= n {
		return strings.Join(list, "・")
	}
	return strings.Join(list[:n], "・") + fmt.Sprintf(" ほか %d 本", len(list)-n)
}

// writeWebCheck は web-check の結果を書く（緑なら 1 行と ★）。
func writeWebCheck(w io.Writer, r webCheckResult) {
	g := r.Gate
	verdict := "通す"
	if !g.green() {
		verdict = "止める"
	}
	fmt.Fprintf(w, "web-check: %s — %s・パス %d 件・食い違い %d 件（%s）\n", r.Dir, g.line(), r.Leaks,
		len(r.Sums.Mismatch)+len(r.Sums.MissingUsed), verdict)
	if g.BudgetDefault {
		fmt.Fprintf(w, "  予算は bundle.json に無いので既定の %.0f 秒\n", webStartupTargetSeconds)
	}
	for _, red := range g.Red {
		fmt.Fprintf(w, "  止めた: %s\n", red)
	}
	for _, n := range g.Notes {
		fmt.Fprintf(w, "  %s\n", n)
	}
	if !g.green() && g.Playable > g.Budget.Seconds {
		writeWebGateAdvice(w, g.Advice, "bin/fge export-web <ゲーム> の終わりの「後回しの候補」を見る")
	}
}
