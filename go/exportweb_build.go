package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/mvncache"
)

// exportWebCopyExcludes はゲームの根の直下で写さない物。
// WhyNot: lib を写さないのは、デスクトップの engine の fpkg が入っていて engine_full_web と取り違えるため。
var exportWebCopyExcludes = map[string]bool{
	"lib": true, "build": true, "artifact": true, "debug": true, "gallery": true,
	"saves": true, "reference": true, ".git": true, "packages.lock": true,
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

// runLogged は dir で cmd を流し、出力を log へ書く（echo なら画面にも）。終わりの番号を返す。
func runLogged(dir, log string, echo bool, name string, args ...string) int {
	return runLoggedWith(dir, log, echo, nil, name, args...)
}

// runLoggedWith は runLogged の、子の環境変数を env にする版（nil なら今のプロセスの物）。
func runLoggedWith(dir, log string, echo bool, env []string, name string, args ...string) int {
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
	c.Env = env
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

// teavmHeap は TeaVM の JVM のメモリの上限（-Xmx の値）。既定 6g、FLIX_GE_TEAVM_XMX で替える（メモリの小さい機械向け）。
func teavmHeap() string {
	if v := strings.TrimSpace(os.Getenv("FLIX_GE_TEAVM_XMX")); v != "" {
		return v
	}
	return "6g"
}

func cleanupExportWork(p exportWebPaths, keep bool) {
	if keep {
		return
	}
	os.RemoveAll(p.Project)
	os.Remove(filepath.Join(p.Work, "rewritten.jar"))
	os.Remove(filepath.Join(p.Work, "embedded.jar"))
	os.Remove(filepath.Join(p.Work, "shaders.jar"))
	os.RemoveAll(filepath.Join(p.Work, "wasm"))
}

// wasmBuild は組んだ wasm の道と、頁の wasm-gc-runtime.js を取り出す TeaVM の core の jar。
type wasmBuild struct {
	Wasm, TeavmCore string
}

// buildWasm はゲームを fatjar に組み、バイトコードの付け替え・位置の相対化・素材の埋め込みを経て TeaVM で wasm にする。
func buildWasm(o exportWebOptions, c exportConfig) (wasmBuild, *exportFailure) {
	p, java := c.Paths, c.Java
	fatLog := filepath.Join(p.Work, "fatjar.log")
	ewLogf("① flix build-fatjar（ログ %s）", fatLog)
	if runLogged(p.Project, fatLog, false, java, "-Xss64m", "-jar", p.FlixJar, "build-fatjar", "--entrypoint", "WebMain.main") != 0 {
		return wasmBuild{}, exportFailf(1, "%s\nfge export-web: flix build-fatjar が失敗した（ログ %s）。\n  次: 上の誤りを直すか、--check で型検査だけ流す\n",
			tailFile(fatLog, 40), fatLog)
	}
	fatjar, err := findFatJar(filepath.Join(p.Project, "artifact"))
	if err != nil {
		return wasmBuild{}, exportFail(1, err)
	}

	jars, err := teavmJars(exportWebLog)
	if err != nil {
		return wasmBuild{}, exportFail(2, err)
	}
	asm := findTeavmJar(jars, "teavm-relocated-libs-asm")
	core := findTeavmJar(jars, "teavm-core")
	if asm == "" || core == "" {
		return wasmBuild{}, exportFailf(2, "fge export-web: TeaVM の jar の中に teavm-relocated-libs-asm か teavm-core が無い。\n  次: FLIX_GE_TEAVM_DIR の中身を確かめるか、外して Maven から取らせる\n")
	}

	rewritten := filepath.Join(p.Work, "rewritten.jar")
	rewriteLog := filepath.Join(p.Work, "rewrite.log")
	ewLogf("② バイトコードの付け替え")
	if code := runRewrite(java, asm, p.WebToolsJar, fatjar, rewritten, rewriteLog); code != 0 {
		return wasmBuild{}, exportFailf(1, "%s\nfge export-web: 付け替え（fge.teavmfix.Rewrite）が失敗した（ログ %s）。\n  次: engine の根で make sync-engine-full-web を流して fge-web-tools を作り直す\n",
			tailFile(rewriteLog, 20), rewriteLog)
	}

	ewLogf("②' ゲームの .flix の位置を作業フォルダからの相対（game/...）へ")
	leakFinder := newWebLeakFinder(os.Getenv("HOME"), os.Getenv("USERPROFILE"), p.Work, p.Game)
	relativized := filepath.Join(p.Work, "relativized.jar")
	paths, err := rewriteJarSourcePaths(rewritten, relativized, leakFinder)
	if err != nil {
		return wasmBuild{}, exportFailf(1, "fge export-web: 位置の置き換えが失敗した: %v\n", err)
	}
	ewLogf("  置き換えた位置 %d", paths.Replaced)
	if len(paths.Leaks) > 0 {
		return wasmBuild{}, exportFailf(1, "fge export-web: %s\n", webLeakReport(map[string][]string{"jar": paths.Leaks}, o.ShowLeaks, false))
	}
	rewritten = relativized

	if embedded := c.EmbedPlan.Embedded; len(embedded) > 0 {
		seed, err := embedSeedOf(p.Game, embedded)
		if err != nil {
			return wasmBuild{}, exportFail(1, err)
		}
		embeddedJar := filepath.Join(p.Work, "embedded.jar")
		embedLog := filepath.Join(p.Work, "embed.log")
		ewLogf("②'' 素材を符号にして wasm へ埋め込む（web.embed %d 本）", len(embedded))
		if code := runEmbed(java, asm, p.WebToolsJar, p.WebJar, p.Game, rewritten, embeddedJar, embedLog, embedded, seed); code != 0 {
			return wasmBuild{}, exportFailf(1, "%s\nfge export-web: 埋め込み（fge.teavmfix.Embed）が失敗した（ログ %s）。\n  次: 上の行を読む（EmbeddedData が無いと言うなら engine の根で make sync-engine-full-web を流して fge-web と fge-web-tools を作り直す）\n",
				tailFile(embedLog, 20), embedLog)
		}
		rewritten = embeddedJar
	}

	if c.Shaders.Bake {
		shadersJar := filepath.Join(p.Work, "shaders.jar")
		ewLogf("②''' 3D のシェーダーの字の表を作って wasm へ埋め込む（記録 %s）", c.Shaders.Variants)
		if f := embedShaderLibrary(c, asm, rewritten, shadersJar); f != nil {
			return wasmBuild{}, f
		}
		rewritten = shadersJar
	}

	wasmDir := filepath.Join(p.Work, "wasm")
	teavmLog := filepath.Join(p.Work, "teavm.log")
	ewLogf("③ TeaVM（wasm-gc・ログ %s）", teavmLog)
	if err := os.RemoveAll(wasmDir); err != nil {
		return wasmBuild{}, exportFailf(2, "fge export-web: %s を消せない: %v\n", wasmDir, err)
	}
	if err := os.MkdirAll(wasmDir, 0o755); err != nil {
		return wasmBuild{}, exportFailf(2, "fge export-web: %s を作れない: %v\n", wasmDir, err)
	}
	cp := strings.Join(append(append([]string{p.WebToolsJar}, jars...), rewritten), string(os.PathListSeparator))
	teavmCode := runLogged(p.Work, teavmLog, false, java, "-Xmx"+teavmHeap(), "-cp", cp, "fge.teavmfix.BuildWasm",
		"Main", wasmDir, "classes.wasm")
	logText, _ := os.ReadFile(teavmLog)
	if errs, shown := teavmErrors(string(logText), 5); errs > 0 {
		return wasmBuild{}, exportFailf(1, "%s\nfge export-web: TeaVM の ERROR が %d 件（ログ %s）。\n  次: 上の行のクラス・メソッドを engine_web の shim か付け替えで手当てする\n",
			shown, errs, teavmLog)
	}
	wasm := filepath.Join(wasmDir, "classes.wasm")
	if teavmCode != 0 || !fileExists(wasm) {
		return wasmBuild{}, exportFailf(1, "%s\nfge export-web: TeaVM が classes.wasm を出さなかった（終わりの番号 %d・ログ %s）。\n  次: ログの最後を読む（メモリ不足なら FLIX_GE_TEAVM_XMX で TeaVM の上限を上げる・今は "+teavmHeap()+"。fge.teavmfix.BuildWasm が無いと言うなら engine の根で make sync-engine-full-web を流して fge-web-tools を作り直す）\n",
			tailFile(teavmLog, 20), teavmCode, teavmLog)
	}

	wasmBytes, err := os.ReadFile(wasm)
	if err != nil {
		return wasmBuild{}, exportFail(1, err)
	}
	// WhyNot: 書き出し先へ置いてから探さない — 止めた後も置いた物が残り、置き場へ写す手順だとそのまま配られる。
	leaks, err := findWasmLeaks(wasmBytes, leakFinder)
	if err != nil {
		return wasmBuild{}, exportFailf(1, "fge export-web: wasm を読めない: %v\n", err)
	}
	if leaks.total() > 0 {
		return wasmBuild{}, exportFailf(1, "fge export-web: %s\n", webLeakReport(map[string][]string{"wasm": leaks.Wasm, "names": leaks.Names}, o.ShowLeaks, true))
	}
	return wasmBuild{Wasm: wasm, TeavmCore: core}, nil
}

// runExportCheck は --check の型検査だけを流す。
func runExportCheck(out *strings.Builder, o exportWebOptions, c exportConfig) (int, *exportFailure) {
	p := c.Paths
	log := filepath.Join(p.Work, "check.log")
	if runLogged(p.Project, log, true, c.Java, "-Xss64m", "-jar", p.FlixJar, "check") != 0 {
		return 0, exportFailf(1, "fge export-web --check: 型検査が通らない（ログ %s）。\n  次: web/WebMain.flix か engine_web を直す\n", log)
	}
	cleanupExportWork(p, o.KeepWork)
	fmt.Fprintln(out, "export-web --check: 型検査が通った")
	return 0, nil
}
