package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/fpkgstore"
	"github.com/ababup1192/flix_game_engine/go/internal/javacmd"
	"github.com/ababup1192/flix_game_engine/go/internal/mvncache"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

const exportWebUsage = `使い方: fge export-web <ゲームのフォルダ> [--out <dir>] [--check] [--id <名前>] [--font-atlas-dir <dir>]
                       [--work <dir>] [--engine <dir>] [--keep-work] [--no-browser-check] [--reuse] [--show-leaks]
                       [--apply-deferred]
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
	ShowLeaks, ApplyDeferred                  bool
}

// exportWebCopyExcludes はゲームの根の直下で写さない物。
// WhyNot: lib を写さないのは、デスクトップの engine の fpkg が入っていて engine_full_web と取り違えるため。
var exportWebCopyExcludes = map[string]bool{
	"lib": true, "build": true, "artifact": true, "debug": true, "gallery": true,
	"saves": true, "reference": true, ".git": true, "packages.lock": true,
}

// exportWebMediaExts は files に入れない拡張子（絵・音・フォントは images・sounds・アトラスで別に運ぶ）。
var exportWebMediaExts = map[string]bool{
	".ttf": true, ".otf": true, ".png": true, ".jpg": true, ".jpeg": true, ".webp": true,
	".wav": true, ".ogg": true, ".mp3": true,
}

// exportWebDecodedImageExts は 3D の入口のゲームが readBytes で読み、imageDecoder で解く拡張子。project.json の textures の物も files へ入れる。
// textures の物を web.compress が WebP に替えたら readBytes にも WebP が届く（imageDecoder は解ける）。
// WhyNot: textures の物の元の png を別に配らない — 同じ絵を 2 回運び、配る量が増える。
// WhyNot: 2D の入口のゲームでは入れない — 画面に使わない元絵まで束に入り、配る量が増える。
var exportWebDecodedImageExts = map[string]bool{".png": true, ".jpg": true, ".jpeg": true}

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

// exportWebPaths は 1 回の書き出しで使う道の一式。
type exportWebPaths struct {
	Game, Engine, Version, Work, Project, Out                                       string
	FullWebFpkg, FullWebToml, GlJar, WebJar, WebToolsJar, WebJS, IndexHTML, FlixJar string
	// 置き場（build/fpkg-store）のエントリ。空なら置き場が無く、build/engine_full_web などを直に読んでいる。
	FullWebEntry string
}

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
	deferredGlobs, err := resolveWebDeferred(proj.Web)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	textureNames := textureNamesByPath(proj)
	deferredPlan, err := planWebDeferred(early, deferredGlobs, embedPlan, proj.fontNames(), textureNames)
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
	deferredPlan, textureNames = withDeferredFonts(deferredPlan, deferredFonts, textureNames)
	deferredPolicy, err := resolveWebDeferredPolicy(proj.Web)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	if _, lines, err := applyWebDeferredPolicy(webDeferredEntries("", &early, deferredPlan.Paths, textureNames), deferredPolicy, &early); err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	} else {
		deferredPlan.Warnings = append(deferredPlan.Warnings, lines...)
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
	afterTap, err := resolveWebAfterTap(proj.Web, deferredPolicy, bundled, deferredSet)
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
	if o.NoBrowserCheck {
		ewLogf("⑨ ブラウザで wasm を読めるか: --no-browser-check で飛ばした")
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
		}
		if skipped == "" && len(b.Deferred) > 0 {
			ewLogf("⑨' 4G（?net=4g）のタイトルの %d コマで engine が待つか", webTitleFrames)
			if missing, err = checkWebMissingTitle(p.Out, webTitleFrames, webLoadCheckWait()); err != nil {
				// WhyNot: 止めない — 頁は上の確かめで開けている。4G の届き方をまねる頁だけの不具合で、配った物が止まるのとは違う。
				ewLogf("知らせ: %v", err)
				missing = nil
			}
		}
	}
	cleanupExportWork(p, o.KeepWork)
	if fingerprint != "" {
		if err := os.WriteFile(exportReuseStamp(p), []byte(exportReuseLine(fingerprint, p.Out, hash)), 0o644); err != nil {
			ewLogf("知らせ: 指紋を残せない（次の --reuse も組み直す）: %v", err)
		}
	}

	fmt.Fprintf(out, "export-web: %s（版 %s）\n", p.Out, hash)
	writeExportSizes(out, p.Out, b, atlases, report, strip)
	writeWebMissingTitleTo(out, missing)
	return writeTitleAssets(out, errOut, o, p, &b, proj, deferredFonts, embedPlan, used)
}

// writeTitleAssets は最後の確かめで記録したタイトルの間の素材から後回しの候補を書き、--apply-deferred なら project.json へ足す。
func writeTitleAssets(out, errOut *strings.Builder, o exportWebOptions, p exportWebPaths, b *webBundle, proj exportProject,
	deferredFonts []string, embed webEmbedPlan, used *webUsedAssets) int {
	if used == nil {
		if o.ApplyDeferred {
			fmt.Fprintln(errOut, "fge export-web: --apply-deferred: ブラウザの確かめで素材の記録が取れなかった（Chrome が無いか、engine の fge-web.js が記録を持たない）。project.json は変えていない")
			return 1
		}
		return 0
	}
	hidden := map[string]bool{}
	for _, rel := range append(append([]string{}, embed.Embedded...), embed.Omitted...) {
		hidden[rel] = true
	}
	s := suggestWebDeferred(p.Out, b, proj, deferredFonts, hidden, *used, webTitleFrames)
	w := bufio.NewWriter(out)
	defer w.Flush()
	writeDeferredSuggestion(w, s, o.Game)
	if raw, err := json.MarshalIndent(used, "", "  "); err == nil {
		record := filepath.Join(p.Work, "title-assets.json")
		if os.WriteFile(record, append(raw, '\n'), 0o644) == nil {
			fmt.Fprintf(w, "    記録の全部（名前・道 → 初めて使ったコマ）: %s\n", record)
		}
	}
	if !o.ApplyDeferred {
		return 0
	}
	file := filepath.Join(p.Game, "project.json")
	changed, err := applyDeferredToProject(file, s.Globs, s.Fonts)
	if err != nil {
		w.Flush()
		fmt.Fprintf(errOut, "fge export-web: --apply-deferred: %s を書き換えられない: %v\n", file, err)
		return 1
	}
	writeAppliedDeferred(w, file, changed, s)
	return 0
}

// writeWebMissingTitleTo は ?net=4g のタイトルの間の記録を書き出しの表の後へ書く。
func writeWebMissingTitleTo(out *strings.Builder, r *webMissingReport) {
	w := bufio.NewWriter(out)
	writeWebMissingTitle(w, r, webTitleFrames)
	w.Flush()
}

// readWebEntry は web/WebMain.flix の字（読めなければ空）。
func readWebEntry(game string) string {
	entry, err := os.ReadFile(filepath.Join(game, "web", "WebMain.flix"))
	if err != nil {
		return ""
	}
	return string(entry)
}

// usesScene3dEntry は入口の字 entry が 3D の入口を使うか。
func usesScene3dEntry(entry string) bool {
	return strings.Contains(entry, "WebLayer.withProject3d(")
}

// scene3dEntryWarning は、src が Scene3d を使うのに web/WebMain.flix が 2D の入口のままなら知らせる 1 行を返す（無ければ空）。
// WhyNot: 止めない — 3D の場面を持たない画面だけを書き出すゲームもあり、走らせれば初回に警告も出る。
func scene3dEntryWarning(game, entry string) string {
	if !strings.Contains(entry, "WebLayer.withProject(") {
		return ""
	}
	found := false
	_ = filepath.WalkDir(filepath.Join(game, "src"), func(path string, d fs.DirEntry, err error) error {
		if err != nil || found || d.IsDir() || filepath.Ext(path) != ".flix" {
			return nil
		}
		text, readErr := os.ReadFile(path)
		found = readErr == nil && strings.Contains(string(text), "Scene3d.")
		return nil
	})
	if !found {
		return ""
	}
	return "src が Scene3d を使っていますが web/WebMain.flix は WebLayer.withProject のままです。3D を描くなら WebLayer.withProject3d へ替えてください"
}

// resolveExportWebPaths は道を決め、要る物が揃っているかを見る。足りなければ終わりの番号 2 と次の 1 手。
func resolveExportWebPaths(o exportWebOptions) (exportWebPaths, int, error) {
	var p exportWebPaths
	game, err := filepath.Abs(o.Game)
	if err != nil || !dirExists(game) {
		return p, 2, fmt.Errorf("ゲームのフォルダが無い: %s", o.Game)
	}
	p.Game = game
	if !fileExists(filepath.Join(game, "web", "WebMain.flix")) {
		return p, 2, fmt.Errorf("web/WebMain.flix が無い（%s）。\n  次: テンプレートの web/WebMain.flix を写して入口を書く", game)
	}
	toml, err := os.ReadFile(filepath.Join(game, "flix.toml"))
	if err != nil {
		return p, 2, fmt.Errorf("flix.toml を読めない: %v", err)
	}
	p.Version = engineVersionFromToml(string(toml))
	if p.Version == "" {
		return p, 2, errors.New(`flix.toml に "github:ababup1192/flix_game_engine" = { version = "…" } が無い。` +
			"\n  次: engine を使うゲームのフォルダを渡す")
	}

	p.Engine = o.Engine
	if p.Engine == "" {
		p.Engine = engineDirOf(repoRoot())
	}
	if p.Engine, err = filepath.Abs(p.Engine); err != nil || !fileExists(filepath.Join(p.Engine, "mk", "game.mk")) {
		return p, 2, fmt.Errorf("engine の根が見つからない（%s）。\n  次: --engine <engine のフォルダ> を渡す", p.Engine)
	}
	p.FlixJar = os.Getenv("FLIX_JAR")
	if p.FlixJar == "" {
		p.FlixJar = filepath.Join(p.Engine, "bin", "flix.jar")
	}

	v := p.Version
	if code, err := ensureFullWebFresh(p.Engine, v); err != nil {
		return p, code, err
	}
	// WhyNot: build/engine_full_web と build/gl-jar・build/web-jar を直に読まない — 別の所で make sync-engine-full-web が走ると、
	// 書き出しの途中（TeaVM は数分後に fge-web-tools を読む）で中身が書き換わる。置き場のエントリは置いた後は変わらない。
	// 置き場が無い engine（配った版・置き場を作る前の作業コピー）だけ前の置き場を読む。
	if entry, ok := fpkgstore.Current(p.Engine, fpkgstore.EngineFullWeb); ok {
		p.FullWebEntry = entry
		p.FullWebFpkg = filepath.Join(entry, "package.fpkg")
		p.FullWebToml = filepath.Join(entry, "flix.toml")
		p.GlJar = filepath.Join(entry, glJarNameOf(p.FullWebToml, v))
		p.WebJar = filepath.Join(entry, "fge-web-"+v+".jar")
		p.WebToolsJar = filepath.Join(entry, "fge-web-tools-"+v+".jar")
	} else {
		p.FullWebFpkg = filepath.Join(p.Engine, "build", "engine_full_web", "artifact", "package.fpkg")
		p.FullWebToml = filepath.Join(p.Engine, "build", "engine_full_web", "flix.toml")
		p.GlJar = filepath.Join(p.Engine, "build", "gl-jar", glJarNameOf(p.FullWebToml, v))
		p.WebJar = filepath.Join(p.Engine, "build", "web-jar", "fge-web-"+v+".jar")
		p.WebToolsJar = filepath.Join(p.Engine, "build", "web-jar", "fge-web-tools-"+v+".jar")
	}
	p.WebJS = filepath.Join(p.Engine, "engine_web", "js", "fge-web.js")
	p.IndexHTML = filepath.Join(p.Engine, "engine_web", "js", "index.html")
	var missing []string
	for _, f := range []string{p.FullWebFpkg, p.FullWebToml, p.GlJar, p.WebJar, p.WebToolsJar} {
		if !fileExists(f) {
			missing = append(missing, f)
		}
	}
	if len(missing) > 0 {
		hint := "engine の根で make sync-engine-full-web を流す"
		if ev := status.ReadEngineVersion(p.Engine); ev != "" && ev != v {
			hint += fmt.Sprintf("（engine は %s・ゲームは %s。版をそろえる）", ev, v)
		}
		return p, 2, fmt.Errorf("engine_full_web の物が無い:\n  %s\n  次: %s", strings.Join(missing, "\n  "), hint)
	}
	for _, f := range []string{p.FlixJar, p.WebJS, p.IndexHTML} {
		if !fileExists(f) {
			return p, 2, fmt.Errorf("%s が無い。\n  次: engine の作業コピーを確かめる（flix.jar なら FLIX_JAR で名指しできる）", f)
		}
	}

	p.Work = o.Work
	if p.Work == "" {
		p.Work = filepath.Join(game, "build", "web-export")
	}
	p.Out = o.Out
	if p.Out == "" {
		p.Out = filepath.Join(game, "build", "web")
	}
	if p.Work, err = filepath.Abs(p.Work); err != nil {
		return p, 2, err
	}
	if p.Out, err = filepath.Abs(p.Out); err != nil {
		return p, 2, err
	}
	p.Project = filepath.Join(p.Work, "project")
	if isWithin(p.Work, game) != "" || isWithin(p.Out, game) != "" {
		return p, 2, errors.New("--work・--out にゲームのフォルダそのものか、その上のフォルダは渡せない（消して作り直すため）")
	}
	return p, 0, nil
}

var engineDepRe = regexp.MustCompile(`"github:ababup1192/flix_game_engine"\s*=\s*\{[^}]*?\bversion\s*=\s*"([^"]+)"`)

// engineVersionFromToml はゲームの flix.toml が使う engine の版。無ければ空。
func engineVersionFromToml(toml string) string {
	for _, line := range strings.Split(toml, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		if m := engineDepRe.FindStringSubmatch(line); m != nil {
			return m[1]
		}
	}
	return ""
}

// isWithin は child が parent の中（同じも含む）なら parent から見た道、外なら空。
func isWithin(parent, child string) string {
	rel, err := filepath.Rel(parent, child)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return ""
	}
	return rel
}

// exportWebJava は java の呼び方（javacmd.Resolve: JAVA → PATH の動く java → engine の devbox の jdk → main の checkout の物）。
func exportWebJava(engine string) string {
	return javacmd.Resolve(engine)
}

// prepareExportProject は作業フォルダの project/ を作り直し、ゲーム・WebMain・engine_full_web を置く。
// WhyNot: ゲームのフォルダで直に組まないのは、src へ WebMain を入れ lib を差し替えるとゲームのデスクトップの組み立てが壊れるため。
func prepareExportProject(p exportWebPaths) error {
	if err := os.RemoveAll(p.Project); err != nil {
		return fmt.Errorf("%s を消せない: %v", p.Project, err)
	}
	if err := copyGameTree(p.Game, p.Project); err != nil {
		return fmt.Errorf("ゲームを写せない: %v", err)
	}
	if err := copyFile(filepath.Join(p.Game, "web", "WebMain.flix"), filepath.Join(p.Project, "src", "WebMain.flix")); err != nil {
		return err
	}
	v := p.Version
	pkg := filepath.Join(p.Project, "lib", "github", "ababup1192", "flix_game_engine", v)
	ext := filepath.Join(p.Project, "lib", "external")
	for src, dst := range map[string]string{
		p.FullWebFpkg: filepath.Join(pkg, "flix_game_engine-"+v+".fpkg"),
		p.FullWebToml: filepath.Join(pkg, "flix_game_engine-"+v+".toml"),
		p.GlJar:       filepath.Join(ext, filepath.Base(p.GlJar)),
		p.WebJar:      filepath.Join(ext, filepath.Base(p.WebJar)),
	} {
		if err := copyFile(src, dst); err != nil {
			return err
		}
	}
	// WhyNot: project は毎回作り直すので、中に置くと書き出しのたびに取り直しになり Maven Central が 429 を返す。
	mvncache.Link(p.Project)
	return copyLocalNativeJars(p, ext)
}

// copyLocalNativeJars は手元にある LWJGL の natives の jar を写す。
// WhyNot: 無ければ Flix が 30 本を Maven Central へ取りに行き、続けて書き出すと 429 で止まる。
// WhyNot: 無い時に誤りにしないのは、同梱の engine には render_gl が無く、取りに行けば通るため。
func copyLocalNativeJars(p exportWebPaths, ext string) error {
	for _, dir := range []string{filepath.Join(p.Game, "lib", "external"), filepath.Join(p.Engine, "render_gl", "lib", "external")} {
		jars, err := filepath.Glob(filepath.Join(dir, "lwjgl-*-natives-*.jar"))
		if err != nil {
			return err
		}
		for _, jar := range jars {
			dst := filepath.Join(ext, filepath.Base(jar))
			if _, err := os.Stat(dst); err == nil {
				continue
			}
			if err := copyFile(jar, dst); err != nil {
				return err
			}
		}
	}
	return nil
}

// copyGameTree はゲームの根の直下の exportWebCopyExcludes を除いて全部写す（symlink は中身を写す）。
func copyGameTree(game, dst string) error {
	entries, err := os.ReadDir(game)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if exportWebCopyExcludes[e.Name()] {
			continue
		}
		if err := copyAny(filepath.Join(game, e.Name()), filepath.Join(dst, e.Name())); err != nil {
			return err
		}
	}
	return nil
}

func copyAny(src, dst string) error {
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return copyFile(src, dst)
	}
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dst, 0o755); err != nil {
		return err
	}
	for _, e := range entries {
		if err := copyAny(filepath.Join(src, e.Name()), filepath.Join(dst, e.Name())); err != nil {
			return err
		}
	}
	return nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	outF, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(outF, in); err != nil {
		outF.Close()
		return err
	}
	return outF.Close()
}

// runLogged は dir で cmd を流し、出力を log へ書く（echo なら画面にも）。終わりの番号を返す。
func runLogged(dir, log string, echo bool, name string, args ...string) int {
	if err := os.MkdirAll(filepath.Dir(log), 0o755); err != nil {
		ewLogf("%s を作れない: %v", filepath.Dir(log), err)
		return 2
	}
	f, err := os.Create(log)
	if err != nil {
		ewLogf("%s を書けない: %v", log, err)
		return 2
	}
	defer f.Close()
	var w io.Writer = f
	if echo {
		w = io.MultiWriter(f, exportWebLog)
	}
	c := exec.Command(name, args...)
	c.Dir = dir
	c.Stdout, c.Stderr = w, w
	if err := c.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return ee.ExitCode()
		}
		fmt.Fprintf(f, "%s を起こせない: %v\n", name, err)
		ewLogf("%s を起こせない: %v（次: JAVA に java の道を渡す）", name, err)
		return 2
	}
	return 0
}

// runRewrite は fge.teavmfix.Rewrite を流し、標準出力の `rewrite <種類> <数>` の行を画面へ出す。
func runRewrite(java, asmJar, toolsJar, fatjar, dst, log string) int {
	cp := asmJar + string(os.PathListSeparator) + toolsJar
	code := runLogged(filepath.Dir(dst), log, false, java, "-cp", cp, "fge.teavmfix.Rewrite", fatjar, dst)
	text, _ := os.ReadFile(log)
	for _, line := range strings.Split(string(text), "\n") {
		if strings.HasPrefix(line, "rewrite ") {
			ewLogf("  %s", strings.TrimRight(line, "\r"))
		}
	}
	if code == 0 && !fileExists(dst) {
		return 1
	}
	return code
}

func findFatJar(dir string) (string, error) {
	jars, _ := filepath.Glob(filepath.Join(dir, "*.jar"))
	if len(jars) == 0 {
		return "", fmt.Errorf("%s に fatjar が無い。\n  次: fatjar.log を読む", dir)
	}
	sort.Strings(jars)
	return jars[0], nil
}

// teavmErrors は TeaVM のログで `ERROR` で始まる行の数と、最初の limit 件（とそれぞれ次の 2 行）。
func teavmErrors(log string, limit int) (int, string) {
	lines := strings.Split(strings.ReplaceAll(log, "\r\n", "\n"), "\n")
	count := 0
	var shown strings.Builder
	for i, line := range lines {
		if !strings.HasPrefix(line, "ERROR") {
			continue
		}
		count++
		if count > limit {
			continue
		}
		for j := i; j < len(lines) && j <= i+2; j++ {
			shown.WriteString(lines[j])
			shown.WriteString("\n")
		}
	}
	return count, strings.TrimSuffix(shown.String(), "\n")
}

func tailFile(path string, n int) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

// resetExportOut は出力のフォルダを空にする。前の書き出し（bundle.json がある）か空のフォルダだけを消す。
// WhyNot: 何でも消さないのは、--out の打ち間違いで手で置いた物のフォルダを丸ごと消すため。
func resetExportOut(out string) error {
	entries, err := os.ReadDir(out)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("%s を読めない: %v", out, err)
	}
	if len(entries) > 0 && !fileExists(filepath.Join(out, "bundle.json")) {
		return fmt.Errorf("%s に書き出しでない物がある（bundle.json が無い）。\n  次: 空のフォルダか前の書き出しのフォルダを --out に渡す", out)
	}
	if err := os.RemoveAll(out); err != nil {
		return fmt.Errorf("%s を消せない: %v", out, err)
	}
	return os.MkdirAll(filepath.Join(out, "assets"), 0o755)
}

// exportProject は project.json のうち書き出しが読む欄。
type exportProject struct {
	Title        string          `json:"title"`
	DesignWidth  int             `json:"designWidth"`
	DesignHeight int             `json:"designHeight"`
	Web          json.RawMessage `json:"web"`
	Textures     []webTexture    `json:"textures"`
	Sounds       []webSound      `json:"sounds"`
	Fonts        []struct {
		Name string `json:"name"`
	} `json:"fonts"`
}

func (pr exportProject) fontNames() []string {
	var names []string
	for _, f := range pr.Fonts {
		if f.Name != "" {
			names = append(names, f.Name)
		}
	}
	return names
}

func loadExportProject(game string) (exportProject, error) {
	var pr exportProject
	data, err := os.ReadFile(filepath.Join(game, "project.json"))
	if err != nil {
		return pr, fmt.Errorf("project.json を読めない: %v", err)
	}
	if err := json.Unmarshal(data, &pr); err != nil {
		return pr, fmt.Errorf("project.json を読めない: %v\n  次: JSON の形を直す", err)
	}
	return pr, nil
}

type webTexture struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

type webSound struct {
	Name    string `json:"name"`
	Path    string `json:"path"`
	Looping bool   `json:"looping"`
	// 以下は書き出しが wav から読んで束に書く（秒）。Seconds は元の長さ・LoopStart と LoopEnd は smpl のループ（終わりを含まない）。
	Seconds   float64 `json:"seconds,omitempty"`
	LoopStart float64 `json:"loopStart,omitempty"`
	LoopEnd   float64 `json:"loopEnd,omitempty"`
}

// webBundle は bundle.json の形。道は全部ゲームの根から見た `/` 区切り。
type webBundle struct {
	ID            string            `json:"id"`
	Title         string            `json:"title"`
	Files         []string          `json:"files"`
	Images        []string          `json:"images"`
	Sounds        []webSound        `json:"sounds"`
	Design        *webDesign        `json:"design,omitempty"`
	VirtualPad    *webVirtualPad    `json:"virtualPad,omitempty"`
	TouchGestures map[string]string `json:"touchGestures,omitempty"`
	Orientation   string            `json:"orientation,omitempty"`
	// Transcoded は論理の道 → 配る道（WebP・Opus・gzip に替えた物だけ）。頁は配る道で取り、論理の道で素材の表へ入れる。
	Transcoded map[string]string `json:"transcoded,omitempty"`
	// Deferred は「押して始める」の前に取らず、wasm を読んだ後に裏で取る素材（取る順）。files・images・sounds にも載せたまま。
	// WhyNot: files などから抜かない — deferred を知らない古い fge-web.js でも、全部を起動の前に取って動く。
	Deferred []webDeferredEntry `json:"deferred,omitempty"`
	// Splash は頁が「押して始める」の前に描く起動画面の材料（exportweb_splash.go）。
	Splash *webSplash `json:"splash,omitempty"`
	// WasmBrotli は classes.wasm を brotli にした物の道（無ければ頁は classes.wasm を取る）。
	WasmBrotli string `json:"wasmBrotli,omitempty"`
	// Boot は押して始めるまでに取る物の大きさ。頁は進みの棒をこの量の重みで動かす。
	Boot *webStartupBytes `json:"boot,omitempty"`
	// ServiceWorker は頁が sw.js を登録するか（project.json の web.serviceWorker・既定は入れる）。false なら頁は前に登録した物を外す。
	ServiceWorker bool `json:"serviceWorker,omitempty"`
}

// withTouch は頁が起動の前に要る物（design の縦横比・パッド・ジェスチャー・向き）を束に足す。
func (b *webBundle) withTouch(pr exportProject, t webTouch) {
	if pr.DesignWidth > 0 && pr.DesignHeight > 0 {
		b.Design = &webDesign{W: pr.DesignWidth, H: pr.DesignHeight}
	}
	b.VirtualPad = t.VirtualPad
	b.TouchGestures = t.TouchGestures
	if t.Orientation != "any" {
		b.Orientation = t.Orientation
	}
}

func (b webBundle) copyList() []string {
	seen := map[string]bool{}
	var list []string
	add := func(rel string) {
		if !seen[rel] {
			seen[rel] = true
			list = append(list, rel)
		}
	}
	for _, rel := range b.Files {
		add(rel)
	}
	for _, rel := range b.Images {
		add(rel)
	}
	for _, s := range b.Sounds {
		add(s.Path)
	}
	return list
}

// buildWebBundle は project.json と assets/ の下から bundle.json の中身を作る（アトラスは後で足す）。
func buildWebBundle(game, id string, pr exportProject, readsImages bool) (webBundle, error) {
	b := webBundle{ID: id, Title: pr.Title, Files: []string{"project.json"}, Images: []string{}, Sounds: []webSound{}}
	named := map[string]bool{}
	for _, t := range pr.Textures {
		rel, err := checkAssetPath(game, t.Path, "textures[].path")
		if err != nil {
			return b, err
		}
		b.Images = append(b.Images, rel)
		named[rel] = true
		if readsImages && exportWebDecodedImageExts[strings.ToLower(path.Ext(rel))] {
			b.Files = append(b.Files, rel)
		}
	}
	for _, s := range pr.Sounds {
		rel, err := checkAssetPath(game, s.Path, "sounds[].path")
		if err != nil {
			return b, err
		}
		s.Path = rel
		b.Sounds = append(b.Sounds, s)
		named[rel] = true
	}
	root := filepath.Join(game, "assets")
	if dirExists(root) {
		err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			// WhyNot: 点で始まる物（.DS_Store・エディタの控え）を運ばないのは、OS ごとに有る無しが変わり、
			// 同じゲームから違う束ができるため。
			if strings.HasPrefix(d.Name(), ".") {
				if d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			if d.IsDir() {
				return nil
			}
			rel, err := filepath.Rel(game, p)
			if err != nil {
				return err
			}
			rel = filepath.ToSlash(rel)
			ext := strings.ToLower(path.Ext(rel))
			if named[rel] || (exportWebMediaExts[ext] && !(readsImages && exportWebDecodedImageExts[ext])) {
				return nil
			}
			b.Files = append(b.Files, rel)
			return nil
		})
		if err != nil {
			return b, err
		}
	}
	sort.Strings(b.Files)
	return b, nil
}

// checkAssetPath は project.json の道を `/` 区切りの形にそろえ、ゲームの中に実在するかを見る。
func checkAssetPath(game, raw, field string) (string, error) {
	rel := path.Clean(strings.ReplaceAll(raw, "\\", "/"))
	if raw == "" || path.IsAbs(rel) || rel == ".." || strings.HasPrefix(rel, "../") || filepath.IsAbs(raw) {
		return "", fmt.Errorf("project.json の %s がゲームの外か空を指す: %q\n  次: ゲームの根から見た道に直す", field, raw)
	}
	if !fileExists(filepath.Join(game, filepath.FromSlash(rel))) {
		return "", fmt.Errorf("project.json の %s が指す %s が無い。\n  次: 素材を置くか project.json を直す", field, rel)
	}
	return rel, nil
}

func exportAssetPath(out, rel string) string {
	return filepath.Join(out, "assets", filepath.FromSlash(rel))
}

// placeFontAtlases は project.json の fonts ごとに <out>/assets/font-atlas/<name>.fontatlas を置き、files に足す道を返す。
// WhyNot: アトラスの出どころ（--font-atlas-dir か font-bake か）の分岐を呼び手に出さないのは、仮の入口の
// --font-atlas-dir を外す時にここだけ直せば済むようにするため。
func placeFontAtlases(p exportWebPaths, o exportWebOptions, names []string) ([]string, int, error) {
	if len(names) == 0 {
		return nil, 0, nil
	}
	dir := o.FontAtlasDir
	if dir == "" {
		if _, ok := registry["font-bake"]; !ok {
			return nil, 2, errors.New("フォントアトラスの出どころが無い。\n  次: --font-atlas-dir を渡すか、font-bake が入った版の bin/fge で流す")
		}
		dir = filepath.Join(p.Work, "font-atlas")
		if code := runFontBake(p.Game, dir); code != 0 {
			if code != 1 {
				code = 2
			}
			return nil, code, fmt.Errorf("font-bake が止まった（終わりの番号 %d）。\n  次: 上の font-bake の出力を読む", code)
		}
	}
	var files []string
	for _, name := range names {
		src := filepath.Join(dir, name+".fontatlas")
		rel := webFontAtlasRel(name)
		if !fileExists(src) {
			return nil, 1, fmt.Errorf("フォントアトラス %s が無い。\n  次: font-bake で作るか、--font-atlas-dir の中身を確かめる", src)
		}
		if err := copyFile(src, exportAssetPath(p.Out, rel)); err != nil {
			return nil, 1, err
		}
		files = append(files, rel)
	}
	return files, 0, nil
}

// runFontBake は自分の実行ファイルを font-bake 付きで起こす。
// WhyNot: 同じ所の関数として呼ばないのは、font-bake が os.Exit や作業のフォルダを変えても、書き出しの続きに響かないようにするため。
func runFontBake(game, dir string) int {
	exe, err := os.Executable()
	if err != nil {
		ewLogf("自分の実行ファイルが分からない: %v", err)
		return 2
	}
	c := exec.Command(exe, "font-bake", game, dir)
	c.Stdout, c.Stderr = exportWebLog, exportWebLog
	if err := c.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return ee.ExitCode()
		}
		return 2
	}
	return 0
}

// writeWebPage は bundle.json・classes.wasm・js・sw.js・sums.json・index.html・version.txt を出し、版のハッシュを返す。
func writeWebPage(p exportWebPaths, b webBundle, wasm, teavmCore, brotli string) (string, error) {
	if err := writeWebWasm(wasm, p.Out); err != nil {
		return "", err
	}
	if b.WasmBrotli != "" {
		if err := writeWebWasmBrotli(brotli, filepath.Dir(p.WebJS), p.Out); err != nil {
			return "", err
		}
	}
	boot := webStartupBytesOf(p.Out, &b)
	b.Boot = &boot
	bundle, err := marshalWebBundle(b)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(p.Out, "bundle.json"), bundle, 0o644); err != nil {
		return "", err
	}
	if err := copyFile(p.WebJS, filepath.Join(p.Out, "fge-web.js")); err != nil {
		return "", err
	}
	runtime, err := readZipEntry(teavmCore, "org/teavm/backend/wasm/wasm-gc-runtime.js")
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(p.Out, "wasm-gc-runtime.js"), runtime, 0o644); err != nil {
		return "", err
	}
	if err := writeWebServiceWorker(filepath.Dir(p.WebJS), p.Out, b.ID, b.ServiceWorker); err != nil {
		return "", err
	}
	hash, err := writeWebSums(p.Out)
	if err != nil {
		return "", err
	}
	index, err := os.ReadFile(p.IndexHTML)
	if err != nil {
		return "", err
	}
	html, err := stampWebIndex(string(index), hash, webPreloads(b))
	if err != nil {
		return "", fmt.Errorf("%s: %v", p.IndexHTML, err)
	}
	if err := os.WriteFile(filepath.Join(p.Out, "index.html"), []byte(html), 0o644); err != nil {
		return "", err
	}
	return hash, os.WriteFile(filepath.Join(p.Out, "version.txt"), []byte(hash+"\n"), 0o644)
}

// writeWebWasm は wasm を名前の区画の無い classes.wasm と、区画の中身の classes.names に分けて置く。
func writeWebWasm(wasm, out string) error {
	data, err := os.ReadFile(wasm)
	if err != nil {
		return err
	}
	stripped, names, err := splitWasmNames(data)
	if err != nil {
		return fmt.Errorf("%s: %v", wasm, err)
	}
	if err := os.WriteFile(filepath.Join(out, "classes.wasm"), stripped, 0o644); err != nil {
		return err
	}
	if names == nil {
		return nil
	}
	return os.WriteFile(filepath.Join(out, webWasmNamesFile), names, 0o644)
}

// webWasmBrotliFile と webBrotliDecoderFile は、wasm を brotli にした物と、頁がそれを戻す解き手の道。
const (
	webWasmBrotliFile    = "classes.wasm.br"
	webBrotliDecoderFile = "brotli-decode.js"
)

// writeWebWasmBrotli は out/classes.wasm を brotli（最も強い 11）にした classes.wasm.br と、engine_web/js の解き手を置く。
// WhyNot: 置き場の圧縮に任せない — GitHub Pages は gzip しか配らず、wasm は brotli の方が 4 割ほど小さい。
// 頁が自分で解くので、置き場が何で配っても同じ大きさで届く。
func writeWebWasmBrotli(brotli, jsDir, out string) error {
	data, err := exec.Command(brotli, "-q", "11", "-c", filepath.Join(out, "classes.wasm")).Output()
	if err != nil {
		return fmt.Errorf("brotli で wasm を詰められない: %v", err)
	}
	if err := os.WriteFile(filepath.Join(out, webWasmBrotliFile), data, 0o644); err != nil {
		return err
	}
	return copyFile(filepath.Join(jsDir, webBrotliDecoderFile), filepath.Join(out, webBrotliDecoderFile))
}

func marshalWebBundle(b webBundle) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", " ")
	if err := enc.Encode(b); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func cleanupExportWork(p exportWebPaths, keep bool) {
	if keep {
		return
	}
	os.RemoveAll(p.Project)
	os.Remove(filepath.Join(p.Work, "rewritten.jar"))
	os.Remove(filepath.Join(p.Work, "embedded.jar"))
	os.RemoveAll(filepath.Join(p.Work, "wasm"))
}

// writeExportSizes は配る大きさの内訳を 1 行ずつ出す（変換した種類は「前 → 後」）と、変換の知らせ。
// exportDocFiles は files のうち素材の行に数える物。アトラスと、絵の行で数える images の道を除く。
func exportDocFiles(b webBundle, isAtlas map[string]bool) []string {
	isImage := map[string]bool{}
	for _, f := range b.Images {
		isImage[f] = true
	}
	var docs []string
	for _, f := range b.Files {
		if !isAtlas[f] && !isImage[f] {
			docs = append(docs, f)
		}
	}
	return docs
}

func writeExportSizes(out *strings.Builder, dir string, b webBundle, atlases []string, r webTranscodeReport, strip webStripPlan) {
	isAtlas := map[string]bool{}
	for _, a := range atlases {
		isAtlas[a] = true
	}
	docFiles := exportDocFiles(b, isAtlas)
	var docs int64
	for _, f := range docFiles {
		docs += fileSize(exportAssetPath(dir, f))
	}
	page := fileSize(filepath.Join(dir, "index.html")) + fileSize(filepath.Join(dir, "fge-web.js")) +
		fileSize(filepath.Join(dir, "wasm-gc-runtime.js")) + fileSize(filepath.Join(dir, "bundle.json"))
	wasm := fileSize(filepath.Join(dir, "classes.wasm"))
	pair := func(p webSizePair) string {
		if p.Before == p.After {
			return humanBytes(p.After)
		}
		return fmt.Sprintf("%s → %s", humanBytes(p.Before), humanBytes(p.After))
	}
	rows := []struct {
		name, size, note string
	}{
		{"wasm", humanBytes(wasm), "classes.wasm"},
		{"素材", humanBytes(docs), fmt.Sprintf("Doc など %d 本", len(docFiles))},
		{"絵", pair(r.Images), fmt.Sprintf("%d 枚", len(b.Images))},
		{"アトラス", pair(r.Atlases), fmt.Sprintf("%d 本", len(atlases))},
		{"音", pair(r.Sounds), fmt.Sprintf("%d 本", len(b.Sounds))},
		{"頁", humanBytes(page), "index.html・js・bundle.json"},
	}
	w := bufio.NewWriter(out)
	for _, row := range rows {
		fmt.Fprintf(w, "  %-8s %22s  %s\n", row.name, row.size, row.note)
	}
	total := webSizePair{
		Before: wasm + docs + page + r.Images.Before + r.Atlases.Before + r.Sounds.Before,
		After:  wasm + docs + page + r.Images.After + r.Atlases.After + r.Sounds.After,
	}
	fmt.Fprintf(w, "  %-8s %22s  ブラウザが取る量\n", "合計", pair(total))
	if n := len(strip.Stripped); n > 0 {
		fmt.Fprintf(w, "  %-8s %22s  schema・制作の元ファイル %d 本（動く時に読まない。戻すなら web.keep）\n", "外した", humanBytes(strip.StrippedBytes), n)
	}
	for _, line := range r.AutoLossyLines {
		fmt.Fprintf(w, "  %s\n", line)
	}
	start := webStartupSizeOf(dir, &b)
	var waitFor []string
	logoMax := webAfterTapMaxSeconds
	if t := b.Splash; t != nil && t.AfterTap != nil && t.AfterTap.Mode != "none" {
		waitFor, logoMax = t.AfterTap.WaitFor, t.AfterTap.MaxSeconds
	}
	writeStartupEstimate(w, webStartupEstimateOf(dir, &b), start)
	writeTapWaitEstimate(w, webTapWaitOf(dir, &b, waitFor), logoMax)
	if r.FallbackBytes > 0 {
		fmt.Fprintf(w, "  置き場には元の wav（%s）も残す — Opus を解けないブラウザだけが取る\n", humanBytes(r.FallbackBytes))
	}
	for _, n := range r.Notes {
		fmt.Fprintf(w, "  知らせ: %s\n", n)
	}
	if n := len(strip.Noticed); n > 0 {
		fmt.Fprintf(w, "  知らせ: .md・.txt %d 本（%s）を束に入れた — ゲームが読まないなら web.omit へ\n", n, humanBytes(strip.NoticedBytes))
	}
	// WhyNot: 運ばない物を言わずに終えない — assets/ の外の Doc や readBytes で読む素材は束に入らず、ブラウザで初めて「無い」になる。
	fmt.Fprintln(w, "  束に入れたのは project.json と assets/ の下だけ（assets/ の外を読むゲームはブラウザで読めない）")
	w.Flush()
}

// writeStartupEstimate は起動まで（遊べるまで）の回線の量と 1.6 Mbps での秒数、後回しの最後が届く時刻を書く。目標を超えても止めない。
func writeStartupEstimate(w io.Writer, s webStartupEstimate, start webStartupSize) {
	wire := s.Boot.WasmWire + s.Boot.AssetsWire + s.PageWire
	fmt.Fprintf(w, "  起動まで（タッチして開始まで）%d 本・回線 %s（wasm %s・素材 %s・頁 %s）→ 4G（1.6 Mbps）で約 %.1f 秒（前置き %.1f 秒を含む）\n",
		start.StartCount, humanBytes(wire), humanBytes(s.Boot.WasmWire), humanBytes(s.Boot.AssetsWire), humanBytes(s.PageWire),
		s.Seconds, webStartupPreludeSeconds)
	if n := len(s.Deferred); n > 0 {
		fmt.Fprintf(w, "  後回し %d 本・%s → 最後の %s が届くのは約 %.0f 秒目（1 本ずつの時刻は書き出しのログ）\n",
			start.DeferredCount, humanBytes(start.DeferredBytes), s.Deferred[n-1].Path, s.Deferred[n-1].Seconds)
		for _, a := range s.Deferred {
			ewLogf("  後回し %6.1f 秒目  %s", a.Seconds, a.Path)
		}
	}
	if s.Seconds > webStartupTargetSeconds {
		fmt.Fprintf(w, "  知らせ: 起動までが 4G で %.0f 秒を超える — タイトルより後で使う素材は web.deferred へ回せる（大物から: wasm %s・素材 %s）\n",
			webStartupTargetSeconds, humanBytes(s.Boot.WasmWire), humanBytes(s.Boot.AssetsWire))
	}
}

// writeTapWaitEstimate は「開いてすぐ押した時に、押してから最初の場面が動くまで」の 4G の見積もりを書く（人の要件の 2 本目の数字）。
// logoMax は押した後のロゴの上限の秒（ゲームの web.splash.maxSeconds）。
func writeTapWaitEstimate(w io.Writer, t webTapWait, logoMax float64) {
	switch {
	case t.Count == 0 && len(t.Group) > 0:
		fmt.Fprintf(w, "  押してから動くまで（開いてすぐ押した時・4G）: 0 秒（group %s に後回しの物が無い）\n", strings.Join(t.Group, "・"))
	case t.Count == 0:
		fmt.Fprintln(w, "  押してから動くまで（開いてすぐ押した時・4G）: 0 秒（届く前に使うと engine が待つ後回しの物が無い）")
	case len(t.Group) > 0:
		fmt.Fprintf(w, "  押してから動くまで（開いてすぐ押した時・4G）: 約 %.1f 秒（押した後のロゴが待つ group %s の %d 本がそろうまで）\n",
			t.Seconds, strings.Join(t.Group, "・"), t.Count)
	default:
		fmt.Fprintf(w, "  押してから動くまで（開いてすぐ押した時・4G）: 約 %.1f〜%.1f 秒（最初に届く待つ物 %s から、待つ物 %d 本の最後まで。最初の場面が使う物で決まる）\n",
			t.Seconds, t.Until, t.FirstPath, t.Count)
	}
	if t.Count > 0 && t.Seconds > logoMax {
		fmt.Fprintf(w, "  知らせ: 押してから動くまでが 4G で押した後のロゴの上限 %.1f 秒を超える — すぐ要る物を web.deferred の頭へ並べ替えるか、後回しから外す（ロゴと待ちの合計が後回しにしない時の起動の秒を超えるなら後回しにしない）\n",
			logoMax)
	}
}

func humanBytes(n int64) string {
	switch {
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(n)/(1<<10))
	}
	return fmt.Sprintf("%d B", n)
}

func fileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}

var glJarDepRe = regexp.MustCompile(`^\s*"(fge-gl-[^"]+\.jar)"\s*=`)

// glJarNameOf は、組む flix.toml の [jar-dependencies] が宣言する GL の層の jar の名前を返す。
// WhyNot: 名前を版から組み立てない — jar の置き場は render_gl/java の中身のハッシュで名付け、版とは別に変わる。
// 宣言と違う名前で lib/external に置くと、Flix が置き場のリリースへ取りに行く。
func glJarNameOf(toml, version string) string {
	b, err := os.ReadFile(toml)
	if err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			if m := glJarDepRe.FindStringSubmatch(line); m != nil {
				return m[1]
			}
		}
	}
	return "fge-gl-" + version + ".jar"
}

func dirExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

// teavmHeap は TeaVM の JVM のメモリの上限（-Xmx の値）。既定 6g、FLIX_GE_TEAVM_XMX で替える（メモリの小さい機械向け）。
func teavmHeap() string {
	if v := strings.TrimSpace(os.Getenv("FLIX_GE_TEAVM_XMX")); v != "" {
		return v
	}
	return "6g"
}
