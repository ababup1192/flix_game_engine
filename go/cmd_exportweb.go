package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const exportWebUsage = `使い方: fge export-web <ゲームのフォルダ> [--out <dir>] [--check] [--id <名前>] [--font-atlas-dir <dir>]
                       [--work <dir>] [--engine <dir>] [--keep-work] [--no-browser-check] [--reuse] [--show-leaks]
                       [--apply-deferred] [--draft]
  ゲームをブラウザ版（TeaVM の WASM GC）へ書き出す。出力の既定は <ゲーム>/build/web。
  --check           作業フォルダで flix check だけ流す（web/WebMain.flix の型検査）
  --id              bundle.json の id（既定はゲームのフォルダの名前）
  --font-atlas-dir  <dir>/<フォントの名前>.fontatlas を使う（無ければ font-bake で作る）
  --work            作業フォルダ（既定 <ゲーム>/build/web-export）。中の project/ にゲームを写して組む
  --engine          engine の根（既定は bin/fge-go の置き場から引く）
  --keep-work       終わった後も作業フォルダの project/ を残す
  --no-browser-check  最後の「ヘッドレスの Chrome で頁を開き、wasm を読んで数コマ回せるか」を飛ばす
  --reuse           書き出しの中身を決める物（写すゲームの全部・engine の束と jar・この bin/fge・変換の道具）の指紋が
                    前の書き出しと同じで、書き出し先がその時のままなら組まずに使い回す（指紋は作業フォルダの export.inputs）
  --apply-deferred  最後の確かめでタイトルの 120 コマ（2 秒）に使わなかった起動の素材（後回しの候補）を、project.json の
                    web.deferred・web.deferredFonts の後ろへ足す（無ければ候補を出すだけ。--reuse でも組み直す）
  --draft           門（遊べるまでの予算・4G のタイトル）が赤でも書き出し、bundle.json に draft のマーカーを付ける（web-check が拒むので公開できない。
                    緑なら旗無しと同じ物）。旗無しで赤なら、次に打つ手を出して書き出し先を消す
  --show-leaks      作業フォルダかホームのパスが jar か wasm に残って止まった時、残った字を手元の画面に出す（既定は件数と場所だけ）
  環境変数: FLIX_GE_TEAVM_DIR（TeaVM の jar のフォルダ。無ければ Maven から取る）・JAVA・FLIX_JAR・
            FGE_CHROME（確かめに使う Chrome）・FLIX_GE_WEB_CHECK_WAIT（確かめで待つ秒・既定 90）
  終わりの番号: 0 書き出せた / 1 組み立てか TeaVM か素材かブラウザでの読み込みで失敗 / 2 呼び方の誤りか下ごしらえが無い`

func init() {
	register("export-web", "ゲームをブラウザ版（TeaVM の WASM GC）へ書き出す。export-web --help", cmdExportWeb)
}

type exportWebOptions struct {
	Game, Out, Work, Engine, ID, FontAtlasDir string
	Check, KeepWork, NoBrowserCheck, Reuse    bool
	ShowLeaks, ApplyDeferred, Draft           bool
}

func cmdExportWeb(out, errOut *strings.Builder, rest []string, _ bool) int {
	opts, err := parseExportWebArgs(rest)
	if err != nil {
		if errors.Is(err, errCommandHelp) {
			fmt.Fprintln(out, exportWebUsage)
			return 0
		}
		fmt.Fprintf(errOut, "fge export-web: %v\n%s\n", err, exportWebUsage)
		return 2
	}
	return runExportWeb(out, errOut, opts)
}

// errCommandHelp は --help を読んだ時の値（呼び手は使い方を出して 0 で終える）。
var errCommandHelp = errors.New("help")

func parseExportWebArgs(args []string) (exportWebOptions, error) {
	var o exportWebOptions
	value := map[string]*string{
		"--out": &o.Out, "--work": &o.Work, "--engine": &o.Engine, "--id": &o.ID, "--font-atlas-dir": &o.FontAtlasDir,
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--help" || a == "-h" {
			return o, errCommandHelp
		}
		if a == "--check" {
			o.Check = true
			continue
		}
		if a == "--keep-work" {
			o.KeepWork = true
			continue
		}
		if a == "--no-browser-check" {
			o.NoBrowserCheck = true
			continue
		}
		if a == "--reuse" {
			o.Reuse = true
			continue
		}
		if a == "--show-leaks" {
			o.ShowLeaks = true
			continue
		}
		if a == "--apply-deferred" {
			o.ApplyDeferred = true
			continue
		}
		if a == "--draft" {
			o.Draft = true
			continue
		}
		if a == "--json" {
			continue
		}
		name, val, hasEq := strings.Cut(a, "=")
		if dst, ok := value[name]; ok {
			if !hasEq {
				if i+1 >= len(args) {
					return o, fmt.Errorf("%s には値が要る", name)
				}
				i++
				val = args[i]
			}
			*dst = val
			continue
		}
		if strings.HasPrefix(a, "--") {
			return o, fmt.Errorf("知らない引数: %s", a)
		}
		if o.Game != "" {
			return o, fmt.Errorf("ゲームのフォルダは 1 つだけ: %s と %s", o.Game, a)
		}
		o.Game = a
	}
	if o.Game == "" {
		return o, errors.New("ゲームのフォルダを渡してください")
	}
	if o.ApplyDeferred && (o.NoBrowserCheck || o.Check) {
		return o, errors.New("--apply-deferred は最後のブラウザの確かめで候補を出すので、--no-browser-check・--check とは一緒に使えない")
	}
	return o, nil
}

// exportWebLog は長い手順の途中の様子。out（最後にまとめて出る）ではなく、その場で stderr へ出す。
var exportWebLog io.Writer = os.Stderr

func ewLogf(format string, a ...any) { fmt.Fprintf(exportWebLog, "[export-web] "+format+"\n", a...) }

func runExportWeb(out, errOut *strings.Builder, o exportWebOptions) int {
	code, fail := exportWeb(out, errOut, o)
	if fail != nil {
		return reportExportFailure(errOut, fail)
	}
	return code
}

// reportExportFailure は止まった段の字を errOut へ書き、消すと決めた書き出し先を消して終わりの番号を返す。
func reportExportFailure(errOut *strings.Builder, f *exportFailure) int {
	if f.discard != "" {
		os.RemoveAll(f.discard)
	}
	errOut.WriteString(f.text)
	return f.code
}

// exportWeb は書き出しの段を順に流す。
func exportWeb(out, errOut *strings.Builder, o exportWebOptions) (int, *exportFailure) {
	c, fail := loadExportConfig(o)
	if fail != nil {
		return 0, fail
	}
	p := c.Paths
	fingerprint := ""
	// WhyNot: --apply-deferred で使い回さない — 候補は書き出しの最後のブラウザの確かめで出すので、使い回すと出せない。
	if o.Reuse && !o.Check && !o.ApplyDeferred {
		var reused bool
		if fingerprint, reused, fail = reuseExport(out, o, c); fail != nil || reused {
			return 0, fail
		}
	}
	if p.FullWebEntry != "" {
		ewLogf("① ゲームを %s へ写す（engine_full_web %s・置き場 %s）", p.Project, p.Version, filepath.Base(p.FullWebEntry))
	} else {
		ewLogf("① ゲームを %s へ写す（engine_full_web %s・置き場が無いので build/engine_full_web を直に読む。make sync-engine-full-web で置き場に入る）", p.Project, p.Version)
	}
	if err := prepareExportProject(p); err != nil {
		return 0, exportFail(2, err)
	}
	if o.Check {
		return runExportCheck(out, o, c)
	}
	wasm, fail := buildWasm(o, c)
	if fail != nil {
		return 0, fail
	}
	a, fail := assembleWebBundle(o, c)
	if fail != nil {
		return 0, fail
	}
	hash, fail := writeExportPage(c, &a, wasm)
	if fail != nil {
		return 0, fail
	}
	bc, fail := runExportBrowserChecks(o, c, &a.Bundle)
	if fail != nil {
		return 0, fail
	}
	return finishExport(out, errOut, o, c, &a, wasm, bc, hash, fingerprint)
}

// reuseExport は --reuse の時、前の書き出しと入力の指紋が同じなら門だけ掛け直して使い回す（reused）。
// 組み直す時は、最後に残す指紋を返す。
func reuseExport(out *strings.Builder, o exportWebOptions, c exportConfig) (string, bool, *exportFailure) {
	p := c.Paths
	fingerprint, err := exportInputsFingerprint(p, o, c.ID, findWebEncoders(p.Engine, c.Compress))
	if err != nil {
		return "", false, exportFailf(2, "fge export-web: 指紋を作れない: %v\n", err)
	}
	if !canReuseExport(p, fingerprint) {
		// WhyNot: 前の指紋を残したまま組まない — 途中で止まると、半端な書き出し先を前の指紋が「同じ」と言う。
		os.Remove(exportReuseStamp(p))
		return fingerprint, false, nil
	}
	version, _ := os.ReadFile(filepath.Join(p.Out, "version.txt"))
	fmt.Fprintf(out, "export-web: %s（版 %s・前と同じ入力なので使い回した）\n", p.Out, strings.TrimSpace(string(version)))
	// WhyNot: 使い回す時に門を飛ばさない — 赤のまま書き出した物を緑の終わりの番号で返すと、写す手順がそのまま配る。
	r, err := runWebCheck(p.Out, false, webMeasureConditions{})
	if err != nil {
		return "", true, exportFailf(1, "fge export-web: 使い回す書き出しを読めない: %v\n", err)
	}
	var w strings.Builder
	writeWebCheck(&w, r)
	out.WriteString(w.String())
	switch exportVerdictOf(!r.Gate.green(), o.Draft, c.Budget) {
	case exportStop:
		return "", true, exportFailf(1, "fge export-web: 門が赤なので書き出し先 %s を消した（作業中に開くだけなら --draft）\n", p.Out).discarding(p.Out)
	case exportMigrating:
		fmt.Fprintln(out, "  ★ 上の「止める」は公開の道（web-check）での扱い。web.startupBudget を書いていないので、移行の間は手元の書き出しを止めない（手で写す前に bin/fge web-check）")
	}
	return "", true, nil
}

// finishExport は確かめの結果を束に書き足して門に掛け、表と後回しの候補を書く。門が赤で止める時は書き出し先を消して 1。
func finishExport(out, errOut *strings.Builder, o exportWebOptions, c exportConfig, a *exportAssembly, w wasmBuild,
	bc exportBrowserChecks, hash, fingerprint string) (int, *exportFailure) {
	p, b := c.Paths, &a.Bundle
	checks := bc.Checks
	b.Checks = &checks
	g := exportGateOf(newWebSizeTable(p.Out), b, c.Budget)
	v := exportVerdictOf(!g.green(), o.Draft, c.Budget)
	if v == exportDraft {
		b.Draft, b.DraftReasons = true, g.Red
	}
	var err error
	// WhyNot: 確かめの結果を書き出し先の外（report）に置かない — gh-pages の根や play/ に写したフォルダを web-check が Chrome 無しで読めなくなる。
	if v != exportStop {
		if hash, err = writeWebPageMeta(p, *b, w.TeavmCore); err != nil {
			return 0, exportFail(1, err)
		}
		// WhyNot: 書き直す前の判定のまま終えない — bundle.json が checks の分だけ大きくなり、境目の束は web-check で赤になる。
		after := exportGateOf(newWebSizeTable(p.Out), b, c.Budget)
		if g.green() && !after.green() {
			after.Advice = g.Advice
			g = after
			v = exportVerdictOf(true, o.Draft, c.Budget)
			if v == exportDraft {
				b.Draft, b.DraftReasons = true, g.Red
				if hash, err = writeWebPageMeta(p, *b, w.TeavmCore); err != nil {
					return 0, exportFail(1, err)
				}
			}
		}
	}
	sizes := newWebSizeTable(p.Out)
	suggestion := suggestTitleDeferred(sizes, b, c, bc.Used)
	if advice := webCandidateAdvice(suggestion); advice != "" {
		g.Advice = append([]string{advice}, g.Advice...)
	}
	cleanupExportWork(p, o.KeepWork)
	if fingerprint != "" && v != exportStop {
		if err := os.WriteFile(exportReuseStamp(p), []byte(exportReuseLine(fingerprint, p.Out, hash)), 0o644); err != nil {
			ewLogf("知らせ: 指紋を残せない（次の --reuse も組み直す）: %v", err)
		}
	}

	if v == exportStop {
		fmt.Fprintf(out, "export-web: %s（版 %s・門が赤なので最後に消す）\n", p.Out, hash)
	} else {
		fmt.Fprintf(out, "export-web: %s（版 %s）\n", p.Out, hash)
	}
	writeExportSizes(out, sizes, *b, a.Atlases, a.Report, c.Strip)
	writeWebMissingTitleTo(out, bc.Missing)
	var tw strings.Builder
	tapSkipped := ""
	if bc.Tap == nil {
		tapSkipped = checks.TapSkippedWhy
	}
	writeWebTapMeasure(&tw, bc.Tap, tapSkipped)
	writeWebGateSummary(&tw, g, v)
	out.WriteString(tw.String())
	titleCode := writeTitleAssets(out, errOut, o, p, suggestion, bc.Used)
	if v == exportStop {
		// WhyNot: 赤の書き出し先を残さない — 手で gh-pages の根へ写す道は web-check を通らず、そのまま配られる。
		return 0, exportFailf(1, "%s", exportStopText(p.Out, g)).discarding(p.Out)
	}
	return titleCode, nil
}

// exportGateOf は書き出しの門（webGateOf に、書き出しの確かめの結果の赤を足した物）。
func exportGateOf(sizes *webSizeTable, b *webBundle, budget webStartupBudget) webGate {
	g := webGateOf(sizes, b, budget)
	g.Red = append(g.Red, webChecksRed(b)...)
	return g
}

// exportStopText は門が赤で止めた時に errOut へ書く字（赤の行・次に打つ手・--draft の案内）。
func exportStopText(out string, g webGate) string {
	var w strings.Builder
	fmt.Fprintf(&w, "fge export-web: 門が赤なので書き出し先 %s を消した。\n", out)
	for _, red := range g.Red {
		fmt.Fprintf(&w, "  止めた: %s\n", red)
	}
	writeWebGateAdvice(&w, g.Advice, "")
	w.WriteString("  作業中に開くだけなら --draft（web-check が拒む draft のマーカーが付く）\n")
	return w.String()
}
