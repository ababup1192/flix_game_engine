package testselect

import (
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/gates"
)

// fakeEnv は go list と fpkg を引かない Env。
type fakeEnv struct {
	importers map[string][]string
	execs     []string
	stale     bool
}

func (e fakeEnv) GoImporters(names []string) ([]string, error) {
	out := map[string]bool{}
	for _, n := range names {
		out[n] = true
		for _, up := range e.importers[n] {
			out[up] = true
		}
	}
	return sortedKeys(out), nil
}

func (e fakeEnv) GoExecPkgs() ([]string, error) { return e.execs, nil }

func (e fakeEnv) GoAllPkgs() ([]string, error) { return []string{".", "gates", "precommit", "px", "tape"}, nil }

func (e fakeEnv) FpkgStale() (bool, string) {
	if e.stale {
		return true, "engine_full の fpkg が古い"
	}
	return false, ""
}

var env = fakeEnv{importers: map[string][]string{"precommit": {".", "gates", "testselect"}}, execs: []string{".", "precommit", "tape"}}

func table(t *testing.T) *Table {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	f, err := gates.Load(root)
	if err != nil {
		t.Fatal(err)
	}
	return NewTable(f)
}

func plan(t *testing.T, e Env, opt Options, changes ...Change) *Plan {
	t.Helper()
	p, err := Select(table(t), changes, e, ByFeeds, opt)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func files(paths ...string) []Change {
	var out []Change
	for _, p := range paths {
		out = append(out, Change{Path: p})
	}
	return out
}

// lines は流す門を make の行の形で並べる（並びは名前の順）。
func lines(p *Plan) []string {
	var out []string
	for _, l := range p.Run {
		out = append(out, l.Display())
	}
	sort.Strings(out)
	return out
}

func ids(list []Line) []string {
	var out []string
	for _, l := range list {
		out = append(out, l.ID)
	}
	sort.Strings(out)
	return out
}

func runIDs(p *Plan) []string { return ids(p.Run) }

func has(list []string, want ...string) bool {
	set := map[string]bool{}
	for _, x := range list {
		set[x] = true
	}
	for _, w := range want {
		if !set[w] {
			return false
		}
	}
	return true
}

func hasVar(p *Plan, id, key, want string) bool {
	for _, l := range p.Run {
		if l.ID == id {
			return l.Vars[key] == want
		}
	}
	return false
}

func eq(t *testing.T, got, want []string) {
	t.Helper()
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("got:\n  %s\nwant:\n  %s", strings.Join(got, "\n  "), strings.Join(want, "\n  "))
	}
}

const filesFrom = "build/test-select/files.txt"

// T1 文書だけは precommit の素振りと配線の検査だけ。
func TestDocsOnlyRunsPrecommitAndDocsSync(t *testing.T) {
	p := plan(t, env, Options{FilesFrom: filesFrom}, files("docs/x.md", "plans/y.md")...)
	eq(t, lines(p), []string{"make check-docs-sync", "make precommit-dry FILES_FROM=" + filesFrom})
}

// T1 文書だけでは画面を開く門も手で流す門も選ばない。
func TestDocsOnlySelectsNoHeldGates(t *testing.T) {
	p := plan(t, env, Options{}, files("docs/x.md")...)
	if len(p.GUI)+len(p.Hold) != 0 {
		t.Errorf("gui %v hold %v", ids(p.GUI), ids(p.Hold))
	}
}

// T2 rpg-starter の src は、そのテンプレートのテストと門だけで、engine 側も go のテストも流さない。
func TestTemplateSrcRunsOnlyThatTemplate(t *testing.T) {
	p := plan(t, env, Options{FilesFrom: filesFrom}, files("templates/rpg-starter/src/Battle.flix")...)
	eq(t, lines(p), []string{
		"make check-docs-sync",
		"make lint",
		"make lint ONLY=template-rules",
		"make precommit-dry FILES_FROM=" + filesFrom,
		"make render-all",
		"make test JOBS=1 PKGS=rpg-starter",
	})
}

// T2 の画面を開く門は rpg-starter が使う 4 本で、別の欄に出る。
func TestTemplateSrcListsItsGUIGates(t *testing.T) {
	p := plan(t, env, Options{}, files("templates/rpg-starter/src/Battle.flix")...)
	eq(t, ids(p.GUI), []string{"determinism", "gl-capture-check", "smoke-devtools", "webgpu-v1-check-web"})
}

// T3 engine_world の src は engine と他の 2 層を流さず、下流のテンプレート・bench・game-starter を全部流す。
func TestEngineWorldSrcSkipsOtherLayers(t *testing.T) {
	p := plan(t, env, Options{FilesFrom: filesFrom}, files("engine_world/src/Timeline.flix")...)
	eq(t, lines(p), []string{
		"make check",
		"make check-docs-sync",
		"make check-pkgs DIRS='bench/crowd2d bench/gl_parity bench/scene3d bench/shader_cache_soak bench/sprite_stress bench/texture_upload bench/webgpu_check bench/webgpu_v1 bench/webgpu_v2'",
		"make gl-parity",
		"make go-test FRESH=.,precommit PKG=apidigest,apiindex,apireleased,docrefs,f32,fallback,flixdecl,forbid,headlessrun,quadratic",
		"make lint",
		"make lint ONLY=template-rules",
		"make new-game-check",
		"make precommit-dry FILES_FROM=" + filesFrom,
		"make refactor-smoke",
		"make render-all",
		"make sync-engine-full",
		"make sync-engine-full-web",
		"make test JOBS=6 PKGS='engine_world hd2d-starter hd2d_town rpg-starter sound-novel-starter tidepool-starter'",
	})
}

// T3 で手で流す門（外のリポ・基準の版）は理由つきで別の欄に出る。
func TestEngineWorldSrcHoldsExternalGates(t *testing.T) {
	p := plan(t, env, Options{}, files("engine_world/src/Timeline.flix")...)
	eq(t, ids(p.Hold), []string{"baseline-check", "check-external", "studio-parity"})
}

// T4 render_gl の WGSL を持つ src は、render_gl のテストと下流（T3 の engine_world を render_gl に替えた形）。
func TestRenderGlWgslRunsRenderGlAndDownstream(t *testing.T) {
	p := plan(t, env, Options{}, files("render_gl/src/Render3dWgsl.flix")...)
	if !hasVar(p, "test", "PKGS", "hd2d-starter hd2d_town render_gl rpg-starter sound-novel-starter tidepool-starter") || !has(runIDs(p), "gl-parity", "sync-engine-full") {
		t.Errorf("run %v", lines(p))
	}
}

// PKG と FRESH は重ならない（exec を持つ物は -count=1 の 1 回だけ）。
func TestGoTestDoesNotRunFreshTwice(t *testing.T) {
	p := plan(t, env, Options{}, files("go/internal/precommit/precommit.go")...)
	if !hasVar(p, "go-test", "PKG", "gates,testselect") || !hasVar(p, "go-test", "FRESH", ".,precommit") {
		t.Errorf("run %v", lines(p))
	}
}

// T5 go の 1 パッケージは、そのパッケージと頼る側の go のテスト・go-build・いつもの門だけ。
func TestGoPackageRunsGoTestOfDependents(t *testing.T) {
	p := plan(t, env, Options{FilesFrom: filesFrom}, files("go/internal/precommit/precommit.go")...)
	eq(t, lines(p), []string{
		"make check-docs-sync",
		"make go-build",
		"make go-test FRESH=.,precommit PKG=gates,testselect",
		"make lint",
		"make precommit-dry FILES_FROM=" + filesFrom,
	})
}

// prereq の門が先・安い確かめ・テストの順に並ぶ。
func TestRunIsOrderedPrereqFirst(t *testing.T) {
	p := plan(t, env, Options{}, files("engine_world/src/Timeline.flix")...)
	if p.Run[0].ID != "sync-engine-full" || p.Run[1].ID != "check" {
		t.Errorf("頭が %s %s", p.Run[0].ID, p.Run[1].ID)
	}
}

// 安全側: 持ち主の無い配線（根の Makefile・mk・bin の sh・.github・根の lib・devbox）は全部。
func TestRootWiringSelectsEverything(t *testing.T) {
	for _, f := range []string{"Makefile", "mk/game.mk", "bin/determinism.sh", "bin/fge", ".github/workflows/release.yml", "lib/x.jar", "devbox.json", "flix.toml"} {
		p := plan(t, env, Options{}, files(f)...)
		if len(p.AllBecause) == 0 || !has(runIDs(p), "test", "check-pkgs", "go-test", "go-build", "render-all", "gl-parity", "new-game-check") || !hasVar(p, "go-test", "PKG", "gates,px") {
			t.Errorf("%s: all=%v run=%v", f, p.AllBecause, runIDs(p))
		}
	}
}

// 安全側: 全部の時のテストは全パッケージ。
func TestEverythingTestsAllPackages(t *testing.T) {
	p := plan(t, env, Options{}, files("Makefile")...)
	if !hasVar(p, "test", "PKGS", "engine engine_tools engine_world hd2d-starter hd2d_town render_gl rpg-starter sound-novel-starter tidepool-starter") {
		t.Errorf("run %v", lines(p))
	}
}

// 安全側: 持ち主のある配線（テンプレートの Makefile）はそのパッケージと下流で、全部にはしない。
func TestOwnedWiringRunsThatPackage(t *testing.T) {
	p := plan(t, env, Options{}, files("templates/rpg-starter/Makefile")...)
	if len(p.AllBecause) != 0 || !hasVar(p, "test", "PKGS", "rpg-starter") {
		t.Errorf("all=%v run=%v", p.AllBecause, lines(p))
	}
}

// 安全側: 持ち主の無いファイルは全部。
func TestUnownedFileSelectsEverything(t *testing.T) {
	p := plan(t, env, Options{}, files("somewhere/new.txt")...)
	if len(p.AllBecause) != 1 || p.Files[0].Kind != KindUnowned {
		t.Errorf("all=%v kind=%s", p.AllBecause, p.Files[0].Kind)
	}
}

// flix.toml の version の行だけの差は sync-engine-full だけ（全部にしない）。
func TestVersionOnlyTomlRunsSyncOnly(t *testing.T) {
	p := plan(t, env, Options{}, Change{Path: "engine/flix.toml", VersionOnly: true})
	if len(p.AllBecause) != 0 || !has(runIDs(p), "sync-engine-full") || has(runIDs(p), "test") {
		t.Errorf("all=%v run=%v", p.AllBecause, runIDs(p))
	}
}

// flix.toml の version 以外の差（--files で見えない時も）はそのパッケージと下流の全部。
func TestTomlOtherThanVersionRunsDownstream(t *testing.T) {
	p := plan(t, env, Options{}, files("engine/flix.toml")...)
	if !hasVar(p, "test", "PKGS", "engine engine_tools engine_world hd2d-starter hd2d_town render_gl rpg-starter sound-novel-starter tidepool-starter") {
		t.Errorf("run %v", lines(p))
	}
}

// engine/test だけの差は engine のテストだけで、下流へ伝えない。
func TestEngineTestStaysLocal(t *testing.T) {
	p := plan(t, env, Options{}, files("engine/test/TestColor.flix")...)
	if !hasVar(p, "test", "PKGS", "engine") || has(runIDs(p), "sync-engine-full", "render-all") {
		t.Errorf("run %v", lines(p))
	}
}

// engine/test/data は render_gl が読むので render_gl のテストも流す。
func TestEngineTestDataIsReadByRenderGl(t *testing.T) {
	p := plan(t, env, Options{}, files("engine/test/data/textured_two_materials.glb")...)
	if !hasVar(p, "test", "PKGS", "engine render_gl") {
		t.Errorf("run %v", lines(p))
	}
}

// game-starter のフォントは symlink で読む hd2d_town のテストと scene3d・sprite_stress の型検査も流す。
func TestGameStarterFontReachesBenches(t *testing.T) {
	p := plan(t, env, Options{}, files("templates/game-starter/assets/Xolonium-Regular.ttf")...)
	if !hasVar(p, "test", "PKGS", "engine_tools hd2d_town render_gl") || !hasVar(p, "check-pkgs", "DIRS", "bench/scene3d bench/sprite_stress") {
		t.Errorf("run %v", lines(p))
	}
}

// bench/scene3d の差は写しを持つ webgpu_v2 へも伝える。
func TestScene3dFeedsWebgpuV2(t *testing.T) {
	p := plan(t, env, Options{}, files("bench/scene3d/src/Room.flix")...)
	if !hasVar(p, "check-pkgs", "DIRS", "bench/scene3d bench/webgpu_v2") {
		t.Errorf("run %v", lines(p))
	}
}

// testdata の .md は文書でなく素材（go のテストが読む）。
func TestTestdataMarkdownIsMaterial(t *testing.T) {
	p := plan(t, env, Options{}, files("testdata/lint/x/overlay/AGENTS.core.md")...)
	if p.Files[0].Kind == KindDocs || !has(runIDs(p), "go-test") {
		t.Errorf("kind=%s run=%v", p.Files[0].Kind, runIDs(p))
	}
}

// docs の schema は px の go のテストが読む。
func TestDocsSchemaRunsPxTest(t *testing.T) {
	p := plan(t, env, Options{}, files("docs/pxsrc.schema.json")...)
	if !hasVar(p, "go-test", "PKG", "apidigest,hooks,px") {
		t.Errorf("run %v", lines(p))
	}
}

// plans/tape の .md は tape の go のテストだけを流す。
func TestTapePlanMarkdownRunsTapeTest(t *testing.T) {
	p := plan(t, env, Options{}, files("plans/tape/spec-wide.md")...)
	if !hasVar(p, "go-test", "PKG", "") || !hasVar(p, "go-test", "FRESH", "tape") {
		t.Errorf("run %v", lines(p))
	}
}

// 根の debug/ の追跡していない物は門を持たない（全部にしない）。
func TestDebugIsInert(t *testing.T) {
	p := plan(t, env, Options{}, files("debug/notes.txt")...)
	eq(t, runIDs(p), []string{"check-docs-sync", "lint", "precommit-dry"})
}

// go.mod は go のテストの全部（PKG を付けず、exec を持つ物は全部 FRESH）。
func TestGoModRunsAllGoTests(t *testing.T) {
	p := plan(t, env, Options{}, files("go/go.mod")...)
	if !hasVar(p, "go-test", "PKG", "gates,px") || !hasVar(p, "go-test", "FRESH", ".,precommit,tape") {
		t.Errorf("run %v", lines(p))
	}
}

// go:embed の素材は置き場のパッケージのテストを流す。
func TestGoEmbedAssetRunsItsPackage(t *testing.T) {
	p := plan(t, env, Options{}, files("go/internal/tape/template.html")...)
	if !hasVar(p, "go-test", "FRESH", "tape") {
		t.Errorf("run %v", lines(p))
	}
}

// 消したファイルも差に数える（消した src の下流を流す）。
func TestDeletedFileCounts(t *testing.T) {
	p := plan(t, env, Options{}, Change{Path: "templates/tidepool-starter/src/Old.flix", Deleted: true})
	if !hasVar(p, "test", "PKGS", "tidepool-starter") {
		t.Errorf("run %v", lines(p))
	}
}

// fpkg が古い時は、差分に engine 側が無くてもテンプレートの前に sync-engine-full。
func TestStaleFpkgAddsSync(t *testing.T) {
	stale := env
	stale.stale = true
	p := plan(t, stale, Options{}, files("templates/tidepool-starter/src/Main.flix")...)
	if p.Run[0].ID != "sync-engine-full" {
		t.Errorf("run %v", runIDs(p))
	}
}

// --gui の時は画面を開く門も流す並びに入る。
func TestGUIOptionRunsGUIGates(t *testing.T) {
	p := plan(t, env, Options{GUI: true}, files("templates/sound-novel-starter/src/Main.flix")...)
	if !has(runIDs(p), "determinism", "gl-capture-check") || len(p.NotRun(true)) != 1 {
		t.Errorf("run %v notRun %v", runIDs(p), p.NotRun(true))
	}
}

// 配線の検査の全部を流す時は、名前ごとの docs-sync:* を落とす。
func TestCheckDocsSyncCoversNamedChecks(t *testing.T) {
	p := plan(t, env, Options{}, files("Makefile")...)
	for _, id := range runIDs(p) {
		if strings.HasPrefix(id, "docs-sync:") {
			t.Errorf("覆われた %s が残る", id)
		}
	}
}

// 差分が無ければ何も流さない。
func TestNoChangesRunsNothing(t *testing.T) {
	if p := plan(t, env, Options{}); len(p.Run) != 0 {
		t.Errorf("run %v", runIDs(p))
	}
}

// 本物の表は CheckTable を通る（パッケージの id・feeds・門・go の表）。
func TestRealTableHasNoStructuralErrors(t *testing.T) {
	tb := table(t)
	root, _ := filepath.Abs(filepath.Join("..", "..", ".."))
	if errs := CheckTable(root, tb, nil, nil, nil); len(errs) != 0 {
		t.Errorf("errs %v", errs)
	}
}

// feeds の輪を見つける。
func TestCheckTableFindsFeedCycle(t *testing.T) {
	tb := NewTable(&gates.File{Packages: []gates.Package{{ID: "a", Dir: "a/", Feeds: []string{"b"}}, {ID: "b", Dir: "b/", Feeds: []string{"a"}}}})
	if errs := CheckTable(t.TempDir(), tb, nil, nil, nil); !strings.Contains(strings.Join(errs, "\n"), "輪") {
		t.Errorf("errs %v", errs)
	}
}

// 別のパッケージを指す symlink は reads か feeds に要る。
func TestCheckTableWantsReadsForCrossLinks(t *testing.T) {
	tb := NewTable(&gates.File{Packages: []gates.Package{{ID: "a", Dir: "a/"}, {ID: "b", Dir: "b/"}}})
	errs := CheckTable(t.TempDir(), tb, nil, nil, map[string]string{"a/x.ttf": "b/x.ttf"})
	if !strings.Contains(strings.Join(errs, "\n"), "a/x.ttf") {
		t.Errorf("errs %v", errs)
	}
}

// パッケージに持たれた門の input が dir の中に当たると止める。
func TestCheckTableRejectsOwnedGateInputInsidePackage(t *testing.T) {
	f := &gates.File{
		Packages: []gates.Package{{ID: "a", Dir: "a/", Gates: []string{"g"}}},
		Gates:    []gates.Gate{{ID: "g", Make: "g", Select: "package"}},
	}
	f.Gates[0].Input = &f.Wiring
	f.Wiring.Prefixes = []string{"a/"}
	errs := CheckTable(t.TempDir(), NewTable(f), nil, []string{"a/x.flix"}, nil)
	if !strings.Contains(strings.Join(errs, "\n"), "パッケージに持たれた門の input") {
		t.Errorf("errs %v", errs)
	}
}

// webgpu_v2 は gl_parity と webgpu_v1 の src を木へ写すので、その差も webgpu_v2 の型検査へ伝える。
func TestGlParitySrcFeedsWebgpuV2(t *testing.T) {
	p := plan(t, env, Options{}, files("bench/gl_parity/src/BillboardShadowYard.flix")...)
	if !hasVar(p, "check-pkgs", "DIRS", "bench/gl_parity bench/webgpu_v2") {
		t.Errorf("run %v", lines(p))
	}
}

// version の行だけの差は version 扱い。
func TestVersionOnlyDiffAcceptsVersionLines(t *testing.T) {
	if !VersionOnlyDiff("--- a/flix.toml\n+++ b/flix.toml\n@@ -2 +2 @@\n-version     = \"0.1.0\"\n+version     = \"0.2.0\"\n") {
		t.Error("version の行が version 扱いにならない")
	}
}

// 依存の行（{ version = … }）は version に数えない。
func TestVersionOnlyDiffRejectsDependencyLines(t *testing.T) {
	if VersionOnlyDiff("@@ -9 +9 @@\n-\"x\" = { version = \"0.1\" }\n+\"x\" = { version = \"0.2\" }\n") {
		t.Error("依存の行を version に数えた")
	}
}
