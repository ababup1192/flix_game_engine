package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

const exportWebUsage = `使い方: fge export-web <ゲームのフォルダ> [--out <dir>] [--check] [--id <名前>] [--font-atlas-dir <dir>]
                       [--work <dir>] [--engine <dir>] [--keep-work]
  ゲームをブラウザ版（TeaVM の WASM GC）へ書き出す。出力の既定は <ゲーム>/build/web。
  --check           作業フォルダで flix check だけ流す（web/WebMain.flix の型検査）
  --id              bundle.json の id（既定はゲームのフォルダの名前）
  --font-atlas-dir  <dir>/<フォントの名前>.fontatlas を使う（無ければ font-bake で作る）
  --work            作業フォルダ（既定 <ゲーム>/build/web-export）。中の project/ にゲームを写して組む
  --engine          engine の根（既定は bin/fge-go の置き場から引く）
  --keep-work       終わった後も作業フォルダの project/ を残す
  環境変数: FLIX_GE_TEAVM_DIR（TeaVM の jar のフォルダ。無ければ Maven から取る）・JAVA・FLIX_JAR
  終わりの番号: 0 書き出せた / 1 組み立てか TeaVM か素材で失敗 / 2 呼び方の誤りか下ごしらえが無い`

func init() {
	register("export-web", "ゲームをブラウザ版（TeaVM の WASM GC）へ書き出す。export-web --help", cmdExportWeb)
}

type exportWebOptions struct {
	Game, Out, Work, Engine, ID, FontAtlasDir string
	Check, KeepWork                           bool
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

func cmdExportWeb(out, errOut *strings.Builder, rest []string, _ bool) int {
	opts, err := parseExportWebArgs(rest)
	if err != nil {
		if errors.Is(err, errExportWebHelp) {
			fmt.Fprintln(out, exportWebUsage)
			return 0
		}
		fmt.Fprintf(errOut, "fge export-web: %v\n%s\n", err, exportWebUsage)
		return 2
	}
	return runExportWeb(out, errOut, opts)
}

var errExportWebHelp = errors.New("help")

func parseExportWebArgs(args []string) (exportWebOptions, error) {
	var o exportWebOptions
	value := map[string]*string{
		"--out": &o.Out, "--work": &o.Work, "--engine": &o.Engine, "--id": &o.ID, "--font-atlas-dir": &o.FontAtlasDir,
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--help" || a == "-h" {
			return o, errExportWebHelp
		}
		if a == "--check" {
			o.Check = true
			continue
		}
		if a == "--keep-work" {
			o.KeepWork = true
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
	return o, nil
}

// exportWebLog は長い手順の途中の様子。out（最後にまとめて出る）ではなく、その場で stderr へ出す。
var exportWebLog io.Writer = os.Stderr

func ewLogf(format string, a ...any) { fmt.Fprintf(exportWebLog, "[export-web] "+format+"\n", a...) }

// exportWebPaths は 1 回の書き出しで使う道の一式。
type exportWebPaths struct {
	Game, Engine, Version, Work, Project, Out                                       string
	FullWebFpkg, FullWebToml, GlJar, WebJar, WebToolsJar, WebJS, IndexHTML, FlixJar string
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

	ewLogf("① ゲームを %s へ写す（engine_full_web %s）", p.Project, p.Version)
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
	teavmCode := runLogged(p.Work, teavmLog, false, java, "-Xmx"+teavmHeap(), "-cp", cp, "org.teavm.cli.TeaVMRunner",
		"-t", "wasm-gc", "-O", "2", "-d", wasmDir, "-f", "classes.wasm", "Main")
	logText, _ := os.ReadFile(teavmLog)
	if errs, shown := teavmErrors(string(logText), 5); errs > 0 {
		fmt.Fprintf(errOut, "%s\nfge export-web: TeaVM の ERROR が %d 件（ログ %s）。\n  次: 上の行のクラス・メソッドを engine_web の shim か付け替えで手当てする\n",
			shown, errs, teavmLog)
		return 1
	}
	wasm := filepath.Join(wasmDir, "classes.wasm")
	if teavmCode != 0 || !fileExists(wasm) {
		fmt.Fprintf(errOut, "%s\nfge export-web: TeaVM が classes.wasm を出さなかった（終わりの番号 %d・ログ %s）。\n  次: ログの最後を読む（メモリ不足なら FLIX_GE_TEAVM_XMX で TeaVM の上限を上げる・今は "+teavmHeap()+"）\n",
			tailFile(teavmLog, 20), teavmCode, teavmLog)
		return 1
	}

	ewLogf("④ アセットの束 → %s", p.Out)
	if err := resetExportOut(p.Out); err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 2
	}
	id := o.ID
	if id == "" {
		id = filepath.Base(p.Game)
	}
	b, err := buildWebBundle(p.Game, id, proj)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	b.withTouch(proj, touch)
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

	ewLogf("⑥ 頁")
	hash, err := writeWebPage(p, b, wasm, core)
	if err != nil {
		fmt.Fprintf(errOut, "fge export-web: %v\n", err)
		return 1
	}
	cleanupExportWork(p, o.KeepWork)

	fmt.Fprintf(out, "export-web: %s（版 %s）\n", p.Out, hash)
	writeExportSizes(out, p.Out, b, atlases)
	return 0
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
	p.FullWebFpkg = filepath.Join(p.Engine, "build", "engine_full_web", "artifact", "package.fpkg")
	p.FullWebToml = filepath.Join(p.Engine, "build", "engine_full_web", "flix.toml")
	p.GlJar = filepath.Join(p.Engine, "build", "gl-jar", "fge-gl-"+v+".jar")
	p.WebJar = filepath.Join(p.Engine, "build", "web-jar", "fge-web-"+v+".jar")
	p.WebToolsJar = filepath.Join(p.Engine, "build", "web-jar", "fge-web-tools-"+v+".jar")
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

// exportWebJava は java の呼び方（JAVA → PATH の動く java → engine の devbox の jdk）。
// WhyNot: PATH の java だけにしないのは、macOS の /usr/bin/java が jdk の無い入口で、起こすと止まるため。
func exportWebJava(engine string) string {
	if j := os.Getenv("JAVA"); j != "" {
		return j
	}
	if exec.Command("java", "-version").Run() == nil {
		return "java"
	}
	name := "java"
	if os.PathSeparator == '\\' {
		name = "java.exe"
	}
	if devbox := filepath.Join(engine, ".devbox", "nix", "profile", "default", "bin", name); fileExists(devbox) {
		return devbox
	}
	return "java"
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
	Textures []struct {
		Path string `json:"path"`
	} `json:"textures"`
	Sounds []webSound `json:"sounds"`
	Fonts  []struct {
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

type webSound struct {
	Name    string `json:"name"`
	Path    string `json:"path"`
	Looping bool   `json:"looping"`
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
	list := append([]string{}, b.Files...)
	list = append(list, b.Images...)
	for _, s := range b.Sounds {
		list = append(list, s.Path)
	}
	return list
}

// buildWebBundle は project.json と assets/ の下から bundle.json の中身を作る（アトラスは後で足す）。
func buildWebBundle(game, id string, pr exportProject) (webBundle, error) {
	b := webBundle{ID: id, Title: pr.Title, Files: []string{"project.json"}, Images: []string{}, Sounds: []webSound{}}
	named := map[string]bool{}
	for _, t := range pr.Textures {
		rel, err := checkAssetPath(game, t.Path, "textures[].path")
		if err != nil {
			return b, err
		}
		b.Images = append(b.Images, rel)
		named[rel] = true
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
			if named[rel] || exportWebMediaExts[strings.ToLower(path.Ext(rel))] {
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
		rel := "font-atlas/" + name + ".fontatlas"
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

var webScriptRe = regexp.MustCompile(`(<script\s+src=")(fge-web\.js|wasm-gc-runtime\.js)(")`)

// writeWebPage は bundle.json・classes.wasm・js・index.html・version.txt を出し、版のハッシュを返す。
func writeWebPage(p exportWebPaths, b webBundle, wasm, teavmCore string) (string, error) {
	bundle, err := marshalWebBundle(b)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(p.Out, "bundle.json"), bundle, 0o644); err != nil {
		return "", err
	}
	if err := copyFile(wasm, filepath.Join(p.Out, "classes.wasm")); err != nil {
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
	hash, err := webVersionHash(p.Out)
	if err != nil {
		return "", err
	}
	index, err := os.ReadFile(p.IndexHTML)
	if err != nil {
		return "", err
	}
	html, err := stampWebIndex(string(index), hash)
	if err != nil {
		return "", fmt.Errorf("%s: %v", p.IndexHTML, err)
	}
	if err := os.WriteFile(filepath.Join(p.Out, "index.html"), []byte(html), 0o644); err != nil {
		return "", err
	}
	return hash, os.WriteFile(filepath.Join(p.Out, "version.txt"), []byte(hash+"\n"), 0o644)
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

// webVersionHash は出力の木（index.html と version.txt を除く全部）を道の順に名前と中身ごと読んで作る短いハッシュ
// （頁の js の参照に付けてキャッシュを外す）。
// WhyNot: wasm と bundle.json だけから作らない — Doc や fge-web.js だけを直した書き出しで版が変わらず、置き先のキャッシュが古い物を配る。
func webVersionHash(out string) (string, error) {
	var rels []string
	err := filepath.WalkDir(out, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, err := filepath.Rel(out, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if rel != "index.html" && rel != "version.txt" {
			rels = append(rels, rel)
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	sort.Strings(rels)
	h := sha256.New()
	for _, rel := range rels {
		data, err := os.ReadFile(filepath.Join(out, filepath.FromSlash(rel)))
		if err != nil {
			return "", err
		}
		fmt.Fprintf(h, "%s\x00%d\x00", rel, len(data))
		h.Write(data)
	}
	return hex.EncodeToString(h.Sum(nil))[:12], nil
}

// stampWebIndex は index.html の fge-web.js と wasm-gc-runtime.js の <script src> に ?v=<hash> を付ける。
func stampWebIndex(html, hash string) (string, error) {
	seen := map[string]bool{}
	stamped := webScriptRe.ReplaceAllStringFunc(html, func(m string) string {
		sub := webScriptRe.FindStringSubmatch(m)
		seen[sub[2]] = true
		return sub[1] + sub[2] + "?v=" + hash + sub[3]
	})
	for _, name := range []string{"wasm-gc-runtime.js", "fge-web.js"} {
		if !seen[name] {
			return "", fmt.Errorf(`<script src="%s"> が無い。次: index.html の script の行を確かめる`, name)
		}
	}
	return stamped, nil
}

func cleanupExportWork(p exportWebPaths, keep bool) {
	if keep {
		return
	}
	os.RemoveAll(p.Project)
	os.Remove(filepath.Join(p.Work, "rewritten.jar"))
	os.RemoveAll(filepath.Join(p.Work, "wasm"))
}

// writeExportSizes は出力の大きさの内訳を 1 行ずつ出す。
func writeExportSizes(out *strings.Builder, dir string, b webBundle, atlases []string) {
	size := func(p string) int64 {
		info, err := os.Stat(p)
		if err != nil {
			return 0
		}
		return info.Size()
	}
	isAtlas := map[string]bool{}
	var atlasSum int64
	for _, a := range atlases {
		isAtlas[a] = true
		atlasSum += size(exportAssetPath(dir, a))
	}
	var docs, images, sounds int64
	for _, f := range b.Files {
		if !isAtlas[f] {
			docs += size(exportAssetPath(dir, f))
		}
	}
	for _, f := range b.Images {
		images += size(exportAssetPath(dir, f))
	}
	for _, s := range b.Sounds {
		sounds += size(exportAssetPath(dir, s.Path))
	}
	page := size(filepath.Join(dir, "index.html")) + size(filepath.Join(dir, "fge-web.js")) +
		size(filepath.Join(dir, "wasm-gc-runtime.js")) + size(filepath.Join(dir, "bundle.json"))
	wasm := size(filepath.Join(dir, "classes.wasm"))
	rows := []struct {
		name string
		n    int64
		note string
	}{
		{"wasm", wasm, "classes.wasm"},
		{"素材", docs, fmt.Sprintf("Doc など %d 本", len(b.Files)-len(atlases))},
		{"絵", images, fmt.Sprintf("%d 枚", len(b.Images))},
		{"アトラス", atlasSum, fmt.Sprintf("%d 本", len(atlases))},
		{"音", sounds, fmt.Sprintf("%d 本", len(b.Sounds))},
		{"頁", page, "index.html・js・bundle.json"},
	}
	w := bufio.NewWriter(out)
	for _, r := range rows {
		fmt.Fprintf(w, "  %-8s %10s  %s\n", r.name, humanBytes(r.n), r.note)
	}
	fmt.Fprintf(w, "  %-8s %10s\n", "合計", humanBytes(wasm+docs+images+atlasSum+sounds+page))
	// WhyNot: 運ばない物を言わずに終えない — assets/ の外の Doc や readBytes で読む素材は束に入らず、ブラウザで初めて「無い」になる。
	fmt.Fprintln(w, "  束に入れたのは project.json と assets/ の下だけ（assets/ の外を読むゲームはブラウザで読めない）")
	w.Flush()
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
