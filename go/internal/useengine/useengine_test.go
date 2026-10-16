package useengine

// 何を守るか: 向けた先のエンジンの fpkg が lib に入り local.mk がそこを指すこと、
// --restore で最初の姿（local.mk・flix.toml・lib）へバイトまで戻ること。

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func fakeEngine(t *testing.T, version, fpkg string) string {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "mk", "game.mk"), "")
	write(t, filepath.Join(dir, "Makefile"), "VERSION := "+version+"\n")
	write(t, filepath.Join(dir, "engine_full", "artifact", "package.fpkg"), fpkg)
	write(t, filepath.Join(dir, "engine_full", "flix.toml"), "version = \""+version+"\"\n")
	write(t, filepath.Join(dir, "engine_full", "lib", "external", "lwjgl.jar"), "jar")
	return dir
}

const gameToml = `[dependencies]
"github:ababup1192/flix_game_engine" = { version = "0.35.16", security = "unrestricted" }
`

func fakeGame(t *testing.T, withLib bool) string {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "flix.toml"), gameToml)
	write(t, filepath.Join(dir, "local.mk"), "# mine\nENGINE := /old/engine\n")
	if withLib {
		write(t, filepath.Join(dir, libEngineDir, "0.35.16", "flix_game_engine-0.35.16.fpkg"), "old")
		write(t, filepath.Join(dir, "lib", "external", "lwjgl.jar"), "jar")
	}
	return dir
}

func opts(game string) Options {
	return Options{Game: game, Home: filepath.Join(game, "home"), Out: io.Discard, Err: io.Discard}
}

func TestUsePutsEngineFpkgAndPointsLocalMk(t *testing.T) {
	engine := fakeEngine(t, "0.35.16", "new")
	game := fakeGame(t, true)
	if err := Use(engine, opts(game)); err != nil {
		t.Fatal(err)
	}
	got := read(t, filepath.Join(game, libEngineDir, "0.35.16", "flix_game_engine-0.35.16.fpkg"))
	if got != "new" {
		t.Fatalf("lib の fpkg が向けた先の物ではない: %q", got)
	}
	if engineOfLocalMk(read(t, filepath.Join(game, "local.mk"))) != engine {
		t.Fatalf("local.mk が向けた先を指していない")
	}
}

func TestRestoreBringsBackFirstState(t *testing.T) {
	game := fakeGame(t, true)
	o := opts(game)
	// 2 回向けても戻る先は最初の姿。
	if err := Use(fakeEngine(t, "0.35.9", "a"), o); err != nil {
		t.Fatal(err)
	}
	if err := Use(fakeEngine(t, "0.35.16", "b"), o); err != nil {
		t.Fatal(err)
	}
	if err := Restore(o); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(game, "flix.toml")) != gameToml {
		t.Fatalf("flix.toml が戻っていない")
	}
	if read(t, filepath.Join(game, "local.mk")) != "# mine\nENGINE := /old/engine\n" {
		t.Fatalf("local.mk が戻っていない")
	}
	if read(t, filepath.Join(game, libEngineDir, "0.35.16", "flix_game_engine-0.35.16.fpkg")) != "old" {
		t.Fatalf("lib の fpkg が戻っていない")
	}
}

func TestOtherVersionFollowsInFlixToml(t *testing.T) {
	game := fakeGame(t, true)
	if err := Use(fakeEngine(t, "0.35.9", "a"), opts(game)); err != nil {
		t.Fatal(err)
	}
	if m := depRe.FindStringSubmatch(read(t, filepath.Join(game, "flix.toml"))); m == nil || m[2] != "0.35.9" {
		t.Fatalf("flix.toml の版が lib のフォルダとそろっていない: %v", m)
	}
}

func TestRestoreRemovesLibThatWasNotThere(t *testing.T) {
	game := fakeGame(t, false)
	o := opts(game)
	if err := Use(fakeEngine(t, "0.35.16", "a"), o); err != nil {
		t.Fatal(err)
	}
	if !isFile(filepath.Join(game, "lib", "external", "lwjgl.jar")) {
		t.Fatalf("lib/external をエンジンから写していない")
	}
	if err := Restore(o); err != nil {
		t.Fatal(err)
	}
	if isDir(filepath.Join(game, "lib")) {
		t.Fatalf("無かった lib が残った")
	}
}

func TestResolvePrefersInstalledEngine(t *testing.T) {
	game := fakeGame(t, true)
	o := opts(game)
	installed := filepath.Join(o.Home, "engines", "0.35.16")
	write(t, filepath.Join(installed, "mk", "game.mk"), "")
	write(t, filepath.Join(installed, "engine_full", "artifact", "engine_full.fpkg"), "x")
	got, err := Resolve("0.35.16", o)
	if err != nil || got != installed {
		t.Fatalf("置いてある版を使わない: %q %v", got, err)
	}
}

func TestResolveFillsDefaultHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("FGE_STUDIO_HOME", home)
	installed := filepath.Join(home, "engines", "0.35.16")
	write(t, filepath.Join(installed, "mk", "game.mk"), "")
	write(t, filepath.Join(installed, "engine_full", "artifact", "engine_full.fpkg"), "x")
	got, err := Resolve("0.35.16", Options{Game: fakeGame(t, true)})
	if err != nil || got != installed {
		t.Fatalf("既定の置き場を見ない: %q %v", got, err)
	}
}

func TestMissingVersionWithoutCloneStopsAndSaysWhatToDo(t *testing.T) {
	t.Setenv("FGE_ENGINE_REPO", "")
	game := fakeGame(t, true)
	_, err := Resolve("0.35.99", opts(game))
	if err == nil || !strings.Contains(err.Error(), "--repo") || !strings.Contains(err.Error(), "engines") {
		t.Fatalf("clone が分からない時に止まって手を知らせない: %v", err)
	}
}
