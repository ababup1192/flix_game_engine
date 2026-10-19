package resident

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func gameDir(t *testing.T) string {
	t.Helper()
	d := t.TempDir()
	writeFile(t, filepath.Join(d, "src", "Main.flix"), "mod Main {}")
	writeFile(t, filepath.Join(d, "src", "a", "B.flix"), "mod B {}")
	writeFile(t, filepath.Join(d, "flix.toml"), "[package]")
	return d
}

func manifestOf(t *testing.T, d string) string {
	t.Helper()
	m, err := BuildManifest(d)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestManifestIs64Hex(t *testing.T) {
	if m := manifestOf(t, gameDir(t)); len(m) != 64 {
		t.Fatalf("長さ %d", len(m))
	}
}

func TestManifestIgnoresMtime(t *testing.T) {
	d := gameDir(t)
	before := manifestOf(t, d)
	later := time.Now().Add(time.Hour)
	_ = os.Chtimes(filepath.Join(d, "src", "Main.flix"), later, later)
	if after := manifestOf(t, d); after != before {
		t.Fatal("時刻だけで指紋が変わった")
	}
}

func TestManifestSeesContentChange(t *testing.T) {
	d := gameDir(t)
	before := manifestOf(t, d)
	writeFile(t, filepath.Join(d, "src", "a", "B.flix"), "mod B { }")
	if after := manifestOf(t, d); after == before {
		t.Fatal("中身が変わったのに指紋が同じ")
	}
}

func TestManifestFollowsLibSymlink(t *testing.T) {
	d := gameDir(t)
	real := t.TempDir()
	writeFile(t, filepath.Join(real, "engine.fpkg"), "v1")
	if err := os.Symlink(real, filepath.Join(d, "lib")); err != nil {
		t.Fatal(err)
	}
	before := manifestOf(t, d)
	writeFile(t, filepath.Join(real, "engine.fpkg"), "v2")
	if after := manifestOf(t, d); after == before {
		t.Fatal("lib の symlink の先が変わったのに指紋が同じ")
	}
}

func TestManifestSeesNewFile(t *testing.T) {
	d := gameDir(t)
	before := manifestOf(t, d)
	writeFile(t, filepath.Join(d, "src", "C.flix"), "")
	if after := manifestOf(t, d); after == before {
		t.Fatal("ファイルが増えたのに指紋が同じ")
	}
}

func TestReadManifestTakesFirstLine(t *testing.T) {
	d := t.TempDir()
	writeFile(t, filepath.Join(d, ManifestFile), "abc\n")
	if got := ReadManifest(d); got != "abc" {
		t.Fatalf("%q", got)
	}
}
