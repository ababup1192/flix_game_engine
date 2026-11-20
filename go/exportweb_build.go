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
	os.RemoveAll(filepath.Join(p.Work, "wasm"))
}
