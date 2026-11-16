package main

import (
	"os"
	"path/filepath"
	"testing"
)

// engine の devbox に java があれば、その bin が PATH の先頭に来る。
func TestPathWithEngineJavaPrependsDevboxBin(t *testing.T) {
	engine := t.TempDir()
	bin := filepath.Join(engine, ".devbox", "nix", "profile", "default", "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "java"), nil, 0o755); err != nil {
		t.Fatal(err)
	}
	got, ok := pathWithEngineJava("/usr/bin", engine)
	if !ok || got != bin+string(os.PathListSeparator)+"/usr/bin" {
		t.Errorf("got %q %v", got, ok)
	}
}

// engine の devbox に java が無ければ、PATH はそのまま。
func TestPathWithEngineJavaKeepsPathWithoutDevbox(t *testing.T) {
	got, ok := pathWithEngineJava("/usr/bin", t.TempDir())
	if ok || got != "/usr/bin" {
		t.Errorf("got %q %v", got, ok)
	}
}

// refactor.local.json が flixlint を書いた時だけ、既定の flixlint の探し方を止める。
func TestLocalNamesFlixlintOnlyWhenTheFieldIsSet(t *testing.T) {
	for body, want := range map[string]bool{
		``: false,
		`{"verify": "java -jar bin/flix.jar check"}`: false,
		`{"flixlint": ""}`:                           false,
		`{"flixlint": "/opt/flixlint/bin/flixlint"}`: true,
	} {
		root := t.TempDir()
		if body != "" {
			dir := filepath.Join(root, "bin", "lint-rules")
			os.MkdirAll(dir, 0o755)
			os.WriteFile(filepath.Join(dir, "refactor.local.json"), []byte(body), 0o644)
		}
		if got := localNamesFlixlint(root); got != want {
			t.Errorf("%q: %v のはず（%v）", body, want, got)
		}
	}
}

// ルートの src/ は各パッケージの src/ をファイル単位で写す。足した・消した・名前を変えたファイルに索引の前で追いつく。
func TestSyncRootSrcFollowsAddedRemovedAndRenamedFiles(t *testing.T) {
	root := t.TempDir()
	write := func(rel string) {
		p := filepath.Join(root, filepath.FromSlash(rel))
		os.MkdirAll(filepath.Dir(p), 0o755)
		if err := os.WriteFile(p, []byte("mod X {}\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	link := func(rel, target string) {
		p := filepath.Join(root, filepath.FromSlash(rel))
		os.MkdirAll(filepath.Dir(p), 0o755)
		if err := os.Symlink(target, p); err != nil {
			t.Fatal(err)
		}
	}
	write("render_gl/flix.toml")
	write("render_gl/src/Render3d.flix")
	write("render_gl/src/Render3d/Old.flix")
	write("render_gl/src/Render3d/Mipmaps.flix")
	write("render_gl/src/notes.txt")
	write("src/Main.flix")
	link("src/render_gl/Render3d.flix", "../../render_gl/src/Render3d.flix")
	link("src/render_gl/Render3d/Old.flix", "../../../render_gl/src/Render3d/Old.flix")
	link("src/render_gl/Render3d/Gone.flix", "../../../render_gl/src/Render3d/Gone.flix")
	os.Rename(filepath.Join(root, "render_gl/src/Render3d/Old.flix"), filepath.Join(root, "render_gl/src/Render3d/New.flix"))

	added, removed, err := syncRootSrc(root)
	if err != nil {
		t.Fatal(err)
	}
	if added != 2 || removed != 2 {
		t.Errorf("足した %d・消した %d（2・2 のはず）", added, removed)
	}
	for _, rel := range []string{"src/render_gl/Render3d/Mipmaps.flix", "src/render_gl/Render3d/New.flix", "src/render_gl/Render3d.flix", "src/Main.flix"} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(rel))); err != nil {
			t.Errorf("%s が読めない: %v", rel, err)
		}
	}
	if got, _ := os.Readlink(filepath.Join(root, "src/render_gl/Render3d/Mipmaps.flix")); got != "../../../render_gl/src/Render3d/Mipmaps.flix" {
		t.Errorf("相対の symlink のはず: %q", got)
	}
	for _, rel := range []string{"src/render_gl/Render3d/Old.flix", "src/render_gl/Render3d/Gone.flix", "src/render_gl/notes.txt"} {
		if _, err := os.Lstat(filepath.Join(root, filepath.FromSlash(rel))); err == nil {
			t.Errorf("%s は無いはず", rel)
		}
	}
}

// src/ の下にパッケージ（<名前>/flix.toml と <名前>/src）の写しが無い所（ゲームの src）は触らない。
func TestSyncRootSrcLeavesNonMirrorTreesAlone(t *testing.T) {
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, "src", "Game"), 0o755)
	os.Symlink("../../nowhere.flix", filepath.Join(root, "src", "Game", "Dangling.flix"))
	added, removed, err := syncRootSrc(root)
	if err != nil || added != 0 || removed != 0 {
		t.Errorf("触らないはず: %d %d %v", added, removed, err)
	}
	if _, err := os.Lstat(filepath.Join(root, "src", "Game", "Dangling.flix")); err != nil {
		t.Errorf("消したらいけない: %v", err)
	}
}
