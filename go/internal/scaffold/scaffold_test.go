package scaffold

// What: 置き換えの規則（字の順・画風の仮置きの行・new-game.exclude の読み方）が前の perl の 1 行と同じこと、
// テンプレートから作ったゲームの形（運ばない物・改名・lib の種・local.mk・git・配る物・産声の確認の順）、
// 配った engine と作業コピーと Windows の分かれ目。

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func put(t *testing.T, dir, rel, body string) {
	t.Helper()
	p := filepath.Join(dir, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func get(t *testing.T, dir, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(rel)))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func exists(dir, rel string) bool {
	_, err := os.Lstat(filepath.Join(dir, filepath.FromSlash(rel)))
	return err == nil
}

func TestTokensReplaceWideBeforeNarrow(t *testing.T) {
	got := ApplyTokens("__WW__x__WH__ __W__x__H__", Tokens("g", "t", 240, 320))
	if got != "480x640 240x320" {
		t.Errorf("got %q", got)
	}
}

func TestTitleIsReplacedAfterNameLikeThePerlLine(t *testing.T) {
	got := ApplyTokens("__TITLE__", Tokens("g", "a __W__ b", 10, 20))
	if got != "a 10 b" {
		t.Errorf("got %q", got)
	}
}

func TestStyleNoteTakesTheBlankLineAfterTheHeading(t *testing.T) {
	in := "x\n## この画面の画風\n\n<!-- 注文 -->\n"
	want := "x\n## この画面の画風\n\n（テンプレ rpg-starter の画風の仮置き。**最初に決めて、ここに** 自分の画風を書き直す — 決め方は画風の聞き取りスキル）\n<!-- 注文 -->\n"
	if got := WithStyleNote(in, "rpg-starter"); got != want {
		t.Errorf("got %q", got)
	}
}

func TestStyleNoteAlsoMatchesTheGameHeading(t *testing.T) {
	got := WithStyleNote("## このゲームの画風  \nz", "a")
	if !strings.HasPrefix(got, "## このゲームの画風\n\n（テンプレ a の") || !strings.HasSuffix(got, "）z") {
		t.Errorf("got %q", got)
	}
}

func TestExcludePathsSkipsCommentsAbsoluteAndParent(t *testing.T) {
	got := ExcludePaths("# 注釈\nsample-test  # 作例\n/etc\n../x\n\na/b/\n")
	if strings.Join(got, ",") != "sample-test,a/b" {
		t.Errorf("got %v", got)
	}
}

func TestTokenTargetsAreTextFilesAndMakefile(t *testing.T) {
	for name, want := range map[string]bool{
		"Main.flix": true, "x.json": true, "flix.toml": true, "README.md": true, "Makefile": true,
		"a.png": false, "local.mk": false, "Makefile.bak": false,
	} {
		if IsTokenTarget(name) != want {
			t.Errorf("%s: want %v", name, want)
		}
	}
}

type fakeSteps struct {
	calls []string
	fail  string
}

func (f *fakeSteps) do(name string) error {
	f.calls = append(f.calls, name)
	if name == f.fail {
		return errors.New("落ちました")
	}
	return nil
}
func (f *fakeSteps) Check(string) error        { return f.do("check") }
func (f *fakeSteps) Test(string) error         { return f.do("test") }
func (f *fakeSteps) LintFlixlint(string) error { return f.do("lint-flixlint") }
func (f *fakeSteps) RenderAll(string) error    { return f.do("render-all") }

type world struct {
	engine, game string
	steps        *fakeSteps
	git          []string
	synced       string
	linked       bool
	out          *strings.Builder
}

// bundleEngine は配った engine（go/ が無い）を 1 つ作る。
func bundleEngine(t *testing.T) string {
	t.Helper()
	e := t.TempDir()
	put(t, e, "Makefile", "VERSION := 0.9.0\n")
	put(t, e, "engine_full/artifact/engine_full.fpkg", "fpkg")
	put(t, e, "engine_full/flix.toml", "toml")
	put(t, e, "bin/fge-go", "fge-go-unix")
	put(t, e, "bin/fge-go.exe", "fge-go-windows")
	put(t, e, "lib/external/a.jar", "a")
	put(t, e, "lib/cache/https/x", "c")
	tpl := "templates/rpg-starter/"
	put(t, e, tpl+"flix.toml", `name = "__NAME__"`)
	put(t, e, tpl+"project.json", `{"title": "__TITLE__", "w": __W__, "ww": __WW__}`)
	put(t, e, tpl+"Makefile", "# __NAME__\n")
	put(t, e, tpl+"src/Main.flix", "// __H__ __WH__\n")
	put(t, e, tpl+"assets/__NAME__.sprite.json", `"__NAME__"`)
	put(t, e, tpl+"assets/x.png", "__NAME__")
	put(t, e, tpl+"AGENTS.local.md", "## この画面の画風\n\n本文\n")
	put(t, e, tpl+"new-game.exclude", "# 注釈\nsample-test\n")
	put(t, e, tpl+"sample-test/Town.flix", "x")
	for _, gen := range []string{"lib/cache/y", "build/z", "debug/d", "gallery/g.png", ".devbox/v", ".test-logs/l"} {
		put(t, e, tpl+gen, "gen")
	}
	if err := os.Chmod(filepath.Join(e, tpl, "Makefile"), 0o444); err != nil {
		t.Fatal(err)
	}
	return e
}

func newWorld(t *testing.T, engine string) *world {
	return &world{engine: engine, game: filepath.Join(t.TempDir(), "tide-pool"), steps: &fakeSteps{}, out: &strings.Builder{}}
}

func (w *world) deps() Deps {
	return Deps{
		Out: w.out, Steps: w.steps,
		Git: func(args ...string) error {
			w.git = append(w.git, strings.Join(args, " "))
			return os.MkdirAll(filepath.Join(w.game, ".git"), 0o755)
		},
		SyncAgents: func(engine, game, version string) error { w.synced = version; return nil },
		LinkCache:  func(string) string { w.linked = true; return "" },
		CacheDir:   func() string { return "/shared" },
	}
}

func (w *world) create(t *testing.T, goos string) error {
	t.Helper()
	return Create(Request{Engine: w.engine, Game: w.game, Name: "tide_pool", Template: "rpg-starter", GOOS: goos, GOARCH: "amd64", PackNote: true}, w.deps())
}

func TestCreateReplacesTokensWithDefaultSize(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	if err := w.create(t, "linux"); err != nil {
		t.Fatal(err)
	}
	if got := get(t, w.game, "project.json"); got != `{"title": "tide_pool", "w": 480, "ww": 960}` {
		t.Errorf("project.json: %s", got)
	}
	if got := get(t, w.game, "src/Main.flix"); got != "// 300 600\n" {
		t.Errorf("Main.flix: %s", got)
	}
}

func TestCreateLeavesBinaryFilesUntouched(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	if err := w.create(t, "linux"); err != nil {
		t.Fatal(err)
	}
	if got := get(t, w.game, "assets/x.png"); got != "__NAME__" {
		t.Errorf("絵を書き換えています: %s", got)
	}
}

func TestCreateRenamesNameAssets(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	if err := w.create(t, "linux"); err != nil {
		t.Fatal(err)
	}
	if got := get(t, w.game, "assets/tide_pool.sprite.json"); got != `"tide_pool"` {
		t.Errorf("got %s", got)
	}
}

func TestCreateDoesNotCarryGeneratedOrExcludedPaths(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	if err := w.create(t, "linux"); err != nil {
		t.Fatal(err)
	}
	for _, rel := range []string{"lib/cache/y", "build", "debug/d", "gallery/g.png", ".devbox", ".test-logs", "sample-test"} {
		if exists(w.game, rel) {
			t.Errorf("%s を運んでいます", rel)
		}
	}
	for _, rel := range []string{"gallery", "reference", "debug", "atelier", "new-game.exclude"} {
		if !exists(w.game, rel) {
			t.Errorf("%s がありません", rel)
		}
	}
}

func TestCreateMakesReadOnlyTemplateFilesWritable(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	if err := w.create(t, "linux"); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(w.game, "Makefile"))
	if err != nil || info.Mode().Perm()&0o200 == 0 {
		t.Errorf("Makefile が書けません: %v %v", info.Mode(), err)
	}
}

func TestCreateSeedsLibWithWritableEngineFull(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	if err := w.create(t, "linux"); err != nil {
		t.Fatal(err)
	}
	dest := "lib/github/ababup1192/flix_game_engine/0.9.0/"
	if get(t, w.game, dest+"flix_game_engine-0.9.0.fpkg") != "fpkg" || get(t, w.game, dest+"flix_game_engine-0.9.0.toml") != "toml" {
		t.Error("engine_full を写していません")
	}
	if get(t, w.game, "lib/external/a.jar") != "a" || get(t, w.game, "lib/cache/https/x") != "c" {
		t.Error("lib/external か lib/cache を写していません")
	}
}

func TestBundleEngineWritesNoLocalMk(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	if err := w.create(t, "linux"); err != nil {
		t.Fatal(err)
	}
	if exists(w.game, "local.mk") {
		t.Error("配った engine なのに local.mk を書いています")
	}
}

func TestCloneEngineWritesLocalMkAndUsesTheStoreEntry(t *testing.T) {
	e := bundleEngine(t)
	put(t, e, "go/go.mod", "module x\n")
	entry := filepath.Join(e, "build", "fpkg-store", "engine_full-0.9.0-abc")
	put(t, entry, "package.fpkg", "store-fpkg")
	put(t, entry, "flix.toml", "store-toml")
	if err := os.MkdirAll(filepath.Join(e, "build", "fpkg-store", "current"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(entry, filepath.Join(e, "build", "fpkg-store", "current", "engine_full")); err != nil {
		t.Fatal(err)
	}
	put(t, e, "bin/dist/fge-go-linux-amd64", "dist")
	w := newWorld(t, e)
	if err := w.create(t, "linux"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(get(t, w.game, "local.mk"), "ENGINE ?= "+filepath.ToSlash(e)+"\n") {
		t.Errorf("local.mk: %s", get(t, w.game, "local.mk"))
	}
	if get(t, w.game, "lib/github/ababup1192/flix_game_engine/0.9.0/flix_game_engine-0.9.0.fpkg") != "store-fpkg" {
		t.Error("置き場の束を写していません")
	}
	if get(t, w.game, "bin/fge-go") != "dist" {
		t.Error("組んだ bin/dist の fge-go を配っていません")
	}
}

func TestCreateInitsGitWithTheHooksPath(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	if err := w.create(t, "linux"); err != nil {
		t.Fatal(err)
	}
	want := "-C " + w.game + " init -q / -C " + w.game + " config core.hooksPath bin/githooks"
	if strings.Join(w.git, " / ") != want {
		t.Errorf("git: %v", w.git)
	}
}

func TestCreateSyncsAgentsWithTheEngineVersion(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	if err := w.create(t, "linux"); err != nil {
		t.Fatal(err)
	}
	if w.synced != "0.9.0" {
		t.Errorf("synced=%q", w.synced)
	}
}

func TestBirthChecksRunInOrder(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	if err := w.create(t, "linux"); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(w.steps.calls, ","); got != "check,test,lint-flixlint,render-all" {
		t.Errorf("順番: %s", got)
	}
}

func TestBirthCheckFailureStopsTheRest(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	w.steps.fail = "test"
	if err := w.create(t, "linux"); err == nil || !strings.Contains(err.Error(), "test") {
		t.Fatalf("err=%v", err)
	}
	if got := strings.Join(w.steps.calls, ","); got != "check,test" {
		t.Errorf("止まっていません: %s", got)
	}
}

func TestStyleNoteIsWrittenIntoAgentsLocal(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	if err := w.create(t, "linux"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(get(t, w.game, "AGENTS.local.md"), "（テンプレ rpg-starter の画風の仮置き。") {
		t.Error("画風の仮置きがありません")
	}
}

func TestUnixLinksTheSharedMavenCache(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	if err := w.create(t, "linux"); err != nil {
		t.Fatal(err)
	}
	if !w.linked {
		t.Error("lib/cache を共有の置き場へ張っていません")
	}
}

func TestWindowsDoesNotLinkTheMavenCache(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	if err := w.create(t, "windows"); err != nil {
		t.Fatal(err)
	}
	if w.linked {
		t.Error("Windows で lib/cache を張ろうとしています")
	}
}

func TestWindowsGetsTheExeFgeGo(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	if err := w.create(t, "windows"); err != nil {
		t.Fatal(err)
	}
	if get(t, w.game, "bin/fge-go.exe") != "fge-go-windows" {
		t.Error("fge-go.exe を配っていません")
	}
}

func TestWindowsNextStepsUseBinFge(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	if err := w.create(t, "windows"); err != nil {
		t.Fatal(err)
	}
	got := w.out.String()
	if !strings.Contains(got, "bin/fge run") || !strings.Contains(got, "bin/fge reference update") || strings.Contains(got, "make ") {
		t.Errorf("案内:\n%s", got)
	}
}

func TestExistingGameDirIsRefused(t *testing.T) {
	w := newWorld(t, bundleEngine(t))
	if err := os.MkdirAll(w.game, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := w.create(t, "linux"); err == nil || !strings.Contains(err.Error(), "既に存在します") {
		t.Errorf("err=%v", err)
	}
}

func TestValidateRefusesBadNamesAndSizes(t *testing.T) {
	e := bundleEngine(t)
	game := filepath.Join(t.TempDir(), "g")
	for _, r := range []Request{
		{Engine: e, Game: "rel/path", Name: "g"},
		{Engine: e, Game: game, Name: "Bad"},
		{Engine: e, Game: game, Name: "g", W: "12a"},
		{Engine: e, Game: game, Name: "g", Template: "Nope"},
		{Engine: e, Game: game, Name: "g", Template: "missing"},
	} {
		if _, err := Validate(r); err == nil {
			t.Errorf("通しています: %+v", r)
		}
	}
}

func TestBundleWithoutEngineFullIsRefused(t *testing.T) {
	e := bundleEngine(t)
	os.Remove(filepath.Join(e, "engine_full/artifact/engine_full.fpkg"))
	w := newWorld(t, e)
	if err := w.create(t, "linux"); err == nil || !strings.Contains(err.Error(), "欠けています") {
		t.Errorf("err=%v", err)
	}
}
