package newgame

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
	"github.com/ababup1192/flix_game_engine/go/internal/fgeinstall"
)

func TestPackageNameReplacesHyphens(t *testing.T) {
	got, err := PackageName("tide-pool", "")
	if err != nil || got != "tide_pool" {
		t.Fatalf("got %q %v", got, err)
	}
}

func TestPackageNamePrefersTheNameFlag(t *testing.T) {
	got, err := PackageName("Tide-Pool", "tide")
	if err != nil || got != "tide" {
		t.Fatalf("got %q %v", got, err)
	}
}

func TestPackageNameRefusesAnUppercaseFolderAndSuggestsANameFlag(t *testing.T) {
	_, err := PackageName("Tide-Pool", "")
	if err == nil || !strings.Contains(err.Error(), "--name tide_pool") {
		t.Fatalf("--name の例が無い: %v", err)
	}
}

func TestPackageNameRefusesALeadingDigit(t *testing.T) {
	if _, err := PackageName("2048", ""); err == nil {
		t.Fatal("数字はじまりを受けた")
	}
}

func TestParseArgsReadsFlagsAfterTheFolder(t *testing.T) {
	o, err := parseArgs([]string{"tidepool", "--template", "rpg-starter", "--title", "潮"}, &strings.Builder{})
	if err != nil || o.folder != "tidepool" || o.template != "rpg-starter" || o.title != "潮" {
		t.Fatalf("o=%+v err=%v", o, err)
	}
}

func TestInstallHintNamesXcodeOnMacOS(t *testing.T) {
	if !strings.Contains(installHint("darwin", []string{"make"}), "xcode-select --install") {
		t.Fatal("macOS の入れ方が無い")
	}
}

func makeEngine(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for name, readme := range map[string]string{
		"game-starter": "# __TITLE__\n\nスターター。\n",
		"rpg-starter":  "# ルーネの泉\n\n王道 RPG のスターター。\n",
	} {
		td := filepath.Join(dir, "templates", name)
		if err := os.MkdirAll(td, 0o755); err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(td, "README.md"), []byte(readme), 0o644)
	}
	os.WriteFile(filepath.Join(dir, "templates", "rpg-starter", "project.json"), []byte(`{"title": "ルーネの泉"}`), 0o644)
	os.WriteFile(filepath.Join(dir, "templates", "game-starter", "project.json"), []byte(`{"title": "__TITLE__"}`), 0o644)
	return dir
}

func TestListTemplatesReadsTitleAndSummary(t *testing.T) {
	list, err := ListTemplates(makeEngine(t))
	if err != nil || len(list) != 2 {
		t.Fatalf("list=%v err=%v", list, err)
	}
	want := Template{Name: "rpg-starter", Title: "ルーネの泉", Summary: "王道 RPG のスターター。"}
	if list[1] != want {
		t.Fatalf("got %+v", list[1])
	}
}

func TestListTemplatesHidesAnUnreplacedTitle(t *testing.T) {
	list, _ := ListTemplates(makeEngine(t))
	if list[0].Name != "game-starter" || list[0].Title != "" {
		t.Fatalf("got %+v", list[0])
	}
}

type fakeRun struct {
	makeArgs  []string
	installed []string
}

func fakeDeps(t *testing.T, engine string, r *fakeRun) Deps {
	t.Helper()
	t.Setenv("FGE_HOME", t.TempDir())
	cwd := t.TempDir()
	return Deps{
		Install: func(v string) (fgeinstall.InstallResult, error) {
			r.installed = append(r.installed, v)
			return fgeinstall.InstallResult{Version: v, EngineDir: engine}, nil
		},
		Latest:   func() (string, error) { return "0.109.0", nil },
		Newest:   func() string { return "" },
		LookPath: func(name string) (string, error) { return "/usr/bin/" + name, nil },
		RunMake: func(args []string) error {
			r.makeArgs = args
			return nil
		},
		Getwd:    func() (string, error) { return cwd, nil },
		GOOS:     "linux",
		Progress: &strings.Builder{},
	}
}

func TestRunPassesTheNewGameArgumentsToMake(t *testing.T) {
	engine := makeEngine(t)
	r := &fakeRun{}
	d := fakeDeps(t, engine, r)
	cwd, _ := d.Getwd()

	var out, errOut strings.Builder
	if code := Run(&out, &errOut, []string{"tide-pool", "--template", "rpg-starter", "--title", "潮"}, false, d); code != 0 {
		t.Fatalf("code=%d %s", code, errOut.String())
	}
	want := []string{"-C", engine, "new-game", "GAME=" + filepath.Join(cwd, "tide-pool"), "NAME=tide_pool", "TEMPLATE=rpg-starter", "PACK_NOTE=0", "TITLE=潮"}
	if strings.Join(r.makeArgs, "|") != strings.Join(want, "|") {
		t.Fatalf("got %v", r.makeArgs)
	}
}

func TestRunAddsTheGameToTheWorkspace(t *testing.T) {
	r := &fakeRun{}
	d := fakeDeps(t, makeEngine(t), r)
	cwd, _ := d.Getwd()

	var out, errOut strings.Builder
	if code := Run(&out, &errOut, []string{"tidepool"}, false, d); code != 0 {
		t.Fatalf("code=%d %s", code, errOut.String())
	}
	ws, err := fgehome.ReadWorkspace()
	if err != nil || len(ws.Games) != 1 || ws.Games[0] != (fgehome.Game{Name: "tidepool", Dir: filepath.Join(cwd, "tidepool")}) {
		t.Fatalf("ws=%+v err=%v", ws, err)
	}
}

func TestRunUsesTheLatestReleaseWhenNoEngineIsInstalled(t *testing.T) {
	r := &fakeRun{}
	d := fakeDeps(t, makeEngine(t), r)

	var out, errOut strings.Builder
	Run(&out, &errOut, []string{"tidepool"}, false, d)
	if len(r.installed) != 1 || r.installed[0] != "0.109.0" {
		t.Fatalf("got %v", r.installed)
	}
}

func TestRunPrefersTheNewestInstalledEngine(t *testing.T) {
	r := &fakeRun{}
	d := fakeDeps(t, makeEngine(t), r)
	d.Newest = func() string { return "0.108.0" }

	var out, errOut strings.Builder
	Run(&out, &errOut, []string{"tidepool"}, false, d)
	if len(r.installed) != 1 || r.installed[0] != "0.108.0" {
		t.Fatalf("got %v", r.installed)
	}
}

func TestRunStopsBeforeDownloadingWhenMakeIsMissing(t *testing.T) {
	r := &fakeRun{}
	d := fakeDeps(t, makeEngine(t), r)
	d.LookPath = func(name string) (string, error) {
		if name == "make" {
			return "", errors.New("not found")
		}
		return "/usr/bin/" + name, nil
	}

	var out, errOut strings.Builder
	code := Run(&out, &errOut, []string{"tidepool"}, false, d)
	if code == 0 || len(r.installed) != 0 || !strings.Contains(errOut.String(), "make") {
		t.Fatalf("code=%d installed=%v err=%s", code, r.installed, errOut.String())
	}
}

func TestRunRefusesAnExistingFolder(t *testing.T) {
	r := &fakeRun{}
	d := fakeDeps(t, makeEngine(t), r)
	cwd, _ := d.Getwd()
	os.MkdirAll(filepath.Join(cwd, "tidepool"), 0o755)

	var out, errOut strings.Builder
	if code := Run(&out, &errOut, []string{"tidepool"}, false, d); code == 0 || r.makeArgs != nil {
		t.Fatalf("既にあるフォルダへ作った: code=%d", code)
	}
}

func TestRunRefusesAnUnknownTemplate(t *testing.T) {
	r := &fakeRun{}
	d := fakeDeps(t, makeEngine(t), r)

	var out, errOut strings.Builder
	code := Run(&out, &errOut, []string{"tidepool", "--template", "shmup-starter"}, false, d)
	if code == 0 || r.makeArgs != nil || !strings.Contains(errOut.String(), "rpg-starter") {
		t.Fatalf("code=%d err=%s", code, errOut.String())
	}
}

func TestRunRefusesAFolderNameWithASlash(t *testing.T) {
	r := &fakeRun{}
	d := fakeDeps(t, makeEngine(t), r)

	var out, errOut strings.Builder
	if code := Run(&out, &errOut, []string{"a/b"}, false, d); code == 0 {
		t.Fatal("/ 入りの名前を受けた")
	}
}

func TestRunRemovesTheHalfMadeFolderWhenMakeStops(t *testing.T) {
	r := &fakeRun{}
	d := fakeDeps(t, makeEngine(t), r)
	cwd, _ := d.Getwd()
	dir := filepath.Join(cwd, "tidepool")
	d.RunMake = func(args []string) error {
		os.MkdirAll(filepath.Join(dir, "assets"), 0o755)
		return errors.New("exit status 2")
	}

	var out, errOut strings.Builder
	Run(&out, &errOut, []string{"tidepool"}, false, d)
	if _, err := os.Lstat(dir); !os.IsNotExist(err) {
		t.Fatalf("作りかけが残った: %v", err)
	}
}

func TestRunSaysItRemovedTheHalfMadeFolder(t *testing.T) {
	r := &fakeRun{}
	d := fakeDeps(t, makeEngine(t), r)
	cwd, _ := d.Getwd()
	d.RunMake = func(args []string) error {
		os.MkdirAll(filepath.Join(cwd, "tidepool"), 0o755)
		return errors.New("exit status 2")
	}

	var out, errOut strings.Builder
	Run(&out, &errOut, []string{"tidepool"}, false, d)
	if got := d.Progress.(*strings.Builder).String(); !strings.Contains(got, "作りかけの "+filepath.Join(cwd, "tidepool")+" を消しました") {
		t.Fatalf("消したと出ていない: %s", got)
	}
}

func TestRunKeepsAFolderThatWasThereBefore(t *testing.T) {
	r := &fakeRun{}
	d := fakeDeps(t, makeEngine(t), r)
	cwd, _ := d.Getwd()
	keep := filepath.Join(cwd, "tidepool", "mine.txt")
	os.MkdirAll(filepath.Dir(keep), 0o755)
	os.WriteFile(keep, []byte("x"), 0o644)
	d.RunMake = func(args []string) error { return errors.New("exit status 2") }

	var out, errOut strings.Builder
	Run(&out, &errOut, []string{"tidepool"}, false, d)
	if _, err := os.Stat(keep); err != nil {
		t.Fatalf("前からあったフォルダを消した: %v", err)
	}
}

func TestRunKeepsTheGameWhenMakeSucceeds(t *testing.T) {
	r := &fakeRun{}
	d := fakeDeps(t, makeEngine(t), r)
	cwd, _ := d.Getwd()
	dir := filepath.Join(cwd, "tidepool")
	d.RunMake = func(args []string) error { return os.MkdirAll(dir, 0o755) }

	var out, errOut strings.Builder
	Run(&out, &errOut, []string{"tidepool"}, false, d)
	if _, err := os.Stat(dir); err != nil {
		t.Fatalf("できたゲームを消した: %v", err)
	}
}

func TestRunTellsNewGameNotToPrintThePackNote(t *testing.T) {
	r := &fakeRun{}
	d := fakeDeps(t, makeEngine(t), r)

	var out, errOut strings.Builder
	Run(&out, &errOut, []string{"tidepool"}, false, d)
	if !strings.Contains(strings.Join(r.makeArgs, " "), "PACK_NOTE=0") {
		t.Fatalf("got %v", r.makeArgs)
	}
}
