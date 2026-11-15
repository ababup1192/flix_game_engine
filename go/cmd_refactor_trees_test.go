package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flixlint/go/refactor"
)

const testEnginePrefix = "$pkg$github$owner$engine."

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// engine のルートの形（mk/game.mk・repository つきの flix.toml・src のある bench 1 本・src の無い bench 1 本・engine_web/src）。
func fakeEngine(t *testing.T) string {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "mk", "game.mk"), "")
	writeFile(t, filepath.Join(root, "flix.toml"), "[package]\nrepository  = \"github:owner/engine\"\n")
	writeFile(t, filepath.Join(root, "bench", "crowd", "flix.toml"), "")
	writeFile(t, filepath.Join(root, "bench", "crowd", "src", "Main.flix"), "")
	writeFile(t, filepath.Join(root, "bench", "common", "flix.toml"), "")
	writeFile(t, filepath.Join(root, "engine_web", "src", "WebFs.flix"), "")
	return root
}

// bench は src のある物だけがソースツリーになり、engine の名前の頭は flix.toml の repository から作る。
func TestRefactorTreesListsBenchWithSource(t *testing.T) {
	trees, _ := refactorTrees(fakeEngine(t))
	if len(trees) != 1 || trees[0].Name != "bench/crowd" || trees[0].EnginePrefix != testEnginePrefix {
		t.Errorf("got %+v", trees)
	}
}

// engine_web を組む生成物が無ければ、ソースツリーにせず見ていない事を 1 行で言う。
func TestRefactorTreesNotesMissingWebTree(t *testing.T) {
	_, notes := refactorTrees(fakeEngine(t))
	if len(notes) != 1 || !strings.Contains(notes[0], "make sync-engine-full-web") {
		t.Errorf("got %q", notes)
	}
}

// engine_web を組む生成物があれば、src/engine_web の下だけをこのソースツリーの物として engine_web/src へ置き換える。
func TestRefactorTreesMapsWebTreeToEngineWebSource(t *testing.T) {
	root := fakeEngine(t)
	writeFile(t, filepath.Join(root, webTreeDir, "flix.toml"), "")
	trees, _ := refactorTrees(root)
	web := trees[len(trees)-1]
	got, ok := web.mapFile("src/engine_web/WebFs.flix")
	_, copied := web.mapFile("src/engine/core/Vec2.flix")
	if !ok || got != "engine_web/src/WebFs.flix" || copied {
		t.Errorf("got %q %v %v", got, ok, copied)
	}
}

// engine のルートでなければ（ゲームのルート）ソースツリーは無い。
func TestRefactorTreesEmptyOutsideEngine(t *testing.T) {
	trees, notes := refactorTrees(t.TempDir())
	if trees != nil || notes != nil {
		t.Errorf("got %+v %q", trees, notes)
	}
}

// 値を取る旗の値を名前と取り違えない。
func TestParseTreeQuerySkipsFlagValues(t *testing.T) {
	q, ok := parseTreeQuery([]string{"search", "--kind", "def", "planOf"})
	if !ok || q.op != "search" || q.target != "planOf" || q.at != 3 {
		t.Errorf("got %+v %v", q, ok)
	}
}

// 欄の問いと、書き換える操作はソースツリーで引かない。
func TestParseTreeQueryRootOnlyOps(t *testing.T) {
	for _, rest := range [][]string{
		{"usages", "--label", "x", "--receiver", "World"},
		{"remove-dead", "--def", "A.f"},
		{"usages"},
	} {
		if _, ok := parseTreeQuery(rest); ok {
			t.Errorf("%q はルートだけのはず", rest)
		}
	}
}

// usages --unused は名前なしでソースツリーも見る。
func TestParseTreeQueryUnused(t *testing.T) {
	q, ok := parseTreeQuery([]string{"usages", "--unused"})
	if !ok || !q.unused {
		t.Errorf("got %+v %v", q, ok)
	}
}

// lib のあるソースツリー（treeGate は lib の無いソースツリーを問わない）。
func treeWithLib(t *testing.T, tr refactorTree) refactorTree {
	tr.Root = t.TempDir()
	if err := os.MkdirAll(filepath.Join(tr.Root, "lib"), 0o755); err != nil {
		t.Fatal(err)
	}
	return tr
}

var benchTree = refactorTree{Name: "bench/crowd", As: "bench/crowd/", EnginePrefix: testEnginePrefix}
var webTree = refactorTree{Name: "engine_web", Own: "src/engine_web/", As: "engine_web/src/", Resident: true}

func gateOf(run treeRun) treeGate {
	return treeGate{stamp: func(refactorTree) int64 { return 1 }, run: run}
}

func okRun(out string) treeRun {
	return func(_ refactorTree, _ []string) (string, string, int) { return out, "", 0 }
}

const benchUsage = `{"sym":"` + testEnginePrefix + `Scene3d.shaderHashOf","sites":[{"file":"src/Main.flix","line":3,"col":5,"owner":"Main.main","what":"call"}],"usage":{"sym":"x","kind":"def"}}`

// ルートが当てた名前は、fpkg で使うソースツリーにはルートの答えの完全な名前に engine の頭を付けて問う。
func TestAskTreePrefixesRootSymInBench(t *testing.T) {
	var asked []string
	run := func(_ refactorTree, rest []string) (string, string, int) { asked = rest; return benchUsage, "", 0 }
	q, _ := parseTreeQuery([]string{"usages", "shaderHashOf"})
	askTree(gateOf(run), treeWithLib(t, benchTree), []string{"usages", "shaderHashOf"}, q, "Scene3d.shaderHashOf")
	if asked[1] != testEnginePrefix+"Scene3d.shaderHashOf" {
		t.Errorf("got %q", asked)
	}
}

// ソースツリーの使われ所は engine のルートからの相対で、名前は頭を外して出す。
func TestAskTreeMapsBenchSites(t *testing.T) {
	q, _ := parseTreeQuery([]string{"usages", "Scene3d.shaderHashOf"})
	a, ok, _ := askTree(gateOf(okRun(benchUsage)), treeWithLib(t, benchTree), []string{"usages", "Scene3d.shaderHashOf"}, q, "Scene3d.shaderHashOf")
	if !ok || a.Sym != "Scene3d.shaderHashOf" || a.Sites[0].File != "bench/crowd/src/Main.flix" {
		t.Errorf("got %+v %v", a, ok)
	}
}

// engine_web のソースツリーで、engine の src の写し（Own の外）の使われ所はルートの答えと重なるので落とす。
func TestAskTreeDropsCopiesOutsideOwn(t *testing.T) {
	out := `{"sym":"A.f","sites":[{"file":"src/engine/A.flix","line":1,"col":1,"owner":"A.g","what":"call"},{"file":"src/engine_web/WebLayer.flix","line":9,"col":2,"owner":"WebLayer.go","what":"call"}],"usage":{"sym":"A.f","kind":"def","decl":"src/engine/A.flix:1:1"}}`
	q, _ := parseTreeQuery([]string{"usages", "A.f"})
	a, _, _ := askTree(gateOf(okRun(out)), treeWithLib(t, webTree), []string{"usages", "A.f"}, q, "A.f")
	if len(a.Sites) != 1 || a.Sites[0].File != "engine_web/src/WebLayer.flix" || a.Decl != "" {
		t.Errorf("got %+v", a)
	}
}

// show はルートが当てた名前ならソースツリーを見ない（engine_web の写しを 2 度出さない）。
func TestAskTreeSkipsShowWhenRootFound(t *testing.T) {
	called := false
	run := func(_ refactorTree, _ []string) (string, string, int) { called = true; return "{}", "", 0 }
	q, _ := parseTreeQuery([]string{"show", "A.f"})
	askTree(gateOf(run), treeWithLib(t, webTree), []string{"show", "A.f"}, q, "A.f")
	if called {
		t.Error("ソースツリーを問うた")
	}
}

const indexFailure = "refactor: 索引を作れません: flixlint が依存（lib/）を読めない（終了コード 4。上の出力）\nnext: make check（flix check が lib/ に依存を入れる）\n"

// 索引を作れなかったソースツリーは、flix.toml・lib・src が新しくならない限り 2 回目は問わない。
func TestTreeGateSkipsFailedTreeUntilItChanges(t *testing.T) {
	calls := 0
	run := func(_ refactorTree, _ []string) (string, string, int) { calls++; return "", indexFailure, 4 }
	g := treeGate{path: filepath.Join(t.TempDir(), "skip.json"), stamp: func(refactorTree) int64 { return 7 }, run: run}
	tr := treeWithLib(t, benchTree)
	g.ask(tr, []string{"search", "x"})
	g.ask(tr, []string{"search", "x"})
	if calls != 1 {
		t.Errorf("%d 回問うた", calls)
	}
}

// 2 回目に問わなかった時も、なぜ引いていないかを 1 行で言う。
func TestTreeGateNotesSkippedTree(t *testing.T) {
	run := func(_ refactorTree, _ []string) (string, string, int) { return "", indexFailure, 4 }
	g := treeGate{path: filepath.Join(t.TempDir(), "skip.json"), stamp: func(refactorTree) int64 { return 7 }, run: run}
	tr := treeWithLib(t, benchTree)
	g.ask(tr, []string{"search", "x"})
	_, _, note := g.ask(tr, []string{"search", "x"})
	if !strings.Contains(note, "前に索引を作れなかった") || !strings.Contains(note, "make check") {
		t.Errorf("got %q", note)
	}
}

// ソースツリーが新しくなったら（依存を入れた後）、もう 1 度問う。
func TestTreeGateAsksAgainAfterTreeChanges(t *testing.T) {
	calls := 0
	run := func(_ refactorTree, _ []string) (string, string, int) { calls++; return "", indexFailure, 4 }
	stamp := int64(7)
	g := treeGate{path: filepath.Join(t.TempDir(), "skip.json"), stamp: func(refactorTree) int64 { return stamp }, run: run}
	tr := treeWithLib(t, benchTree)
	g.ask(tr, []string{"search", "x"})
	stamp = 8
	g.ask(tr, []string{"search", "x"})
	if calls != 2 {
		t.Errorf("%d 回問うた", calls)
	}
}

// lib の無いソースツリーは flixlint を起こさず、make check で依存を入れる事を言う。
func TestTreeGateDoesNotRunTreeWithoutLib(t *testing.T) {
	called := false
	run := func(_ refactorTree, _ []string) (string, string, int) { called = true; return "", "", 0 }
	tr := benchTree
	tr.Root = t.TempDir()
	_, _, note := gateOf(run).ask(tr, []string{"search", "x"})
	if called || !strings.Contains(note, "make check") {
		t.Errorf("called=%v note=%q", called, note)
	}
}

func refactorWith(runRoot func([]string) (string, string, int), run treeRun) treeRefactor {
	return treeRefactor{runRoot: runRoot, gate: gateOf(run)}
}

// ルートに無い名前をソースツリーで当てたら 0 で終わり、ルートの「0 件」は出さない。
func TestTreeRefactorFoundOnlyInTree(t *testing.T) {
	runRoot := func(_ []string) (string, string, int) { return "search runFileRead: 0 件\n", "", 1 }
	out := `{"found":[{"sym":"WebFs.runFileRead","kind":"def","file":"src/engine_web/WebFs.flix","line":20,"pub":true}]}`
	rest := []string{"search", "runFileRead"}
	q, _ := parseTreeQuery(rest)
	var o, e strings.Builder
	code := refactorWith(runRoot, okRun(out)).run(&o, &e, rest, false, q, []refactorTree{treeWithLib(t, webTree)}, nil)
	if code != 0 || strings.Contains(o.String(), "0 件") || !strings.Contains(o.String(), "engine_web/src/WebFs.flix:20") {
		t.Errorf("code=%d out=%q err=%q", code, o.String(), e.String())
	}
}

// ルートが「索引にありません」以外で落ちたら、ルートの誤りと終了コードがそのまま残り、ソースツリーは問わない。
func TestTreeRefactorKeepsRootFailure(t *testing.T) {
	runRoot := func(_ []string) (string, string, int) {
		return "", "refactor: 索引（resolved）を作れません: ソースがコンパイルできない\n", 2
	}
	called := false
	run := func(_ refactorTree, _ []string) (string, string, int) { called = true; return "{}", "", 0 }
	rest := []string{"usages", "A.f"}
	q, _ := parseTreeQuery(rest)
	var o, e strings.Builder
	code := refactorWith(runRoot, run).run(&o, &e, rest, false, q, []refactorTree{treeWithLib(t, benchTree)}, nil)
	if code != 2 || called || !strings.Contains(e.String(), "コンパイルできない") {
		t.Errorf("code=%d called=%v err=%q", code, called, e.String())
	}
}

// --max の歯止めで落ちたルートの終了コードは変わらない。
func TestTreeRefactorKeepsMaxExitCode(t *testing.T) {
	runRoot := func(_ []string) (string, string, int) {
		return "usages Scene3d.material（def）\n  27 か所\n", "", 1
	}
	rest := []string{"usages", "Scene3d.material", "--max", "1"}
	q, _ := parseTreeQuery(rest)
	var o, e strings.Builder
	code := refactorWith(runRoot, okRun(benchUsage)).run(&o, &e, rest, false, q, []refactorTree{treeWithLib(t, benchTree)}, nil)
	if code != 1 || !strings.Contains(o.String(), "27 か所") {
		t.Errorf("code=%d out=%q", code, o.String())
	}
}

// ソースツリーへ渡す問いからは --max を外す。
func TestTreeRefactorDropsMaxForTrees(t *testing.T) {
	runRoot := func(_ []string) (string, string, int) { return `{"sym":"A.f"}`, "", 0 }
	var asked []string
	run := func(_ refactorTree, rest []string) (string, string, int) { asked = rest; return "{}", "", 0 }
	rest := []string{"usages", "A.f", "--max", "5"}
	q, _ := parseTreeQuery(rest)
	var o, e strings.Builder
	refactorWith(runRoot, run).run(&o, &e, rest, false, q, []refactorTree{treeWithLib(t, benchTree)}, nil)
	if hasAnyArg(asked, "--max") || asked[1] != testEnginePrefix+"A.f" {
		t.Errorf("got %q", asked)
	}
}

// --json ではルートの答えの鍵の順のまま、終わりに trees を足す。
func TestTreeRefactorAppendsTreesToRootJSON(t *testing.T) {
	runRoot := func(_ []string) (string, string, int) {
		return `{"op":"search","found":[{"sym":"A.planOf","kind":"def","file":"src/A.flix","line":1}]}` + "\n", "", 0
	}
	out := `{"found":[{"sym":"BenchRun.planOf","kind":"def","file":"src/BenchRun.flix","line":16}]}`
	rest := []string{"search", "planOf", "--json"}
	q, _ := parseTreeQuery(rest)
	var o, e strings.Builder
	refactorWith(runRoot, okRun(out)).run(&o, &e, rest, true, q, []refactorTree{treeWithLib(t, benchTree)}, nil)
	if !strings.HasPrefix(o.String(), `{"op":"search","found":`) || !strings.Contains(o.String(), `"trees":[{"tree":"bench/crowd"`) {
		t.Errorf("got %q", o.String())
	}
}

// ソースツリーの一覧もルートと同じ件数で切り、残りの数を言う。
func TestRenderTreeAnswersCutsAtLimit(t *testing.T) {
	var sites []refactor.UsageSite
	for i := 0; i < 12; i++ {
		sites = append(sites, refactor.UsageSite{File: "bench/a/src/M.flix", Line: i + 1, Col: 1, Owner: "M.f", What: "call"})
	}
	var b strings.Builder
	q, _ := parseTreeQuery([]string{"usages", "A.f"})
	renderTreeAnswers(&b, q, []treeAnswer{{Tree: "bench/a", Sym: "A.f", Sites: sites}}, 10)
	if strings.Count(b.String(), "M.flix") != 10 || !strings.Contains(b.String(), "ほか 2 件") {
		t.Errorf("got %q", b.String())
	}
}

// ソースツリーの参照は engine の名前ごとに数え、中の自分の名前（頭の無い物）と再帰は数えない。
func TestTreeRefsCountsEngineNamesOnly(t *testing.T) {
	rows := []refactor.Row{
		{Kind: refactor.KindDefUse, File: "src/Main.flix", Line: 1, Col: 1, Sym: testEnginePrefix + "App.go", Owner: "Main.main"},
		{Kind: refactor.KindDefUse, File: "src/Main.flix", Line: 2, Col: 1, Sym: "BenchRun.planOf", Owner: "Main.main"},
		{Kind: refactor.KindDefUse, File: "src/Main.flix", Line: 3, Col: 1, Sym: "Main.main", Owner: "Main.main"},
	}
	got := treeRefs(benchTree, rows)
	if len(got) != 1 || got["App.go"][0] != "bench/crowd/src/Main.flix:1:1" {
		t.Errorf("got %v", got)
	}
}

// --unused の候補のうち、ソースツリーから使われている物だけを名前つきで返す。
func TestUsedInTreesPicksCandidatesUsedByTrees(t *testing.T) {
	cands := map[string]string{"src/A.flix:3": "A.used", "src/A.flix:9": "A.unused"}
	refs := map[string]map[string][]string{"bench/crowd": {"A.used": {"bench/crowd/src/Main.flix:1:1"}}}
	got := usedInTrees(cands, refs, []string{"bench/crowd"})
	if len(got) != 1 || got[0].Sym != "A.used" || got[0].Tree != "bench/crowd" {
		t.Errorf("got %+v", got)
	}
}

// 字の --unused の一覧（last-usages.txt）から def の候補だけを拾う（use の行は拾わない）。
func TestUnusedCandidatesFromListSkipsUses(t *testing.T) {
	list := "engine/test/T.flix:10:1      use java.awt.image.BufferedImage   使っていない use\n" +
		"src/engine/core/Anchor.flix:35:13   Anchor.fromString   参照 0\n"
	got := unusedCandidatesFromList(strings.NewReader(list))
	if len(got) != 1 || got["src/engine/core/Anchor.flix:35"] != "Anchor.fromString" {
		t.Errorf("got %v", got)
	}
}

// --json の --unused の候補は def だけ。
func TestUnusedCandidatesFromJSONKeepsDefs(t *testing.T) {
	out := `{"sites":[{"file":"src/A.flix","line":3,"col":5,"sym":"A.f","what":"def"},{"file":"src/A.flix","line":1,"col":1,"sym":"X","what":"use"}]}`
	got := unusedCandidatesFromJSON(out)
	if len(got) != 1 || got["src/A.flix:3"] != "A.f" {
		t.Errorf("got %v", got)
	}
}

// 空の object にも鍵を足せる。
func TestAppendJSONKeyToEmptyObject(t *testing.T) {
	if got := appendJSONKey("{}\n", "k", 1); got != `{"k":1}`+"\n" {
		t.Errorf("got %q", got)
	}
}

// engine の各パッケージの test は、ルートの索引の sources と testDirs の両方に入っている（新しいパッケージの test を足し忘れない）。
func TestEngineRefactorConfigListsPackageTests(t *testing.T) {
	root := filepath.Join("..")
	// WhyNot: refactor.LoadConfig で読まない。手元の refactor.local.json（git に入らない）が sources を替えると、配る方の欠けが隠れる。
	b, err := os.ReadFile(filepath.Join(root, "bin", "lint-rules", "refactor.json"))
	if err != nil {
		t.Fatal(err)
	}
	var c refactor.Config
	if err := json.Unmarshal(b, &c); err != nil {
		t.Fatal(err)
	}
	tests, _ := filepath.Glob(filepath.Join(root, "*", "test"))
	for _, dir := range tests {
		rel := filepath.Base(filepath.Dir(dir)) + "/test"
		if _, err := os.Stat(filepath.Join(filepath.Dir(dir), "flix.toml")); err != nil {
			continue
		}
		if !contains(c.Sources, rel) || !contains(c.TestDirs, rel) {
			t.Errorf("%s が sources %q・testDirs %q に無い", rel, c.Sources, c.TestDirs)
		}
	}
}

func contains(xs []string, x string) bool {
	for _, y := range xs {
		if y == x {
			return true
		}
	}
	return false
}
