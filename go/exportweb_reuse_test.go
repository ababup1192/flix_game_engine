package main

import (
	"os"
	"path/filepath"
	"testing"
)

// reuseFixture はゲーム 1 つと、前の書き出しの書き出し先と指紋を作る。
func reuseFixture(t *testing.T) (exportWebPaths, string) {
	t.Helper()
	root := t.TempDir()
	game := filepath.Join(root, "game")
	for rel, body := range map[string]string{
		"src/Main.flix":           "def main(): Unit = ()",
		"assets/talk/intro.yarn":  "title: intro",
		"project.json":            "{}",
		"debug/video/a/f0001.png": "frame",
	} {
		writeReuseFile(t, filepath.Join(game, rel), body)
	}
	p := exportWebPaths{Game: game, Work: filepath.Join(root, "work"), Out: filepath.Join(root, "out"), Version: "0.1.0"}
	writeReuseFile(t, filepath.Join(p.Out, "index.html"), "<html>")
	writeReuseFile(t, filepath.Join(p.Out, "version.txt"), "abc123\n")
	fp := mustFingerprint(t, p)
	writeReuseFile(t, exportReuseStamp(p), exportReuseLine(fp, p.Out, "abc123"))
	return p, fp
}

func writeReuseFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func mustFingerprint(t *testing.T, p exportWebPaths) string {
	t.Helper()
	fp, err := exportInputsFingerprint(p, exportWebOptions{}, "game", webEncoders{})
	if err != nil {
		t.Fatal(err)
	}
	return fp
}

func TestReuseExportWhenInputsSame(t *testing.T) {
	p, fp := reuseFixture(t)
	if !canReuseExport(p, fp) {
		t.Fatal("同じ入力なのに使い回さない")
	}
}

func TestReuseExportRebuildsWhenAssetChanges(t *testing.T) {
	p, _ := reuseFixture(t)
	writeReuseFile(t, filepath.Join(p.Game, "assets/talk/intro.yarn"), "title: intro2")
	if canReuseExport(p, mustFingerprint(t, p)) {
		t.Fatal("素材を変えたのに使い回した")
	}
}

func TestReuseExportIgnoresDebugFolder(t *testing.T) {
	p, _ := reuseFixture(t)
	writeReuseFile(t, filepath.Join(p.Game, "debug/video/a/f0002.png"), "frame2")
	if !canReuseExport(p, mustFingerprint(t, p)) {
		t.Fatal("書き出しが写さない debug/ の変化で組み直した")
	}
}

func TestReuseExportRebuildsWhenOutReplaced(t *testing.T) {
	p, fp := reuseFixture(t)
	writeReuseFile(t, filepath.Join(p.Out, "version.txt"), "other\n")
	if canReuseExport(p, fp) {
		t.Fatal("書き出し先が別の書き出しに替わったのに使い回した")
	}
}

func TestReuseExportRebuildsWhenEngineFileChanges(t *testing.T) {
	// 書き出しの中身を変える engine の物は、どれを変えても組み直す。
	cases := map[string]func(p *exportWebPaths) string{
		"engine_full_web の fpkg": func(p *exportWebPaths) string { return p.FullWebFpkg },
		"engine_full_web の toml": func(p *exportWebPaths) string { return p.FullWebToml },
		"gl の jar":               func(p *exportWebPaths) string { return p.GlJar },
		"web の jar":              func(p *exportWebPaths) string { return p.WebJar },
		"web の道具の jar":           func(p *exportWebPaths) string { return p.WebToolsJar },
		"fge-web.js":             func(p *exportWebPaths) string { return p.WebJS },
		"頁の雛形":                   func(p *exportWebPaths) string { return p.IndexHTML },
		"flix.jar":               func(p *exportWebPaths) string { return p.FlixJar },
		"起動画面の字":                 func(p *exportWebPaths) string { return bootFontDataPath(p.Engine) },
	}
	for name, pathOf := range cases {
		t.Run(name, func(t *testing.T) {
			p := engineFixture(t)
			fp := mustFingerprint(t, p)
			writeReuseFile(t, pathOf(&p), "changed")
			if mustFingerprint(t, p) == fp {
				t.Fatalf("%s を変えても指紋が同じ", name)
			}
		})
	}
}

// engineFixture は engine の物を全部置いたゲームの道の一式。
func engineFixture(t *testing.T) exportWebPaths {
	t.Helper()
	p, _ := reuseFixture(t)
	eng := t.TempDir()
	p.Engine = eng
	p.FullWebFpkg, p.FullWebToml = filepath.Join(eng, "package.fpkg"), filepath.Join(eng, "flix.toml")
	p.GlJar, p.WebJar, p.WebToolsJar = filepath.Join(eng, "gl.jar"), filepath.Join(eng, "web.jar"), filepath.Join(eng, "web-tools.jar")
	p.WebJS, p.IndexHTML, p.FlixJar = filepath.Join(eng, "fge-web.js"), filepath.Join(eng, "index.html"), filepath.Join(eng, "flix.jar")
	for _, f := range []string{p.FullWebFpkg, p.FullWebToml, p.GlJar, p.WebJar, p.WebToolsJar, p.WebJS, p.IndexHTML, p.FlixJar, bootFontDataPath(eng)} {
		writeReuseFile(t, f, "v1")
	}
	return p
}

func TestReuseExportRebuildsWhenBrowserCheckTurnsOn(t *testing.T) {
	p, _ := reuseFixture(t)
	skipped, err := exportInputsFingerprint(p, exportWebOptions{NoBrowserCheck: true}, "game", webEncoders{})
	if err != nil {
		t.Fatal(err)
	}
	if skipped == mustFingerprint(t, p) {
		t.Fatal("確かめずに組んだ書き出しを、確かめる呼び出しで使い回す")
	}
}
