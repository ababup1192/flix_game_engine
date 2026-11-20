package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
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
	p, code, err := resolveExportWebPaths(o)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return code
	}
	java := exportWebJava(p.Engine)
	// WhyNot: web 欄の誤りを束を作る所まで待って言わない — 組み立てと TeaVM に数分かかった後に止まる。
	proj, err := loadExportProject(p.Game)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	touch, err := resolveWebTouch(p.Game, proj.Web)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	compress, err := resolveWebCompress(proj.Web)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	if compress.Auto, err = loadWebAutoLossyRules(p.Engine); err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 2
	}
	compress.DataImages = loadWebShaderTextures(p.Game, proj)
	startPrompt, err := resolveWebStartPrompt(proj.Web)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	embed, err := resolveWebEmbed(proj.Web)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	serviceWorker, err := resolveWebServiceWorker(proj.Web)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	budget, err := resolveWebStartupBudget(proj.Web)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	id := o.ID
	if id == "" {
		id = filepath.Base(p.Game)
	}
	entry := readWebEntry(p.Game)
	// WhyNot: web.embed の誤りを TeaVM の後まで待って言わない — 組み立てに数分かかった後に止まる。
	early, err := buildWebBundle(p.Game, id, proj, usesScene3dEntry(entry))
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	embedPlan, err := planWebEmbed(early, embed)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	losslessNotes, err := checkWebLosslessGlobs(early.Images, compress)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	keep, err := resolveWebKeep(proj.Web)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	strip, err := planWebStrip(p.Game, early.Files, keep, embedPlan)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	early.Files = strip.without(early.Files)
	deferredOrder, err := resolveWebDeferred(proj.Web)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	textureNames := textureNamesByPath(proj)
	deferredPlan, err := planWebDeferred(early, deferredOrder.Globs, embedPlan, proj.fontNames(), textureNames)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	deferredFonts, err := resolveWebDeferredFonts(proj.Web, proj.fontNames())
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	if err := checkDeferredFontNames(deferredFonts, textureNames, early.Sounds); err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	deferredPolicy, err := resolveWebDeferredPolicy(proj.Web)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	fontGroupAt := webFontGroupStarts(deferredPlan.Paths, deferredFonts, deferredPolicy, &early, textureNames)
	if deferredPlan, textureNames, err = withDeferredFonts(deferredPlan, deferredFonts, deferredOrder.Fonts, fontGroupAt, textureNames); err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	earlyEntries := webDeferredEntries("", &early, deferredPlan.Paths, textureNames)
	if _, lines, err := applyWebDeferredPolicy(earlyEntries, deferredPolicy, &early); err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	} else {
		deferredPlan.Warnings = append(deferredPlan.Warnings, lines...)
	}
	if rows := placeholderImageRowsWithoutWhy(earlyEntries, deferredPolicy, &early); len(rows) > 0 {
		msg := fmt.Sprintf("web.deferredPolicy の %s が後回しの絵を placeholder にしているのに why が無い（届くまで描かずに進み、押した後に黒いコマが出る）。\n  次: 絵は待たせる（onMissing を消す）か、行に \"why\": \"<理由>\" を書く", quotedList(rows))
		if budget.Declared {
			fmt.Fprintf(errOut, "fge export-web: %s\n", msg)
			return 1
		}
		ewLogf("★ %s（web.startupBudget を書くと止まる・移行が終わる版から全部止まる）", msg)
	}
	for _, line := range deferredPlan.Warnings {
		ewLogf("知らせ: %s", line)
	}

	if line := scene3dEntryWarning(p.Game, entry); line != "" {
		ewLogf("%s", line)
	}

	fingerprint := ""
	// WhyNot: --apply-deferred で使い回さない — 候補は書き出しの最後のブラウザの確かめで出すので、使い回すと出せない。
	if o.Reuse && !o.Check && !o.ApplyDeferred {
		fingerprint, err = exportInputsFingerprint(p, o, id, findWebEncoders(p.Engine, compress))
		if err != nil {
			fmt.Fprintf(errOut, "fge export-web: 指紋を作れない: %v\n", err)
			return 2
		}
		if canReuseExport(p, fingerprint) {
			version, _ := os.ReadFile(filepath.Join(p.Out, "version.txt"))
			fmt.Fprintf(out, "export-web: %s（版 %s・前と同じ入力なので使い回した）\n", p.Out, strings.TrimSpace(string(version)))
			// WhyNot: 使い回す時に門を飛ばさない — 赤のまま書き出した物を緑の終わりの番号で返すと、写す手順がそのまま配る。
			r, err := runWebCheck(p.Out, false)
			if err != nil {
				fmt.Fprintf(errOut, "fge export-web: 使い回す書き出しを読めない: %v\n", err)
				return 1
			}
			var w strings.Builder
			writeWebCheck(&w, r)
			out.WriteString(w.String())
			if !r.Gate.green() && !o.Draft && budget.Declared {
				os.RemoveAll(p.Out)
				fmt.Fprintf(errOut, "fge export-web: 門が赤なので書き出し先 %s を消した（作業中に開くだけなら --draft）\n", p.Out)
				return 1
			}
			if !r.Gate.green() && !o.Draft {
				fmt.Fprintln(out, "  ★ 上の「止める」は公開の道（web-check）での扱い。web.startupBudget を書いていないので、移行の間は手元の書き出しを止めない（手で写す前に bin/fge web-check）")
			}
			return 0
		}
		// WhyNot: 前の指紋を残したまま組まない — 途中で止まると、半端な書き出し先を前の指紋が「同じ」と言う。
		os.Remove(exportReuseStamp(p))
	}

	if p.FullWebEntry != "" {
		ewLogf("① ゲームを %s へ写す（engine_full_web %s・置き場 %s）", p.Project, p.Version, filepath.Base(p.FullWebEntry))
	} else {
		ewLogf("① ゲームを %s へ写す（engine_full_web %s・置き場が無いので build/engine_full_web を直に読む。make sync-engine-full-web で置き場に入る）", p.Project, p.Version)
	}
	if err := prepareExportProject(p); err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 2
	}
	if o.Check {
		code := runLogged(p.Project, filepath.Join(p.Work, "check.log"), true,
			java, "-Xss64m", "-jar", p.FlixJar, "check")
		if code != 0 {
			fmt.Fprintf(errOut, "fge export-web --check: 型検査が通らない（ログ %s）。\n  次: web/WebMain.flix か engine_web を直す\n",
				filepath.Join(p.Work, "check.log"))
			return 1
		}
		cleanupExportWork(p, o.KeepWork)
		fmt.Fprintln(out, "export-web --check: 型検査が通った")
		return 0
	}

	fatLog := filepath.Join(p.Work, "fatjar.log")
	ewLogf("① flix build-fatjar（ログ %s）", fatLog)
	if runLogged(p.Project, fatLog, false, java, "-Xss64m", "-jar", p.FlixJar, "build-fatjar", "--entrypoint", "WebMain.main") != 0 {
		fmt.Fprintf(errOut, "%s\nfge export-web: flix build-fatjar が失敗した（ログ %s）。\n  次: 上の誤りを直すか、--check で型検査だけ流す\n",
			tailFile(fatLog, 40), fatLog)
		return 1
	}
	fatjar, err := findFatJar(filepath.Join(p.Project, "artifact"))
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}

	jars, err := teavmJars(exportWebLog)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 2
	}
	asm := findTeavmJar(jars, "teavm-relocated-libs-asm")
	core := findTeavmJar(jars, "teavm-core")
	if asm == "" || core == "" {
		fmt.Fprintln(errOut, "fge export-web: TeaVM の jar の中に teavm-relocated-libs-asm か teavm-core が無い。\n  次: FLIX_GE_TEAVM_DIR の中身を確かめるか、外して Maven から取らせる")
		return 2
	}

	rewritten := filepath.Join(p.Work, "rewritten.jar")
	ewLogf("② バイトコードの付け替え")
	if code := runRewrite(java, asm, p.WebToolsJar, fatjar, rewritten, filepath.Join(p.Work, "rewrite.log")); code != 0 {
		fmt.Fprintf(errOut, "%s\nfge export-web: 付け替え（fge.teavmfix.Rewrite）が失敗した（ログ %s）。\n  次: engine の根で make sync-engine-full-web を流して fge-web-tools を作り直す\n",
			tailFile(filepath.Join(p.Work, "rewrite.log"), 20), filepath.Join(p.Work, "rewrite.log"))
		return 1
	}

	ewLogf("②' ゲームの .flix の位置を作業フォルダからの相対（game/...）へ")
	leakFinder := newWebLeakFinder(os.Getenv("HOME"), os.Getenv("USERPROFILE"), p.Work, p.Game)
	relativized := filepath.Join(p.Work, "relativized.jar")
	paths, err := rewriteJarSourcePaths(rewritten, relativized, leakFinder)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: 位置の置き換えが失敗した: %v\n", err)
		return 1
	}
	ewLogf("  置き換えた位置 %d", paths.Replaced)
	if len(paths.Leaks) > 0 {
		fmt.Fprintf(errOut, "fge export-web: %s\n", webLeakReport(map[string][]string{"jar": paths.Leaks}, o.ShowLeaks, false))
		return 1
	}
	rewritten = relativized

	if len(embedPlan.Embedded) > 0 {
		seed, err := embedSeedOf(p.Game, embedPlan.Embedded)
		if err != nil {
			fmt.Fprintf(errOut, "fge export-web: %v\n", err)
			return 1
		}
		embeddedJar := filepath.Join(p.Work, "embedded.jar")
		embedLog := filepath.Join(p.Work, "embed.log")
		ewLogf("②'' 素材を符号にして wasm へ埋め込む（web.embed %d 本）", len(embedPlan.Embedded))
		if code := runEmbed(java, asm, p.WebToolsJar, p.WebJar, p.Game, rewritten, embeddedJar, embedLog, embedPlan.Embedded, seed); code != 0 {
			fmt.Fprintf(errOut, "%s\nfge export-web: 埋め込み（fge.teavmfix.Embed）が失敗した（ログ %s）。\n  次: 上の行を読む（EmbeddedData が無いと言うなら engine の根で make sync-engine-full-web を流して fge-web と fge-web-tools を作り直す）\n",
				tailFile(embedLog, 20), embedLog)
			return 1
		}
		rewritten = embeddedJar
	}

	wasmDir := filepath.Join(p.Work, "wasm")
	teavmLog := filepath.Join(p.Work, "teavm.log")
	ewLogf("③ TeaVM（wasm-gc・ログ %s）", teavmLog)
	if err := os.RemoveAll(wasmDir); err != nil {
		fmt.Fprintf(errOut, "fge export-web: %s を消せない: %v\n", wasmDir, err)
		return 2
	}
	if err := os.MkdirAll(wasmDir, 0o755); err != nil {
		fmt.Fprintf(errOut, "fge export-web: %s を作れない: %v\n", wasmDir, err)
		return 2
	}
	cp := strings.Join(append(append([]string{p.WebToolsJar}, jars...), rewritten), string(os.PathListSeparator))
	teavmCode := runLogged(p.Work, teavmLog, false, java, "-Xmx"+teavmHeap(), "-cp", cp, "fge.teavmfix.BuildWasm",
		"Main", wasmDir, "classes.wasm")
	logText, _ := os.ReadFile(teavmLog)
	if errs, shown := teavmErrors(string(logText), 5); errs > 0 {
		fmt.Fprintf(errOut, "%s\nfge export-web: TeaVM の ERROR が %d 件（ログ %s）。\n  次: 上の行のクラス・メソッドを engine_web の shim か付け替えで手当てする\n",
			shown, errs, teavmLog)
		return 1
	}
	wasm := filepath.Join(wasmDir, "classes.wasm")
	if teavmCode != 0 || !fileExists(wasm) {
		fmt.Fprintf(errOut, "%s\nfge export-web: TeaVM が classes.wasm を出さなかった（終わりの番号 %d・ログ %s）。\n  次: ログの最後を読む（メモリ不足なら FLIX_GE_TEAVM_XMX で TeaVM の上限を上げる・今は "+teavmHeap()+"。fge.teavmfix.BuildWasm が無いと言うなら engine の根で make sync-engine-full-web を流して fge-web-tools を作り直す）\n",
			tailFile(teavmLog, 20), teavmCode, teavmLog)
		return 1
	}

	wasmBytes, err := os.ReadFile(wasm)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	// WhyNot: 書き出し先へ置いてから探さない — 止めた後も置いた物が残り、置き場へ写す手順だとそのまま配られる。
	leaks, err := findWasmLeaks(wasmBytes, leakFinder)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: wasm を読めない: %v\n", err)
		return 1
	}
	if leaks.total() > 0 {
		fmt.Fprintf(errOut, "fge export-web: %s\n", webLeakReport(map[string][]string{"wasm": leaks.Wasm, "names": leaks.Names}, o.ShowLeaks, true))
		return 1
	}

	ewLogf("④ アセットの束 → %s", p.Out)
	prevLossless := loadPreviousLosslessImages(p.Out)
	if err := resetExportOut(p.Out); err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 2
	}
	b, err := buildWebBundle(p.Game, id, proj, usesScene3dEntry(entry))
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	b.Files = strip.without(embedPlan.withoutHidden(b.Files))
	if len(embedPlan.Omitted) > 0 {
		ewLogf("  web.omit で配らない: %s", strings.Join(embedPlan.Omitted, "・"))
	}
	b.withTouch(proj, touch)
	splash, warning := buildWebSplash(p.Engine, startPrompt, touch.PortraitDesign)
	if warning != "" {
		ewLogf("知らせ: %s", warning)
	}
	b.Splash = &splash
	bundled, deferredSet := map[string]bool{}, map[string]bool{}
	for _, rel := range b.copyList() {
		bundled[rel] = true
	}
	for _, rel := range deferredPlan.Paths {
		deferredSet[rel] = true
	}
	images := map[string]bool{}
	for _, rel := range b.Images {
		images[rel] = true
	}
	afterTap, err := resolveWebAfterTap(proj.Web, deferredPolicy, bundled, deferredSet, images)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	splash.AfterTap = &afterTap
	for _, rel := range b.copyList() {
		if err := copyFile(filepath.Join(p.Game, filepath.FromSlash(rel)), exportAssetPath(p.Out, rel)); err != nil {
			fmt.Fprintf(errOut, "fge export-web: 素材を写せない: %v\n", err)
			return 1
		}
	}

	ewLogf("⑤ フォントアトラス")
	atlases, code, err := placeFontAtlases(p, o, proj.fontNames())
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return code
	}
	b.Files = append(b.Files, atlases...)
	sort.Strings(b.Files)

	ewLogf("⑥ 素材を小さくする（絵は WebP・音は Opus・アトラスは画素を WebP か gzip）")
	enc := findWebEncoders(p.Engine, compress)
	report := transcodeWebAssets(p.Out, &b, atlases, compress, enc)
	report.Notes = append(report.Notes, losslessNotes...)
	report.AutoLossyLines = buildWebAutoLossySummary(report.Verdicts, compress.Auto, compress.LossyImages, prevLossless)
	logWebAutoLossy(report.Verdicts)
	if b.Deferred, _, err = applyWebDeferredPolicy(webDeferredEntries(p.Out, &b, deferredPlan.Paths, textureNames), deferredPolicy, &b); err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	setWebArrivalSeconds(p.Out, &b)

	ewLogf("⑦ 頁")
	b.ServiceWorker = serviceWorker
	bookedBudget := budget
	b.StartupBudget = &bookedBudget
	switch {
	case enc.Brotli != "":
		b.WasmBrotli = webWasmBrotliFile
	case compress.WasmBrotli:
		// WhyNot: 書き出しを止めない — Studio を使う人の機械に brotli が無くても、遅いだけで遊べる頁は出せる。
		note := brotliMissingNote(webWireSize(wasm))
		ewLogf("%s", note)
		report.Notes = append(report.Notes, note)
	}
	hash, err := writeWebPage(p, b, wasm, core, enc.Brotli)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	if len(embedPlan.Embedded) > 0 {
		ewLogf("⑧ 埋め込んだ素材の平文が書き出し先に残っていないか")
		unchecked, err := checkEmbedLeaks(p.Out, p.Game, embedPlan.Embedded)
		if err != nil {
			// WhyNot: 止めた書き出し先を残さない — 頁と版はもう書いてあり、置き場へ写すだけの手順だと平文の残る版が配られる。
			os.RemoveAll(p.Out)
			fmt.Fprintf(errOut, "fge export-web: %v\n  書き出し先 %s は消した\n", err, p.Out)
			return 1
		}
		for _, rel := range unchecked {
			ewLogf("  %s は ASCII でない字が続く所が無く、平文の残りを探せなかった", rel)
		}
	}
	var used *webUsedAssets
	var missing *webMissingReport
	checks := webBundleChecks{Title4g: "ok"}
	var tap *webTapMeasure
	if o.NoBrowserCheck {
		ewLogf("⑨ ブラウザで wasm を読めるか: --no-browser-check で飛ばした")
		checks.Title4g, checks.SkippedWhy = "skipped", "--no-browser-check"
	} else {
		ewLogf("⑨ ブラウザで wasm を読めるか（ヘッドレスの Chrome で ?capture=%d・タイトルの %d コマに使う素材を記録）", webLoadCheckFrames, webTitleFrames)
		skipped, recorded, err := checkWebLoadsRecording(p.Out, webLoadCheckFrames, webTitleFrames, webLoadCheckWait())
		used = recorded
		if err != nil {
			fmt.Fprintf(errOut, "fge export-web: 書き出した頁をブラウザで開くと止まる: %v\n"+
				"  書き出し先 %s は残してある（配ると真っ白になる）。\n"+
				"  次: CompileError なら TeaVM は通るのにブラウザが wasm を読めない形（JSO の物を Object を受ける所へ渡す等。JSO は fge.web の Java の類に包んで渡す）。"+
				"それ以外は頁を開いて開発者の道具の console を読む\n", err, p.Out)
			return 1
		}
		if skipped != "" {
			ewLogf("知らせ: %s", skipped)
			checks.Title4g, checks.SkippedWhy = "skipped", "Chrome が見つからない"
		}
		if skipped == "" && len(b.Deferred) > 0 {
			ewLogf("⑨' 4G（?net=4g）のタイトルの %d コマで engine が待つか", webTitleFrames)
			missing, err = checkWebMissingTitle(p.Out, webTitleFrames, webLoadCheckWait())
			checks.Title4g, checks.SkippedWhy = webTitle4gOf(missing, err)
			if err != nil {
				ewLogf("知らせ: %v", err)
				missing = nil
			}
		}
		if skipped == "" && webTapNeedsMeasure(&b) {
			ewLogf("⑨'' 4G（?net=4g）で開いてすぐ押し、押してから最初の場面が動くまでを測る（タイトルで %s）", strings.Join(budget.startKeys(), "・"))
			m, why, err := measureWebTapWait(p.Out, budget.startKeys(), webLastWaitingArrival(&b), webLoadCheckWait())
			switch {
			case err != nil:
				checks.TapSkippedWhy = "測れなかった: " + err.Error()
				ewLogf("知らせ: 押した後を測れなかった: %v", err)
			case why != "":
				checks.TapSkippedWhy = why
			default:
				tap = &m
				checks.TapWaitSeconds, checks.TapNoRecord = tap.tapSeconds(), tap.NoRecord
			}
		}
	}
	if tap == nil && checks.TapSkippedWhy == "" && webTapNeedsMeasure(&b) {
		checks.TapSkippedWhy = "Chrome が見つからない"
		if o.NoBrowserCheck {
			checks.TapSkippedWhy = "--no-browser-check"
		}
	}
	b.Checks = &checks
	suggestion := webCandidateAdvice(p.Out, &b, proj, deferredFonts, embedPlan, used)
	g := webGateOf(p.Out, &b, budget)
	if checks.Title4g == "stopped" {
		g.Red = append(g.Red, "4G（?net=4g）のタイトルで、届いていない後回しの物を待って止まった（上の知らせ）— タイトルで使う物は web.deferred から外す")
	}
	if suggestion != "" {
		g.Advice = append([]string{suggestion}, g.Advice...)
	}
	stop := !g.green() && !o.Draft && budget.Declared
	if !g.green() && o.Draft {
		b.Draft, b.DraftReasons = true, g.Red
	}
	// WhyNot: 確かめの結果を書き出し先の外（report）に置かない — gh-pages の根や play/ に写したフォルダを web-check が Chrome 無しで読めなくなる。
	if !stop {
		if hash, err = writeWebPageMeta(p, b, core); err != nil {
			fmt.Fprintf(errOut, "fge export-web: %v\n", err)
			return 1
		}
		// WhyNot: 書き直す前の判定のまま終えない — bundle.json が checks の分だけ大きくなり、境目の束は web-check で赤になる。
		after := webGateOf(p.Out, &b, budget)
		if g.green() && !after.green() {
			after.Advice = g.Advice
			g = after
			stop = !o.Draft && budget.Declared
			if o.Draft {
				b.Draft, b.DraftReasons = true, g.Red
				if hash, err = writeWebPageMeta(p, b, core); err != nil {
					fmt.Fprintf(errOut, "fge export-web: %v\n", err)
					return 1
				}
			}
		}
	}
	cleanupExportWork(p, o.KeepWork)
	if fingerprint != "" && !stop {
		if err := os.WriteFile(exportReuseStamp(p), []byte(exportReuseLine(fingerprint, p.Out, hash)), 0o644); err != nil {
			ewLogf("知らせ: 指紋を残せない（次の --reuse も組み直す）: %v", err)
		}
	}

	if stop {
		fmt.Fprintf(out, "export-web: %s（版 %s・門が赤なので最後に消す）\n", p.Out, hash)
	} else {
		fmt.Fprintf(out, "export-web: %s（版 %s）\n", p.Out, hash)
	}
	writeExportSizes(out, p.Out, b, atlases, report, strip)
	writeWebMissingTitleTo(out, missing)
	var tw strings.Builder
	tapSkipped := ""
	if tap == nil {
		tapSkipped = checks.TapSkippedWhy
	}
	writeWebTapMeasure(&tw, tap, tapSkipped)
	writeWebGateSummary(&tw, g, budget, o.Draft)
	out.WriteString(tw.String())
	titleCode := writeTitleAssets(out, errOut, o, p, &b, proj, deferredFonts, embedPlan, used)
	if stop {
		// WhyNot: 赤の書き出し先を残さない — 手で gh-pages の根へ写す道は web-check を通らず、そのまま配られる。
		os.RemoveAll(p.Out)
		fmt.Fprintf(errOut, "fge export-web: 門が赤なので書き出し先 %s を消した。\n", p.Out)
		for _, red := range g.Red {
			fmt.Fprintf(errOut, "  止めた: %s\n", red)
		}
		var aw strings.Builder
		writeWebGateAdvice(&aw, g.Advice, "")
		fmt.Fprintf(errOut, "%s  作業中に開くだけなら --draft（web-check が拒む draft のマーカーが付く）\n", aw.String())
		return 1
	}
	return titleCode
}
