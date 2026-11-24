package upgradegame

// What: engine-upgrade が配った engine ではその engine の fge-go の upgrade-game を（Makefile と同じ引数で）起こし、
// clone した engine では make upgrade-game を起こすこと、TO= で入れた版を使うこと、TO= を clone では断ること、
// 追随待ち（3）を 0 にすること、Windows では fge-go.exe を起こすこと。

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type execRec struct {
	dir, name string
	args      []string
	code      int
}

func bundleFor(t *testing.T, version string) string {
	t.Helper()
	e := t.TempDir()
	write(t, e, "Makefile", "VERSION := "+version+"\n")
	write(t, e, "engine_full/artifact/engine_full.fpkg", "f")
	write(t, e, "engine_full/flix.toml", "t")
	return e
}

func upgradeWorld(t *testing.T, engine string, installed string) (EngineUpgradeDeps, *execRec, *[]string, *strings.Builder) {
	t.Helper()
	game := t.TempDir()
	write(t, game, "flix.toml", gameToml)
	rec := &execRec{}
	var installs []string
	errOut := &strings.Builder{}
	return EngineUpgradeDeps{
		Out: &strings.Builder{}, Err: errOut,
		Getwd:         func() (string, error) { return game, nil },
		ResolveEngine: func(string) string { return engine },
		Install: func(v string) (string, error) {
			installs = append(installs, v)
			return installed, nil
		},
		Exec: func(dir, name string, args ...string) (int, error) {
			rec.dir, rec.name, rec.args = dir, name, args
			return rec.code, nil
		},
		GOOS: "linux",
	}, rec, &installs, errOut
}

func TestBundleEngineRunsItsOwnUpgradeGame(t *testing.T) {
	e := bundleFor(t, "0.31.0")
	d, rec, _, _ := upgradeWorld(t, e, "")
	game, _ := d.Getwd()
	if code := RunEngineUpgrade(nil, d); code != exitDone {
		t.Fatalf("code=%d", code)
	}
	want := []string{"upgrade-game", "--game", game, "--version", "0.31.0",
		"--fpkg", filepath.Join(e, "engine_full/artifact/engine_full.fpkg"), "--toml", filepath.Join(e, "engine_full/flix.toml"),
		"--dest", "lib/github/ababup1192/flix_game_engine/0.31.0",
		"--fpkg-name", "flix_game_engine-0.31.0.fpkg", "--toml-name", "flix_game_engine-0.31.0.toml", "--no-content-swap"}
	if rec.name != filepath.Join(e, "bin", "fge-go") || strings.Join(rec.args, " ") != strings.Join(want, " ") {
		t.Errorf("起こし方: %s %v", rec.name, rec.args)
	}
}

func TestFollowUpIsReportedAsDone(t *testing.T) {
	d, rec, _, _ := upgradeWorld(t, bundleFor(t, "0.31.0"), "")
	rec.code = exitFollowUp
	if code := RunEngineUpgrade(nil, d); code != exitDone {
		t.Errorf("code=%d", code)
	}
}

func TestToInstallsAndUsesThatEngine(t *testing.T) {
	newer := bundleFor(t, "0.32.0")
	d, rec, installs, _ := upgradeWorld(t, bundleFor(t, "0.31.0"), newer)
	if code := RunEngineUpgrade([]string{"TO=0.32.0", "REFERENCE=1"}, d); code != exitDone {
		t.Fatalf("code=%d", code)
	}
	if strings.Join(*installs, ",") != "0.32.0" {
		t.Errorf("installs=%v", *installs)
	}
	if rec.dir != newer || !strings.Contains(strings.Join(rec.args, " "), "--version 0.32.0") || rec.args[len(rec.args)-1] != "--reference" {
		t.Errorf("新しい engine で起こしていません: %s %v", rec.dir, rec.args)
	}
}

func TestToIsRefusedForAClonedEngine(t *testing.T) {
	e := bundleFor(t, "0.31.0")
	write(t, e, "go/go.mod", "module x\n")
	d, rec, installs, errOut := upgradeWorld(t, e, "")
	if code := RunEngineUpgrade([]string{"TO=0.32.0"}, d); code == exitDone {
		t.Error("clone で TO= を通しています")
	}
	if len(*installs) != 0 || rec.name != "" || !strings.Contains(errOut.String(), "配った engine の時だけ") {
		t.Errorf("installs=%v exec=%s err=%s", *installs, rec.name, errOut.String())
	}
}

func TestClonedEngineGoesThroughMakeUpgradeGame(t *testing.T) {
	e := bundleFor(t, "0.31.0")
	write(t, e, "go/go.mod", "module x\n")
	d, rec, _, _ := upgradeWorld(t, e, "")
	game, _ := d.Getwd()
	RunEngineUpgrade(nil, d)
	if rec.name != "make" || strings.Join(rec.args, " ") != "-C "+e+" upgrade-game GAME="+game {
		t.Errorf("起こし方: %s %v", rec.name, rec.args)
	}
}

func TestWindowsRunsTheExe(t *testing.T) {
	e := bundleFor(t, "0.31.0")
	d, rec, _, _ := upgradeWorld(t, e, "")
	d.GOOS = "windows"
	RunEngineUpgrade(nil, d)
	if rec.name != filepath.Join(e, "bin", "fge-go.exe") {
		t.Errorf("name=%s", rec.name)
	}
}

func TestOutsideAGameIsRefused(t *testing.T) {
	d, _, _, _ := upgradeWorld(t, bundleFor(t, "0.31.0"), "")
	empty := t.TempDir()
	d.Getwd = func() (string, error) { return empty, nil }
	if code := RunEngineUpgrade(nil, d); code != exitBadUsage {
		t.Errorf("code=%d", code)
	}
	_ = os.Remove(empty)
}
