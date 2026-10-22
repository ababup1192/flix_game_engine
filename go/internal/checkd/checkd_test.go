package checkd

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/hooks"
)

func repoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return root
}

func loadRules(t *testing.T) *hooks.Rules {
	t.Helper()
	r, err := hooks.LoadRules(repoRoot(t))
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestServerMarkReadsBack(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "server"), []byte("/c/flixlint/ab.sock\n/p/game\nflix=1 shim=2\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	m, ok := readServerMark(dir)
	if !ok || m.socket != "/c/flixlint/ab.sock" || m.pkg != "/p/game" || m.identity != "flix=1 shim=2" {
		t.Fatalf("got %+v %v", m, ok)
	}
	if _, ok := readServerMark(t.TempDir()); ok {
		t.Error("a directory without the mark read as one")
	}
}

func TestCheckGoesToTheServerUnlessCli(t *testing.T) {
	r := loadRules(t)
	t.Setenv(*r.Checkd.Server.BackendEnvVar, "")
	if !useServer(r) {
		t.Error("check does not go to the server by default")
	}
	t.Setenv(*r.Checkd.Server.BackendEnvVar, "cli")
	if useServer(r) {
		t.Error("CHECKD_BACKEND=cli still goes to the server")
	}
}

func TestFlixBinPrefersPackageLocalWrapper(t *testing.T) {
	pkg := t.TempDir()
	if err := os.MkdirAll(filepath.Join(pkg, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	local := filepath.Join(pkg, "bin", "flix")
	if err := os.WriteFile(local, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := flixBin("/nonexistent", pkg); got != local {
		t.Errorf("パッケージ足元の bin/flix を優先していません: %s", got)
	}
}

func TestFlixBinReadsEngineFromLocalMk(t *testing.T) {
	engine := t.TempDir()
	if err := os.MkdirAll(filepath.Join(engine, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(engine, "bin", "flix")
	if err := os.WriteFile(want, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	pkg := t.TempDir()
	if err := os.WriteFile(filepath.Join(pkg, "local.mk"),
		[]byte("ENGINE := "+engine+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ENGINE", "")
	if got := flixBin("/nonexistent", pkg); got != want {
		t.Errorf("local.mk の ENGINE を見ていません: %s", got)
	}
}
