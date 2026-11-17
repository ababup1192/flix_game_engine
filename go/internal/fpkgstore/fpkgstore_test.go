package fpkgstore

// What: current の辿り方（辿った先の絶対パス・無い時）・置き場の中かの判定・lock の engine の節の読み書き・
// 読むだけのファイルの置き換え。

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCurrentResolvesToTheEntryDirectory(t *testing.T) {
	eng := t.TempDir()
	entry := filepath.Join(Dir(eng), "engine_full-0.1.0-0123456789abcdef")
	if err := os.MkdirAll(filepath.Join(Dir(eng), "current"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(entry, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../engine_full-0.1.0-0123456789abcdef", filepath.Join(Dir(eng), "current", EngineFull)); err != nil {
		t.Fatal(err)
	}
	got, ok := Current(eng, EngineFull)
	want, _ := filepath.EvalSymlinks(entry)
	if !ok || got != want {
		t.Errorf("Current = %q, %v（want %q）", got, ok, want)
	}
}

func TestCurrentIsAbsentWithoutAStore(t *testing.T) {
	if _, ok := Current(t.TempDir(), EngineFullWeb); ok {
		t.Error("置き場が無いのに在ると言っています")
	}
}

func TestIsInStoreFollowsTheSymlink(t *testing.T) {
	eng := t.TempDir()
	inside := filepath.Join(Dir(eng), "e", "package.fpkg")
	if err := os.MkdirAll(filepath.Dir(inside), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(inside, []byte("x"), 0o444); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(eng, "lib.fpkg")
	if err := os.Symlink(inside, link); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(eng, "artifact.fpkg")
	if err := os.WriteFile(outside, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !IsInStore(eng, link) {
		t.Error("置き場を指す symlink を外と言っています")
	}
	if IsInStore(eng, outside) {
		t.Error("置き場の外を中と言っています")
	}
}

const lock = "[lock]\nversion = 1\n\n" +
	`[packages."github:ababup1192/flix_game_engine"."0.1.0"]` + "\n" +
	`toml    = "sha256:aa"` + "\n" + `fpkg    = "sha256:bb"` + "\n\n" +
	`[packages."github:ababup1192/flix_game_engine"."0.2.0"]` + "\n" +
	`toml    = "sha256:cc"` + "\n" + `fpkg    = "sha256:dd"` + "\n"

func TestWithEngineLockTouchesOnlyThatVersion(t *testing.T) {
	got, found := WithEngineLock(lock, "0.2.0", "11", "22")
	if !found {
		t.Fatal("節を見つけていません")
	}
	if !strings.Contains(got, `"sha256:aa"`) || !strings.Contains(got, `"sha256:bb"`) {
		t.Errorf("別の版の節まで書き換えています:\n%s", got)
	}
	if tomlSum, fpkgSum, ok := EngineLockSums(got, "0.2.0"); !ok || tomlSum != "11" || fpkgSum != "22" {
		t.Errorf("書いた sha を読めません: %q %q %v", tomlSum, fpkgSum, ok)
	}
}

func TestWithEngineLockLeavesAMissingSectionToFlix(t *testing.T) {
	got, found := WithEngineLock(lock, "0.3.0", "11", "22")
	if found || got != lock {
		t.Errorf("無い節を足しています: found=%v\n%s", found, got)
	}
}

func TestWriteFileAtomicReplacesAReadOnlyFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.fpkg")
	if err := os.WriteFile(path, []byte("old"), 0o444); err != nil {
		t.Fatal(err)
	}
	if err := WriteFileAtomic(path, []byte("new"), 0o644); err != nil {
		t.Fatal(err)
	}
	body, _ := os.ReadFile(path)
	info, _ := os.Stat(path)
	if string(body) != "new" || info.Mode().Perm() != 0o644 {
		t.Errorf("中身 %q・mode %v", body, info.Mode().Perm())
	}
}
