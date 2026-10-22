package refactor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// flixJarStub は jar の版を表で返し、同じ版を探す所を dir の下に差し替える（java を立てない）。
func flixJarStub(t *testing.T, versions map[string]string, nix []string, engines string) {
	t.Helper()
	oldV, oldR := flixJarVersion, flixJarRoots
	flixJarVersion = func(jar string) string { return versions[jar] }
	flixJarRoots = func() ([]string, string) { return nix, engines }
	t.Cleanup(func() { flixJarVersion, flixJarRoots = oldV, oldR })
}

func touch(t *testing.T, p, body string) string {
	t.Helper()
	must(t, os.MkdirAll(filepath.Dir(p), 0o755))
	must(t, os.WriteFile(p, []byte(body), 0o644))
	return p
}

// 常駐（や PATH）の jar が flix.toml より古ければ、Studio の engines の同じ版の jar を選び直す。新しい engine の版が先。
func TestChooseFlixJarPicksTheJarOfTheTomlVersion(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "game")
	touch(t, filepath.Join(root, "flix.toml"), "[package]\nflix    = \"0.78.0\"\n")
	old := touch(t, filepath.Join(dir, "old", "flix.jar"), "x")
	engines := filepath.Join(dir, "engines")
	a := touch(t, filepath.Join(engines, "0.54.0", "bin", "flix.jar"), "x")
	b := touch(t, filepath.Join(engines, "0.55.1", "bin", "flix.jar"), "x")
	touch(t, filepath.Join(engines, "0.54.0", "engine_full", "flix.toml"), "flix = \"0.78.0\"\n")
	touch(t, filepath.Join(engines, "0.55.1", "engine_full", "flix.toml"), "flix = \"0.78.0\"\n")
	flixJarStub(t, map[string]string{old: "0.77.0", a: "0.78.0", b: "0.78.0"}, nil, engines)
	t.Setenv("FLIX_JAR", "")
	c := ChooseFlixJar(root, "", Config{}, old)
	if !c.Picked || c.Jar != b || !strings.Contains(c.Note, "make check の常駐の jar（"+old+"）は 0.77.0") {
		t.Fatalf("%+v", c)
	}
}

// FLIX_JAR で名指しした jar は替えず、版が合わなければ索引が落ちた時に直し方を出す。
func TestChooseFlixJarKeepsTheNamedJarAndSaysHowToFix(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "game")
	touch(t, filepath.Join(root, "flix.toml"), "[package]\nflix = \"0.78.0\"\n")
	old := touch(t, filepath.Join(dir, "old", "flix.jar"), "x")
	flixJarStub(t, map[string]string{old: "0.77.0"}, nil, "")
	t.Setenv("FLIX_JAR", old)
	c := ChooseFlixJar(root, "", Config{}, "")
	ie := Builder{FlixHint: c.Mismatch}.indexError(Resolved, 4, "")
	if c.Picked || c.Jar != old || !strings.Contains(ie.Msg, "使っている flix は 0.77.0（"+old+"・FLIX_JAR）・このプロジェクトの flix.toml は 0.78.0。FLIX_JAR を flix 0.78.0 の jar に替える") {
		t.Fatalf("%+v\n%s", c, ie.Msg)
	}
}
