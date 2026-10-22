package refactor

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testdata/spans-*.tsv は testdata/spans（src/Shapes.flix・src/Uses.flix）に flixlint --spans を掛けた物（作り直しは regen_test.go）。

func loadFixture(t *testing.T, s Stage) []Row {
	t.Helper()
	rows, err := ReadIndex(filepath.Join("testdata", "spans-"+string(s)+".tsv"), s)
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

func TestReadIndexRefusesAnotherStage(t *testing.T) {
	_, err := ReadIndex(filepath.Join("testdata", "spans-resolved.tsv"), Typed)
	if err == nil || !strings.Contains(err.Error(), "段") {
		t.Errorf("resolved の索引を typed として読めた: %v", err)
	}
}

func TestReadIndexRefusesAnotherFormat(t *testing.T) {
	_, err := parseIndex(strings.NewReader("# flixlint-spans 99 stage=typed columns=x\n"), Typed)
	if err == nil || !strings.Contains(err.Error(), "版") {
		t.Errorf("形の版の違う索引を読めた: %v", err)
	}
}

func TestResolveBySuffix(t *testing.T) {
	sym, err := Resolve(loadFixture(t, Resolved), "Shape.Dot", nameKinds)
	if err != nil || sym != "Shapes.Shape.Dot" {
		t.Errorf("got %q %v", sym, err)
	}
}

func TestResolveRefusesAmbiguousName(t *testing.T) {
	rows := []Row{{Kind: KindDefDecl, Sym: "A.run"}, {Kind: KindDefDecl, Sym: "B.run"}}
	_, err := Resolve(rows, "run", nameKinds)
	if err == nil || !strings.Contains(err.Error(), "A.run・B.run") {
		t.Errorf("2 つに当たる名前を通した: %v", err)
	}
}

func TestResolvePrefersTheExactName(t *testing.T) {
	rows := []Row{{Kind: KindEnumDecl, Sym: "World"}, {Kind: KindEnumDecl, Sym: "X.World"}}
	sym, err := Resolve(rows, "World", nameKinds)
	if err != nil || sym != "World" {
		t.Errorf("got %q %v", sym, err)
	}
}

func TestRefsCountsUsesNotTheDeclaration(t *testing.T) {
	res := Refs(loadFixture(t, Resolved), "Shapes.area", false)
	if len(res.Decls) != 1 || len(res.Uses) != 5 {
		t.Errorf("宣言 %d・参照 %d（1・5 のはず）", len(res.Decls), len(res.Uses))
	}
}

func TestRefsCallersGroupsByOwner(t *testing.T) {
	res := Refs(loadFixture(t, Resolved), "Shapes.area", true)
	got := map[string]int{}
	for _, c := range res.Callers {
		got[c.Owner] = c.Count
	}
	want := map[string]int{"Shapes.isRound": 2, "Shapes.fromParam": 1, "Shapes.piped": 1, "Shapes.wide": 1}
	if len(got) != len(want) || got["Shapes.isRound"] != 2 || got["Shapes.wide"] != 1 {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestMatchSitesOfEnum(t *testing.T) {
	sites := MatchSites(loadFixture(t, Resolved), "Shapes.Shape", false)
	if len(sites) != 2 || !sites[0].CatchAll() || sites[0].Wild != 1 || sites[1].Var != 2 {
		t.Errorf("got %+v", sites)
	}
}

func TestMatchSitesOfCase(t *testing.T) {
	sites := MatchSites(loadFixture(t, Resolved), "Shapes.Shape.Square", true)
	if len(sites) != 1 || sites[0].Owner != "Shapes.area" || sites[0].Hits != 1 {
		t.Errorf("got %+v", sites)
	}
}

func TestFieldSitesByReceiver(t *testing.T) {
	ans := FieldSites(loadFixture(t, Typed), FieldQuery{Label: "count", Receiver: "World"})
	writes := 0
	for _, s := range ans.Sites {
		if s.Write {
			writes++
		}
	}
	// fromParam・fromLet・bump の読み 3 と bump の書き 1。open の r#count は受け手が開いた row で unsure。
	if len(ans.Sites) != 4 || writes != 1 || len(ans.Unsure) != 1 {
		t.Errorf("sites %d・書き %d・unsure %d（4・1・1 のはず）", len(ans.Sites), writes, len(ans.Unsure))
	}
}

func TestFieldSitesOutsideSkipsTheAccessorModule(t *testing.T) {
	ans := FieldSites(loadFixture(t, Typed), FieldQuery{Label: "count", Receiver: "World", Outside: "Shapes"})
	if len(ans.Sites) != 0 || ans.Inside != 5 {
		t.Errorf("外 %d・中 %d（0・5 のはず）", len(ans.Sites), ans.Inside)
	}
}

func TestFieldSitesKnowsReceiverByRow(t *testing.T) {
	ans := FieldSites(loadFixture(t, Typed), FieldQuery{Label: "left", Receiver: "Pair"})
	if len(ans.Sites) != 1 || ans.Sites[0].Why != "row" {
		t.Errorf("got %+v", ans.Sites)
	}
}

// 索引の列は UTF-16 の数え方（日本語の後ろの名前も、BMP の外の字の後ろの名前も当たる）。
func TestSpanTextCountsUTF16(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("testdata", "spans", "src", "Shapes.flix"))
	if err != nil {
		t.Fatal(err)
	}
	r := Row{File: "src/Shapes.flix", Line: 45, Col: 57, EndLine: 45, EndCol: 61}
	got, err := SpanText(string(src), r)
	if err != nil || got != "area" {
		t.Errorf("got %q %v", got, err)
	}
	got, err = SpanText("x = \"🎲\" + f(1)\n", Row{Line: 1, Col: 12, EndLine: 1, EndCol: 13})
	if err != nil || got != "f" {
		t.Errorf("BMP の外の字の後ろ: got %q %v", got, err)
	}
}

func TestSpanTextRefusesAStaleSpan(t *testing.T) {
	if _, err := SpanText("short\n", Row{Line: 1, Col: 3, EndLine: 1, EndCol: 40}); err == nil {
		t.Error("行の外の範囲を通した")
	}
}

// project は testdata/spans/src の .flix（索引の元）と、索引を書く代わりの flixlint（中身は使わない）を持つ根を作る。
func project(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	must(t, os.MkdirAll(filepath.Join(root, "src"), 0o755))
	for _, name := range []string{"Shapes.flix", "Uses.flix"} {
		src, err := os.ReadFile(filepath.Join("testdata", "spans", "src", name))
		if err != nil {
			t.Fatal(err)
		}
		must(t, os.WriteFile(filepath.Join(root, "src", name), src, 0o644))
	}
	must(t, os.WriteFile(filepath.Join(root, "flixlint"), []byte("stand-in\n"), 0o644))
	return root
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// fakeRunner は flixlint の代わりに testdata の索引を --spans の先へ写し、呼ばれた数を数える。
func fakeRunner(calls *int) Runner {
	return func(_ Stage, desc, dir string, cmd []string, _ string) int {
		*calls++
		var out, stage string
		for i := 0; i+1 < len(cmd); i++ {
			switch cmd[i] {
			case "--spans":
				out = cmd[i+1]
			case "--stage":
				stage = cmd[i+1]
			}
		}
		data, err := os.ReadFile(filepath.Join("testdata", "spans-"+stage+".tsv"))
		if err != nil || os.WriteFile(out, data, 0o644) != nil {
			return 4
		}
		return 0
	}
}

func builder(root string, calls *int) Builder {
	return Builder{Root: root, Config: defaults(), Flixlint: filepath.Join(root, "flixlint"), Run: fakeRunner(calls), Log: io.Discard}
}

func TestLoadReusesTheIndexWhileTheSourcesAreTheSame(t *testing.T) {
	root := project(t)
	calls := 0
	b := builder(root, &calls)
	if _, err := b.Load(Resolved); err != nil {
		t.Fatal(err)
	}
	idx, err := b.Load(Resolved)
	if err != nil || !idx.Cached || calls != 1 {
		t.Errorf("2 回目: cached %v・作った回数 %d（true・1 のはず）%v", idx != nil && idx.Cached, calls, err)
	}
}

func TestLoadRebuildsWhenASourceChanges(t *testing.T) {
	root := project(t)
	calls := 0
	b := builder(root, &calls)
	if _, err := b.Load(Resolved); err != nil {
		t.Fatal(err)
	}
	must(t, os.WriteFile(filepath.Join(root, "src", "More.flix"), []byte("mod More {}\n"), 0o644))
	idx, err := b.Load(Resolved)
	if err != nil || idx.Cached || calls != 2 {
		t.Errorf("足した後: cached %v・作った回数 %d（false・2 のはず）%v", idx != nil && idx.Cached, calls, err)
	}
}

func TestLoadKeepsNoIndexWhenFlixlintFails(t *testing.T) {
	root := project(t)
	b := builder(root, new(int))
	b.Run = func(Stage, string, string, []string, string) int { return 3 }
	if _, err := b.Load(Resolved); err == nil || !strings.Contains(err.Error(), "コンパイル") {
		t.Errorf("コンパイルできない時の誤り: %v", err)
	}
	if _, err := os.Stat(b.indexPath(Resolved)); err == nil {
		t.Error("失敗した走行の索引が残った")
	}
}

func TestKeyFollowsSymlinkedSources(t *testing.T) {
	root := project(t)
	real := filepath.Join(root, "pkg")
	must(t, os.MkdirAll(real, 0o755))
	must(t, os.WriteFile(filepath.Join(real, "Linked.flix"), []byte("mod Linked {}\n"), 0o644))
	if err := os.Symlink(filepath.Join(real, "Linked.flix"), filepath.Join(root, "src", "Linked.flix")); err != nil {
		t.Skip("symlink を作れない:", err)
	}
	files, err := flixFiles(root, []string{"src"})
	if err != nil || len(files) != 3 {
		t.Errorf("got %v %v（Linked・Shapes・Uses の 3 つのはず）", files, err)
	}
}

func run(t *testing.T, root string, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	calls := 0
	code := Run(&out, &errOut, root, append(args, "--flixlint", filepath.Join(root, "flixlint")), Options{Run: fakeRunner(&calls), Log: io.Discard})
	return code, out.String() + errOut.String()
}

func TestRunMaxTurnsTheCountIntoACheck(t *testing.T) {
	code, text := run(t, project(t), "field-sites", "--label", "count", "--receiver", "World", "--max", "0")
	if code != 1 || !strings.Contains(text, "fail: 4 件（--max 0 を超えた）") {
		t.Errorf("exit %d\n%s", code, text)
	}
}

func TestRunJSONHasTheCheckresShape(t *testing.T) {
	code, text := run(t, project(t), "match-sites", "Shape", "--catch-all", "--json")
	var rep struct {
		Results []struct {
			Code   string  `json:"code"`
			Status string  `json:"status"`
			Got    float64 `json:"got"`
		} `json:"results"`
		Sites []MatchSite `json:"sites"`
		Exit  int         `json:"exit"`
	}
	if err := json.Unmarshal([]byte(text), &rep); err != nil {
		t.Fatalf("%v\n%s", err, text)
	}
	if code != 0 || len(rep.Results) != 1 || rep.Results[0].Code != CodeMatchSites || rep.Results[0].Got != 2 || len(rep.Sites) != 2 {
		t.Errorf("exit %d\n%s", code, text)
	}
}

func TestRunRefusesResolvedStageForFields(t *testing.T) {
	code, text := run(t, project(t), "field-sites", "--label", "count", "--stage", "resolved")
	if code != 2 || !strings.Contains(text, "typed") {
		t.Errorf("exit %d\n%s", code, text)
	}
}

func TestConfigLocalOverridesOnlyWhatItNames(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "bin", "lint-rules")
	must(t, os.MkdirAll(dir, 0o755))
	must(t, os.WriteFile(filepath.Join(dir, "refactor.json"), []byte(`{"sources": ["src", "test"], "verify": "make check"}`), 0o644))
	must(t, os.WriteFile(filepath.Join(dir, "refactor.local.json"), []byte(`{"verify": "make check CHECKD=0"}`), 0o644))
	c, err := LoadConfig(root)
	if err != nil || c.Verify != "make check CHECKD=0" || len(c.Sources) != 2 {
		t.Errorf("got %+v %v", c, err)
	}
}

// Point と Size は欄の組が同じ（{x, y}）。p#x の受け手はどちらとも決まらないので数えず unsure に並べる（設計 §5-1）。
func TestFieldSitesDoesNotCountAnAmbiguousReceiver(t *testing.T) {
	ans := FieldSites(loadFixture(t, Typed), FieldQuery{Label: "x", Receiver: "Point"})
	if len(ans.Sites) != 0 || len(ans.Unsure) != 1 || ans.Unsure[0].Recv != "ambiguous" {
		t.Errorf("sites %d・unsure %+v（0・ambiguous の 1 件のはず）", len(ans.Sites), ans.Unsure)
	}
}

func TestRunMaxIgnoresAnAmbiguousReceiver(t *testing.T) {
	code, text := run(t, project(t), "field-sites", "--label", "x", "--receiver", "Point", "--max", "0")
	if code != 0 || !strings.Contains(text, "pass: 0 件（--max 0 まで）") {
		t.Errorf("exit %d\n%s", code, text)
	}
}

func TestLoadRunsTheTypedStageAsTyped(t *testing.T) {
	root := project(t)
	var got Stage
	b := builder(root, new(int))
	inner := b.Run
	b.Run = func(s Stage, desc, dir string, cmd []string, log string) int {
		got = s
		return inner(s, desc, dir, cmd, log)
	}
	if _, err := b.Load(Typed); err != nil || got != Typed {
		t.Errorf("流した段 %q（typed のはず。heavy の長い物の枠を選ぶ元）%v", got, err)
	}
}

func TestLoadNamesSpansWhenFlixlintRefusesTheCall(t *testing.T) {
	b := builder(project(t), new(int))
	b.Run = func(Stage, string, string, []string, string) int { return 4 }
	if _, err := b.Load(Resolved); err == nil || !strings.Contains(err.Error(), "flixlint "+MinFlixlint+" 以上") {
		t.Errorf("終了コード 4 の誤り: %v", err)
	}
}

func TestKeyChangesWithTheDependencies(t *testing.T) {
	root := project(t)
	b := builder(root, new(int))
	before, err := b.Key(Resolved)
	must(t, err)
	dir := filepath.Join(root, "lib", "github", "o", "fge", "0.55.0")
	must(t, os.MkdirAll(dir, 0o755))
	must(t, os.WriteFile(filepath.Join(dir, "fge-0.55.0.fpkg"), []byte("pkg"), 0o644))
	after, err := b.Key(Resolved)
	if err != nil || before == after {
		t.Errorf("lib に fpkg を足しても鍵が同じ: %s %v", after, err)
	}
}

// --resident は索引の形 3 を書く flixlint（MinFlixlint 以上）に付ける。版が読めなければ付けない（作ってから頭の行で見る）。
func TestResidentOnlyForSharedServerVersions(t *testing.T) {
	for ver, want := range map[string]bool{"flixlint " + MinFlixlint: true, "flixlint 0.9.0-rc1": true, "版は読めない": false} {
		root := project(t)
		var got bool
		b := builder(root, new(int))
		inner := b.Run
		b.Run = func(s Stage, desc, dir string, cmd []string, log string) int {
			got = strings.Contains(strings.Join(cmd, " "), "--resident")
			return inner(s, desc, dir, cmd, log)
		}
		b.Version = func(string) string { return ver }
		if _, err := b.Load(Resolved); err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Errorf("%s: --resident %v（%v のはず）", ver, got, want)
		}
	}
}

// 版が読めて MinFlixlint より古ければ、索引を作る前（JVM を立てる前）に止め、上げ方を next に出す。
func TestLoadStopsBeforeBuildingWhenFlixlintIsTooOld(t *testing.T) {
	for _, ver := range []string{"flixlint 0.8.5", "flixlint 0.7.1"} {
		calls := 0
		b := builder(project(t), &calls)
		b.Version = func(string) string { return ver }
		_, err := b.Load(Typed)
		var ie *IndexError
		if err == nil || !errors.As(err, &ie) || calls != 0 || !strings.Contains(ie.Msg, MinFlixlint) || !strings.Contains(ie.NextWhy, "submodule") {
			t.Errorf("%s: 呼んだ数 %d・%v", ver, calls, err)
		}
	}
}

// 索引を作っている間にソースが変わったら、次の回は使い回さず作り直す（鍵のソースの分は作る前の値）。
func TestSourceChangedWhileBuildingRebuildsNextTime(t *testing.T) {
	root := project(t)
	calls := 0
	b := builder(root, &calls)
	inner := b.Run
	b.Run = func(s Stage, desc, dir string, cmd []string, log string) int {
		code := inner(s, desc, dir, cmd, log)
		if calls == 1 {
			must(t, os.WriteFile(filepath.Join(root, "src", "Late.flix"), []byte("mod Late {}\n"), 0o644))
		}
		return code
	}
	if _, err := b.Load(Resolved); err != nil {
		t.Fatal(err)
	}
	idx, err := b.Load(Resolved)
	if err != nil || idx.Cached || calls != 2 {
		t.Errorf("2 回目: cached %v・作った回数 %d（false・2 のはず）%v", idx != nil && idx.Cached, calls, err)
	}
}

// 依存（lib/）を作る途中で広げても、次の回は使い回す（鍵の依存の分は作った後の値）。
func TestLibAddedWhileBuildingIsReused(t *testing.T) {
	root := project(t)
	calls := 0
	b := builder(root, &calls)
	inner := b.Run
	b.Run = func(s Stage, desc, dir string, cmd []string, log string) int {
		must(t, os.MkdirAll(filepath.Join(root, "lib"), 0o755))
		must(t, os.WriteFile(filepath.Join(root, "lib", "dep.fpkg"), []byte("x"), 0o644))
		return inner(s, desc, dir, cmd, log)
	}
	if _, err := b.Load(Resolved); err != nil {
		t.Fatal(err)
	}
	idx, err := b.Load(Resolved)
	if err != nil || !idx.Cached || calls != 1 {
		t.Errorf("2 回目: cached %v・作った回数 %d（true・1 のはず）%v", idx != nil && idx.Cached, calls, err)
	}
}
