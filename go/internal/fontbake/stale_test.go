package fontbake

import (
	"os"
	"path/filepath"
	"testing"
)

// staleGame は project.json と 1 本のフォントを持つゲームの根を作る。
func staleGame(t *testing.T, fontSize string) string {
	t.Helper()
	root := t.TempDir()
	writeFile(t, root, "project.json", `{"title": "t", "glyphs": "auto", "fonts": [{"name": "default", "path": "assets/f.ttf", "fontSize": `+fontSize+`}]}`)
	writeFile(t, root, "assets/f.ttf", "font-bytes")
	return root
}

func inputsOf(t *testing.T, root, charset string) string {
	t.Helper()
	return inputsWith(t, root, "jar", "collected", charset)
}

func inputsWith(t *testing.T, root, jar, glyphs, charset string) string {
	t.Helper()
	k, err := InputsKey(root, jar, glyphs, charset)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func TestInputsKeyIsStableForSameInputs(t *testing.T) {
	root := staleGame(t, "48.0")
	if inputsOf(t, root, "あ") != inputsOf(t, root, "あ") {
		t.Error("同じ材料で指紋が変わった")
	}
}

func TestInputsKeyChangesWhenCharsetGrows(t *testing.T) {
	root := staleGame(t, "48.0")
	if inputsOf(t, root, "あ") == inputsOf(t, root, "あい") {
		t.Error("字が増えたのに指紋が同じ")
	}
}

func TestInputsKeyChangesWhenFontFileChanges(t *testing.T) {
	root := staleGame(t, "48.0")
	before := inputsOf(t, root, "あ")
	writeFile(t, root, "assets/f.ttf", "other-font")
	if before == inputsOf(t, root, "あ") {
		t.Error("フォントの中身が変わったのに指紋が同じ")
	}
}

func TestInputsKeyChangesWhenFontSizeChanges(t *testing.T) {
	if inputsOf(t, staleGame(t, "48.0"), "あ") == inputsOf(t, staleGame(t, "32.0"), "あ") {
		t.Error("fontSize が変わったのに指紋が同じ")
	}
}

func TestInputsKeyChangesWhenJarChanges(t *testing.T) {
	root := staleGame(t, "48.0")
	if inputsWith(t, root, "jar-a", "collected", "あ") == inputsWith(t, root, "jar-b", "collected", "あ") {
		t.Error("engine（jar の指紋）が変わったのに指紋が同じ")
	}
}

func TestInputsKeyChangesWhenGlyphsModeChanges(t *testing.T) {
	root := staleGame(t, "48.0")
	if inputsWith(t, root, "jar", "collected", "あ") == inputsWith(t, root, "jar", "all", "あ") {
		t.Error("--glyphs が変わったのに指紋が同じ")
	}
}

func TestInputsKeyIgnoresOtherProjectKeys(t *testing.T) {
	root := staleGame(t, "48.0")
	before := inputsOf(t, root, "あ")
	writeFile(t, root, "project.json", `{"title": "別の題", "windowScale": 3, "glyphs": "auto", "fonts": [{"name": "default", "path": "assets/f.ttf", "fontSize": 48.0}]}`)
	if before != inputsOf(t, root, "あ") {
		t.Error("字に関係ない project.json の欄で指紋が変わった")
	}
}

func writeManifestFile(t *testing.T, dir, body string, atlases ...string) {
	t.Helper()
	os.MkdirAll(dir, 0o755)
	if err := os.WriteFile(filepath.Join(dir, "fonts.json"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, a := range atlases {
		if err := os.WriteFile(filepath.Join(dir, a), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestIsFreshWhenInputsMatchAndAtlasesExist(t *testing.T) {
	dir := t.TempDir()
	writeManifestFile(t, dir, `{"inputs": "abc", "fonts": [{"file": "default.fontatlas"}]}`, "default.fontatlas", "default.fontatlas.key")
	if !IsFresh(dir, "abc") {
		t.Error("指紋が同じでアトラスもあるのに古いと見た")
	}
}

func TestIsNotFreshWhenInputsDiffer(t *testing.T) {
	dir := t.TempDir()
	writeManifestFile(t, dir, `{"inputs": "abc", "fonts": [{"file": "default.fontatlas"}]}`, "default.fontatlas", "default.fontatlas.key")
	if IsFresh(dir, "xyz") {
		t.Error("指紋が違うのに新しいと見た")
	}
}

func TestIsNotFreshWithoutInputs(t *testing.T) {
	dir := t.TempDir()
	writeManifestFile(t, dir, `{"fonts": [{"file": "default.fontatlas"}]}`, "default.fontatlas")
	if IsFresh(dir, "") {
		t.Error("指紋の無い fonts.json（漏れで止まった回）を新しいと見た")
	}
}

func TestIsNotFreshWhenAtlasIsMissing(t *testing.T) {
	dir := t.TempDir()
	writeManifestFile(t, dir, `{"inputs": "abc", "fonts": [{"file": "default.fontatlas"}]}`)
	if IsFresh(dir, "abc") {
		t.Error("アトラスが無いのに新しいと見た")
	}
}

func TestIsNotFreshWhenKeyIsMissing(t *testing.T) {
	dir := t.TempDir()
	writeManifestFile(t, dir, `{"inputs": "abc", "fonts": [{"file": "default.fontatlas"}]}`, "default.fontatlas")
	if IsFresh(dir, "abc") {
		t.Error(".key の無いアトラス（デスクトップが読まない）を新しいと見た")
	}
}

func TestPackFilesIsEmptyWithNoFonts(t *testing.T) {
	dir := t.TempDir()
	writeManifestFile(t, dir, `{"fonts": []}`)
	if PackFiles(dir) != nil {
		t.Error("1 本も無いのに揃っていると見た")
	}
}
