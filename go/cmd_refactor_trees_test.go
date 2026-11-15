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

// engine の根の形（mk/game.mk・repository つきの flix.toml・src のある bench 1 本・src の無い bench 1 本・engine_web/src）。
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

// bench は src のある物だけが木になり、engine の名前の頭は flix.toml の repository から作る。
func TestRefactorTreesListsBenchWithSource(t *testing.T) {
	trees, _ := refactorTrees(fakeEngine(t))
	if len(trees) != 1 || trees[0].Name != "bench/crowd" || trees[0].EnginePrefix != testEnginePrefix {
		t.Errorf("got %+v", trees)
	}
}

// engine_web を組む生成物が無ければ、木にせず見ていない事を 1 行で言う。
func TestRefactorTreesNotesMissingWebTree(t *testing.T) {
	_, notes := refactorTrees(fakeEngine(t))
	if len(notes) != 1 || !strings.Contains(notes[0], "make sync-engine-full-web") {
		t.Errorf("got %q", notes)
	}
}

// engine_web を組む生成物があれば、src/engine_web の下だけをこの木の物として engine_web/src へ置き換える。
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

// engine の根でなければ（ゲームの根）木は無い。
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

// 欄の問いと、書き換える操作は木で引かない。
func TestParseTreeQueryRootOnlyOps(t *testing.T) {
	for _, rest := range [][]string{
		{"usages", "--label", "x", "--receiver", "World"},
		{"remove-dead", "--def", "A.f"},
		{"usages"},
	} {
		if _, ok := parseTreeQuery(rest); ok {
			t.Errorf("%q は根だけのはず", rest)
		}
	}
}

// usages --unused は名前なしで木も見る。
func TestParseTreeQueryUnused(t *testing.T) {
	q, ok := parseTreeQuery([]string{"usages", "--unused"})
	if !ok || !q.unused {
		t.Errorf("got %+v %v", q, ok)
	}
}

var benchTree = refactorTree{Name: "bench/crowd", Root: "/e/bench/crowd", As: "bench/crowd/", EnginePrefix: testEnginePrefix}
var webTree = refactorTree{Name: "engine_web", Root: "/e/build/engine_full_web", Own: "src/engine_web/", As: "engine_web/src/", Resident: true}

// 根が当てた名前は、fpkg で使う木には engine の頭を付けて問う（木の中の同じ名前の別物を拾わない）。
func TestAskTreePrefixesEngineNameInBench(t *testing.T) {
	var asked []string
	run := func(_ refactorTree, rest []string) (string, int) {
		asked = rest
		return `{"sym":"` + testEnginePrefix + `App.go","sites":[{"file":"src/Main.flix","line":3,"col":5,"owner":"Main.main","what":"call"}],"usage":{"sym":"x","kind":"def"}}`, 0
	}
	q, _ := parseTreeQuery([]string{"usages", "App.go"})
	askTree(benchTree, []string{"usages", "App.go"}, q, true, run)
	if asked[1] != testEnginePrefix+"App.go" {
		t.Errorf("got %q", asked)
	}
}

// 木の使われ所は engine の根からの相対で、名前は頭を外して出す。
func TestAskTreeMapsBenchSites(t *testing.T) {
	run := func(_ refactorTree, _ []string) (string, int) {
		return `{"sym":"` + testEnginePrefix + `App.go","sites":[{"file":"src/Main.flix","line":3,"col":5,"owner":"Main.main","what":"call"}],"usage":{"sym":"x","kind":"def"}}`, 0
	}
	q, _ := parseTreeQuery([]string{"usages", "App.go"})
	a, ok := askTree(benchTree, []string{"usages", "App.go"}, q, true, run)
	if !ok || a.Sym != "App.go" || a.Sites[0].File != "bench/crowd/src/Main.flix" {
		t.Errorf("got %+v %v", a, ok)
	}
}

// engine_web の木で、engine の src の写し（Own の外）の使われ所は根の答えと重なるので落とす。
func TestAskTreeDropsCopiesOutsideOwn(t *testing.T) {
	run := func(_ refactorTree, _ []string) (string, int) {
		return `{"sym":"A.f","sites":[{"file":"src/engine/A.flix","line":1,"col":1,"owner":"A.g","what":"call"},{"file":"src/engine_web/WebLayer.flix","line":9,"col":2,"owner":"WebLayer.go","what":"call"}],"usage":{"sym":"A.f","kind":"def","decl":"src/engine/A.flix:1:1"}}`, 0
	}
	q, _ := parseTreeQuery([]string{"usages", "A.f"})
	a, _ := askTree(webTree, []string{"usages", "A.f"}, q, true, run)
	if len(a.Sites) != 1 || a.Sites[0].File != "engine_web/src/WebLayer.flix" || a.Decl != "" {
		t.Errorf("got %+v", a)
	}
}

// show は根が当てた名前なら木を見ない（engine_web の木の写しを 2 度出さない）。
func TestAskTreeSkipsShowWhenRootFound(t *testing.T) {
	called := false
	run := func(_ refactorTree, _ []string) (string, int) { called = true; return "{}", 0 }
	q, _ := parseTreeQuery([]string{"show", "A.f"})
	askTree(webTree, []string{"show", "A.f"}, q, true, run)
	if called {
		t.Error("木を問うた")
	}
}

// 根に無い名前を木で当てたら 0 で終わり、根の「索引にありません」は出さない。
func TestRefactorWithTreesFoundOnlyInTree(t *testing.T) {
	runRoot := func(_ []string) (string, string, int) { return "", "refactor search: 0 件\n", 1 }
	run := func(_ refactorTree, _ []string) (string, int) {
		return `{"found":[{"sym":"WebFs.runFileRead","kind":"def","file":"src/engine_web/WebFs.flix","line":20,"pub":true}]}`, 0
	}
	rest := []string{"search", "runFileRead"}
	q, _ := parseTreeQuery(rest)
	var out, errOut strings.Builder
	code := refactorWithTrees(&out, &errOut, rest, false, q, []refactorTree{webTree}, nil, runRoot, run, nil, nil)
	if code != 0 || errOut.String() != "" || !strings.Contains(out.String(), "engine_web/src/WebFs.flix:20") {
		t.Errorf("code=%d out=%q err=%q", code, out.String(), errOut.String())
	}
}

// --json では根の答えに trees を足す。
func TestRefactorWithTreesMergesJSON(t *testing.T) {
	runRoot := func(_ []string) (string, string, int) { return `{"op":"search","found":[]}`, "", 1 }
	run := func(_ refactorTree, _ []string) (string, int) {
		return `{"found":[{"sym":"BenchRun.planOf","kind":"def","file":"src/BenchRun.flix","line":16}]}`, 0
	}
	rest := []string{"search", "planOf", "--json"}
	q, _ := parseTreeQuery(rest)
	var out, errOut strings.Builder
	refactorWithTrees(&out, &errOut, rest, true, q, []refactorTree{benchTree}, nil, runRoot, run, nil, nil)
	var got struct {
		Trees []treeAnswer `json:"trees"`
	}
	if err := json.Unmarshal([]byte(out.String()), &got); err != nil || len(got.Trees) != 1 || got.Trees[0].Found[0].File != "bench/crowd/src/BenchRun.flix" {
		t.Errorf("got %q (%v)", out.String(), err)
	}
}

// 木の参照は engine の名前ごとに数え、木の中の自分の名前（頭の無い物）と再帰は数えない。
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

// --unused の候補のうち、木から使われている物だけを木の名前つきで返す。
func TestUsedInTreesPicksCandidatesUsedByTrees(t *testing.T) {
	cands := map[string]string{"src/A.flix:3": "A.used", "src/A.flix:9": "A.unused"}
	refs := map[string]map[string][]string{"bench/crowd": {"A.used": {"bench/crowd/src/Main.flix:1:1"}}}
	got := usedInTrees(cands, refs, []string{"bench/crowd"})
	if len(got) != 1 || got[0].Sym != "A.used" || got[0].Tree != "bench/crowd" {
		t.Errorf("got %+v", got)
	}
}

// 根の --unused の JSON の候補（短い名前）を、根の索引の宣言で完全な名前にする。
func TestUnusedCandidatesUsesDeclRows(t *testing.T) {
	out := `{"sites":[{"file":"src/A.flix","line":3,"col":5,"sym":"f","what":"def"},{"file":"src/A.flix","line":1,"col":1,"sym":"use X","what":"use"}]}`
	rows := []refactor.Row{{Kind: refactor.KindDefDecl, File: "src/A.flix", Line: 3, Sym: "A.f"}}
	got := unusedCandidates(out, rows)
	if len(got) != 1 || got["src/A.flix:3"] != "A.f" {
		t.Errorf("got %v", got)
	}
}

// engine の各パッケージの test は、根の索引の sources と testDirs の両方に入っている（新しいパッケージの test を足し忘れない）。
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
