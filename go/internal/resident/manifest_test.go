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

// lib/github の中で flix.toml にも packages.lock にも無い版（版を上げた後に残る古い版）は、足しても消しても指紋が変わらない。
func TestManifestIgnoresUnusedLibVersions(t *testing.T) {
	d := gameDir(t)
	writeFile(t, filepath.Join(d, "flix.toml"), `[dependencies]
"github:ababup1192/flix_game_engine" = { version = "0.52.0", mount = "fge" }`)
	writeFile(t, filepath.Join(d, "lib", "github", "ababup1192", "flix_game_engine", "0.52.0", "e.fpkg"), "new")
	before := manifestOf(t, d)
	writeFile(t, filepath.Join(d, "lib", "github", "ababup1192", "flix_game_engine", "0.35.0", "e.fpkg"), "old")
	writeFile(t, filepath.Join(d, "lib", "github", "ababup1192", "flix_game_engine", "stray.fpkg"), "stray")
	if after := manifestOf(t, d); after != before {
		t.Fatal("使わない古い版・版のフォルダの外の物を足しただけで指紋が変わった")
	}
	writeFile(t, filepath.Join(d, "lib", "github", "ababup1192", "flix_game_engine", "0.52.0", "e.fpkg"), "changed")
	if after := manifestOf(t, d); after == before {
		t.Fatal("使う版の中身が変わったのに指紋が同じ")
	}
}

// packages.lock にだけある版（推移の依存）も指紋に入る。
func TestManifestSeesLockedVersions(t *testing.T) {
	d := gameDir(t)
	writeFile(t, filepath.Join(d, "packages.lock"), "[packages.\"github:someone/dep\".\"1.2.3\"]\nfpkg = \"x\"\n")
	before := manifestOf(t, d)
	writeFile(t, filepath.Join(d, "lib", "github", "someone", "dep", "1.2.3", "d.fpkg"), "dep")
	if after := manifestOf(t, d); after == before {
		t.Fatal("lock にある版を足したのに指紋が同じ")
	}
}

// jar を作る写しにだけある入口の束（src/FgeHeadlessMain.flix）は指紋に入らない（写しとゲームの根の指紋がそろう）。
func TestManifestSkipsTheDispatcher(t *testing.T) {
	d := gameDir(t)
	before := manifestOf(t, d)
	writeFile(t, filepath.Join(d, filepath.FromSlash(DispatcherFile)), "mod FgeHeadlessMain {}")
	if after := manifestOf(t, d); after != before {
		t.Fatal("入口の束を足しただけで指紋が変わった")
	}
}

// 元の指紋は lib を見ない（新しい作業場で flix が lib を落としても変わらない）。
func TestSourceManifestIgnoresLib(t *testing.T) {
	d := gameDir(t)
	writeFile(t, filepath.Join(d, "packages.lock"), "[lock]\nversion = 1\n")
	before, _ := BuildSourceManifest(d)
	writeFile(t, filepath.Join(d, "lib", "github", "ababup1192", "flix_game_engine", "0.52.0", "e.fpkg"), "fpkg")
	if after, _ := BuildSourceManifest(d); after != before {
		t.Fatal("lib を足しただけで元の指紋が変わった")
	}
}

// packages.lock が変われば元の指紋も変わる（lib の中身は lock が決める）。
func TestSourceManifestSeesTheLock(t *testing.T) {
	d := gameDir(t)
	writeFile(t, filepath.Join(d, "packages.lock"), "a")
	before, _ := BuildSourceManifest(d)
	writeFile(t, filepath.Join(d, "packages.lock"), "b")
	if after, _ := BuildSourceManifest(d); after == before {
		t.Fatal("packages.lock を変えても元の指紋が同じ")
	}
}

// packages.lock が無ければ元の指紋を作らない（依存の中身を決められない）。
func TestSourceManifestNeedsTheLock(t *testing.T) {
	if _, err := BuildSourceManifest(gameDir(t)); err == nil {
		t.Fatal("packages.lock が無いのに元の指紋を作った")
	}
}
