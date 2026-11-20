package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// project.json の web.startupBudget と、書き出しと web-check が同じに使う門（「すぐ押した人が遊べるまで」の秒・束の食い違い・パス）。

// webStartupBudget は web.startupBudget。Seconds は「遊べるまで（すぐ押した時）」の上限の秒・StartKeys は押した後の測りでタイトルで押すキー。
// Declared は project.json に鍵があったか（無いゲームは移行の間、手元の書き出しを止めない）。
type webStartupBudget struct {
	Seconds   float64  `json:"seconds"`
	Why       string   `json:"why"`
	StartKeys []string `json:"startKeys,omitempty"`
	Declared  bool     `json:"-"`
}

// webBudgetMaxSeconds を超える予算は書き違いとみなす（4G で 2 分待つ頁は公開しない）。
const webBudgetMaxSeconds = 120.0

// webStartKeys は startKeys に書けるキー（go/internal/cdp の PressKey が送れる物）。英字 1 字も書ける。
var webStartKeys = map[string]bool{
	"Enter": true, "Space": true, "Escape": true, "ArrowLeft": true, "ArrowUp": true, "ArrowRight": true, "ArrowDown": true,
}

func defaultWebStartupBudget() webStartupBudget {
	return webStartupBudget{Seconds: webStartupTargetSeconds}
}

// resolveWebStartupBudget は project.json の web.startupBudget を読む（無ければ既定 16 秒・Declared は false）。
func resolveWebStartupBudget(raw json.RawMessage) (webStartupBudget, error) {
	b := defaultWebStartupBudget()
	if len(raw) == 0 || string(raw) == "null" {
		return b, nil
	}
	var web struct {
		StartupBudget json.RawMessage `json:"startupBudget"`
	}
	if err := json.Unmarshal(raw, &web); err != nil {
		return b, fmt.Errorf("project.json の web を読めない: %v", err)
	}
	if len(web.StartupBudget) == 0 || string(web.StartupBudget) == "null" {
		return b, nil
	}
	var s struct {
		Seconds   *float64 `json:"seconds"`
		Why       string   `json:"why"`
		StartKeys []string `json:"startKeys"`
	}
	dec := json.NewDecoder(bytes.NewReader(web.StartupBudget))
	// WhyNot: 書き違い（second など）をそのまま通さない — 予算が反映されないまま既定の 16 秒で止まり、理由が分からない。
	dec.DisallowUnknownFields()
	if err := dec.Decode(&s); err != nil {
		return b, fmt.Errorf("project.json の web.startupBudget を読めない: %v\n  次: { \"seconds\": 16, \"why\": \"\" } の形にする（startKeys は押した後の測りでタイトルで押すキー）", err)
	}
	if s.Seconds == nil {
		return b, fmt.Errorf("project.json の web.startupBudget に seconds が無い。\n  次: { \"seconds\": 16, \"why\": \"\" } の形にする")
	}
	b = webStartupBudget{Seconds: *s.Seconds, Why: strings.TrimSpace(s.Why), StartKeys: s.StartKeys, Declared: true}
	if err := b.validate("project.json の web.startupBudget"); err != nil {
		return b, err
	}
	return b, nil
}

// validate は予算の決まり（範囲・16 秒を超えるなら why・キーの名前）を当てる。web-check も bundle.json の予算に同じ物を当てる。
func (b webStartupBudget) validate(where string) error {
	if b.Seconds < 1 || b.Seconds > webBudgetMaxSeconds {
		return fmt.Errorf("%s の seconds %.1f が範囲の外。\n  次: 1〜%.0f にする", where, b.Seconds, webBudgetMaxSeconds)
	}
	if b.Seconds > webStartupTargetSeconds && strings.TrimSpace(b.Why) == "" {
		return fmt.Errorf("%s の seconds %.1f が既定の %.0f 秒より上なのに why が空。\n  次: 先に後回しの候補と押した後の待ちを詰める（docs/web-export.md の「起動の予算」）。それでも要るなら why に理由を書く（bundle.json に写るので公開される）",
			where, b.Seconds, webStartupTargetSeconds)
	}
	for _, k := range b.StartKeys {
		if !webStartKeys[k] && !(len(k) == 1 && strings.ContainsAny(strings.ToLower(k), "abcdefghijklmnopqrstuvwxyz")) {
			return fmt.Errorf("%s の startKeys の %q を知らない。\n  次: Enter・Space・Escape・矢印（ArrowUp など）・英字 1 字のどれかにする", where, k)
		}
	}
	return nil
}

// startKeys は押した後の測りでタイトルで押すキー（既定は Enter = タイトルの既定の行を決める）。
func (b webStartupBudget) startKeys() []string {
	if len(b.StartKeys) == 0 {
		return []string{"Enter"}
	}
	return b.StartKeys
}

// webBundleChecks は書き出しの確かめの結果（bundle.json の checks）。web-check は Chrome を起こさずに読む。
// Title4g は ?net=4g のタイトルの確かめ（ok・stopped・skipped）。TapWaitSeconds は押した後の測りで取れた、押してから動くまでの秒。
type webBundleChecks struct {
	Title4g        string   `json:"title4g"`
	SkippedWhy     string   `json:"skippedWhy,omitempty"`
	TapWaitSeconds *float64 `json:"tapWaitSeconds,omitempty"`
	// TapSkippedWhy は押した後を測らなかった理由（空で TapWaitSeconds も無ければ、測る後回しが無かった）。
	TapSkippedWhy string `json:"tapSkippedWhy,omitempty"`
	// TapNoRecord は測ったが押した時の待ちの記録が無かった（待たずに動いたか、startKeys がタイトルに合わず何も始まらなかった）。
	TapNoRecord bool `json:"tapNoRecord,omitempty"`
}

// webGate は 1 つの束の門の判定。TapWait は測った値と group の見積もりの大きい方。Playable = Startup + max(0, TapWait − LogoCover)。
type webGate struct {
	Startup       float64
	TapWait       float64
	Measured      bool // TapWait に押した後の測りの値を使った
	Unknown       bool // 測っておらず group も無い（最初の場面が待つかが分からず 0 秒で数えた）
	NoRecord      bool // 押した後を測ったが待ちの記録が無かった
	LogoCover     float64
	Playable      float64
	Budget        webStartupBudget
	BudgetDefault bool // 束に予算が無く既定の 16 秒を使った
	Red           []string
	Notes         []string
	Advice        []string
}

func (g webGate) green() bool { return len(g.Red) == 0 }

func round1(v float64) float64 { return math.Round(v*10) / 10 }

// webGateOf は書き出し先 dir の束 b から門を計算する（export-web と web-check で同じ物）。
// budget は書き出しなら project.json の物・web-check なら bundle.json の物。
func webGateOf(dir string, b *webBundle, budget webStartupBudget) webGate {
	g := webGate{Budget: budget}
	est := webStartupEstimateOf(dir, b)
	g.Startup = est.Seconds
	var waitFor []string
	var after *webAfterTap
	if b.Splash != nil && b.Splash.AfterTap != nil && b.Splash.AfterTap.Mode != "none" {
		after = b.Splash.AfterTap
		waitFor = after.WaitFor
	}
	t := webTapWaitOf(dir, b, waitFor)
	// WhyNot: group の無いゲームで、最初に届く待つ物の秒を足さない — 最初の場面が後回しの物を使わなければ待ちは 0 で（よその子は押した後 8 秒の映像）、
	// 足すと待たないゲームまで止まる。分からない分は押した後の測り（⑨''）で埋める。
	if len(t.Group) > 0 {
		g.TapWait = t.Seconds
	}
	g.Unknown = t.Count > 0 && len(t.Group) == 0
	g.NoRecord = b.Checks != nil && b.Checks.TapNoRecord
	if c := b.Checks; c != nil && c.TapWaitSeconds != nil {
		g.TapWait, g.Measured, g.Unknown = math.Max(g.TapWait, *c.TapWaitSeconds), true, false
	}
	// WhyNot: group の無いゲームでロゴの秒を引かない — 頁のロゴは waitFor の group を待つ時だけ出て（fge-web.js の fgeAfterTapPending）、
	// group が無ければ押した後の待ちは何にも覆われない。
	if after != nil && len(waitFor) > 0 && t.Count > 0 && g.TapWait >= after.MinSeconds {
		g.LogoCover = after.MaxSeconds
	}
	g.Playable = g.Startup + math.Max(0, g.TapWait-g.LogoCover)
	if g.Playable > budget.Seconds {
		g.Red = append(g.Red, fmt.Sprintf("遊べるまで（すぐ押した時・4G）約 %.1f 秒が予算 %.0f 秒を超えた（%s）", g.Playable, budget.Seconds, g.breakdown()))
	}
	if budget.Seconds > webStartupTargetSeconds {
		g.Notes = append(g.Notes, fmt.Sprintf("★ 予算 %.0f 秒（既定 %.0f 秒より上）: %s", budget.Seconds, webStartupTargetSeconds, budget.Why))
	}
	switch {
	case g.Unknown && g.NoRecord:
		g.Notes = append(g.Notes, "押した後を測ったが待ちの記録が無い（待たずに動いた。タイトルの既定の行が「はじめから」でないゲームは web.startupBudget.startKeys を書かないと測れない）")
	case g.Unknown:
		g.Notes = append(g.Notes, fmt.Sprintf("★ 押した後は測っていない（group が無く、最初の場面が待つかは分からないので 0 秒で数えた。待つなら最初の物は %.1f 秒目に届く）— Chrome のある機械で書き出すか web-check --browser で測る", t.Seconds))
	case !g.Measured && t.Count > 0:
		g.Notes = append(g.Notes, "★ 押した後は測っていない（group が届くまでの見積もり）— Chrome のある機械で書き出すか web-check --browser で測る")
	}
	if n := webPlaceholderImages(b); n > 0 {
		g.Notes = append(g.Notes, fmt.Sprintf("★ placeholder の後回しの絵 %d 枚（届くまで描かずに進む）", n))
	}
	g.Advice = g.advise(b, t, est)
	return g
}

// breakdown は門の数字の内訳。
func (g webGate) breakdown() string {
	tap := fmt.Sprintf("押した後 %.1f 秒", g.TapWait)
	switch {
	case g.Measured:
		tap += "・測った値"
	case g.Unknown && g.NoRecord:
		tap += "・測ったが待ちの記録なし"
	case g.Unknown:
		tap += "・測っていない"
	}
	if g.LogoCover > 0 {
		tap += fmt.Sprintf("・ロゴが %.0f 秒まで覆う", g.LogoCover)
	} else if g.TapWait > 0 {
		tap += "・ロゴは出ない"
	}
	return fmt.Sprintf("起動 %.1f 秒＋%s", g.Startup, tap)
}

// line は表と web-check の 1 行。
func (g webGate) line() string {
	return fmt.Sprintf("遊べるまで（すぐ押した時・4G）: 約 %.1f 秒 / 予算 %.0f 秒（%s）", g.Playable, g.Budget.Seconds, g.breakdown())
}

// advise は予算を超えた時の次に打つ手（候補は書き出しの確かめで取れた時に呼び手が先頭へ足す）。
func (g webGate) advise(b *webBundle, t webTapWait, est webStartupEstimate) []string {
	var out []string
	if over := g.TapWait - g.LogoCover; over > 0 {
		hint := "押した直後に要る物を web.deferred の頭へ並べ替えるか後回しから外す"
		if len(t.Group) == 0 {
			hint += "・deferredPolicy に group を付けると押した後のロゴが 3 秒まで覆う"
		}
		out = append(out, fmt.Sprintf("押した後の待ち %.1f 秒（ロゴで覆えない分 %.1f 秒）→ %s", g.TapWait, over, hint))
	}
	if b.WasmBrotli == "" {
		br := int64(float64(est.Boot.WasmWire) * 0.6)
		out = append(out, fmt.Sprintf("brotli が無い（wasm を gzip の大きさで配る）→ 入れると wasm が 約 -%.1f 秒（wasmBrotli: false は逃げ道にならない）", webSecondsFor(est.Boot.WasmWire-br)))
	}
	return out
}

// webPlaceholderImages は後回しの絵のうち onMissing が placeholder の物の数。
func webPlaceholderImages(b *webBundle) int {
	n := 0
	for _, e := range b.Deferred {
		if e.OnMissing == "placeholder" && webDeferredKindOf(e.Path, b) == "image" {
			n++
		}
	}
	return n
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

// loadWebBundle は dir の bundle.json を読む。
func loadWebBundle(dir string) (webBundle, error) {
	var b webBundle
	raw, err := os.ReadFile(filepath.Join(dir, "bundle.json"))
	if err != nil {
		return b, err
	}
	if err := json.Unmarshal(raw, &b); err != nil {
		return b, fmt.Errorf("%s/bundle.json を読めない: %v", dir, err)
	}
	return b, nil
}

// runWebCheck は書き出し済みの束 dir を、束のファイルだけから計算し直して門に掛ける。
func runWebCheck(dir string, browser bool) (webCheckResult, error) {
	res := webCheckResult{Dir: dir}
	b, err := loadWebBundle(dir)
	if err != nil {
		return res, err
	}
	if browser {
		if err := rerunWebBrowserChecks(dir, &b); err != nil {
			return res, err
		}
	}
	budget := defaultWebStartupBudget()
	if b.StartupBudget != nil {
		budget = *b.StartupBudget
		budget.Declared = true
	}
	g := webGateOf(dir, &b, budget)
	g.BudgetDefault = b.StartupBudget == nil
	if err := budget.validate("bundle.json の startupBudget"); err != nil {
		g.Red = append(g.Red, strings.SplitN(err.Error(), "\n", 2)[0])
	}
	if b.Draft {
		g.Red = append(g.Red, "draft の書き出し（"+strings.Join(b.DraftReasons, "・")+"）— --draft を付けずに書き出し直す")
	}
	switch {
	case b.Checks == nil:
		g.Notes = append(g.Notes, "★ 4G のタイトルの確かめの記録が無い（0.105.0 までの書き出し）— web-check --browser で流す")
	case b.Checks.Title4g == "stopped":
		g.Red = append(g.Red, "4G（?net=4g）のタイトルで、届いていない後回しの物を待って止まった — タイトルで使う物は web.deferred から外す")
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

// writeWebGateAdvice は次に打つ手を 3 つまでと、予算の書き方・--draft を書く。
func writeWebGateAdvice(w io.Writer, advice []string, more string) {
	fmt.Fprintln(w, "  次に打つ手（4G の秒が減る順）")
	for i, a := range advice {
		if i == 3 {
			break
		}
		fmt.Fprintf(w, "    %d. %s\n", i+1, a)
	}
	if more != "" {
		fmt.Fprintf(w, "    ・%s\n", more)
	}
	fmt.Fprintf(w, "  どうしても超えるなら project.json の web.startupBudget に { \"seconds\": <秒>, \"why\": \"<理由>\" }（%.0f 秒を超えると毎回 ★・why は公開される）\n", webStartupTargetSeconds)
}
