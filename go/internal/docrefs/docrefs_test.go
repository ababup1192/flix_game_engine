package docrefs

import (
	"archive/zip"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
)

// gameRepo は testdata/game を写し、engine の規約 bin/lint-rules/doc-refs.json を足した使い捨てのリポ。
func gameRepo(t *testing.T) string {
	t.Helper()
	t.Setenv("ENGINE", "") // 手元の local.mk・環境のエンジンを引かない
	root := t.TempDir()
	src := filepath.Join("testdata", "game")
	err := filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		dst := filepath.Join(root, rel)
		if info.IsDir() {
			return os.MkdirAll(dst, 0o755)
		}
		body, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(dst, body, 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
	rules, err := os.ReadFile(filepath.Join("..", "..", "..", "bin", "lint-rules", "doc-refs.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "bin", "lint-rules", "doc-refs.json"), rules, 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

func write(t *testing.T, root, rel, body string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// hitsOf は「文書:行 字 code」を並べた物（比べやすい形）。
func hitsOf(t *testing.T, root string, args ...string) []string {
	t.Helper()
	var out, errOut strings.Builder
	if _, err := Run(&out, &errOut, root, append(args, "--json")); err != nil {
		t.Fatal(err)
	}
	var jr struct {
		Results []struct {
			Code  string `json:"code"`
			Cause struct {
				Op     string `json:"op"`
				Script string `json:"script"`
			} `json:"cause"`
		} `json:"results"`
	}
	if err := json.Unmarshal([]byte(out.String()), &jr); err != nil {
		t.Fatalf("%v: %s", err, out.String())
	}
	got := []string{}
	for _, r := range jr.Results {
		got = append(got, r.Cause.Script+" "+r.Cause.Op+" "+r.Code)
	}
	sort.Strings(got)
	return got
}

func TestGameDocsFindOnlyMissingRefs(t *testing.T) {
	root := gameRepo(t)
	want := []string{
		"NOTES.md:2 World.stepp doc-refs.name",
		"docs/map.md:10 Board.Cell.Wall doc-refs.name",
		"docs/map.md:10 World.removedOnce doc-refs.name",
		"docs/map.md:10 src/Gone.flix doc-refs.file",
		"docs/map.md:10 src/World.flix:999 doc-refs.line",
		"docs/map.md:11 docs/nowhere.md doc-refs.file",
		"docs/map.md:8 World.moveTo doc-refs.name",
	}
	if got := hitsOf(t, root); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("got\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestNamedDocsOnlyAndOutOfScopeIsSilent(t *testing.T) {
	root := gameRepo(t)
	if got := hitsOf(t, root, "NOTES.md"); len(got) != 1 || !strings.HasPrefix(got[0], "NOTES.md:2 ") {
		t.Errorf("NOTES.md だけ: %v", got)
	}
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, []string{"docs/old/history.md", "notes/2026-08.md", "README.md"})
	if err != nil || code != 0 || out.Len()+errOut.Len() != 0 {
		t.Errorf("skip・範囲の外だけなら黙って 0: code %d err %v out %q %q", code, err, out.String(), errOut.String())
	}
}

func TestNearCandidates(t *testing.T) {
	root := gameRepo(t)
	rules, err := LoadRules(root)
	if err != nil {
		t.Fatal(err)
	}
	rep := rules.Check(root, []string{"NOTES.md", "docs/map.md"})
	near := map[string]string{}
	for _, h := range rep.Hits {
		near[h.Text] = strings.Join(h.Near, "・")
	}
	for name, want := range map[string]string{"World.stepp": "World.step", "Board.Cell.Wall": "", "src/Gone.flix": ""} {
		if near[name] != want {
			t.Errorf("%s の候補 %q（want %q）", name, near[name], want)
		}
	}
}

func TestBriefOutputIsShortWithNext(t *testing.T) {
	root := gameRepo(t)
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, nil)
	if err != nil || code != 1 {
		t.Fatalf("code %d err %v", code, err)
	}
	text := errOut.String()
	for _, want := range []string{"見つからない 7 件（名前 4・ファイル 2・行 1）", "docs/map.md:8", "World.moveTo", "→ 候補 World.step", "next: bin/fge doc-refs docs/map.md"} {
		if !strings.Contains(text, want) {
			t.Errorf("出力に %q が無い:\n%s", want, text)
		}
	}
}

// flixlint の索引が sources より新しければ、字で拾えない宣言も在ると数える。古ければ使わない。
func TestSpansIndexFillsWhenFresh(t *testing.T) {
	root := gameRepo(t)
	write(t, root, "docs/gen.md", "`World.generated` は索引だけが知る。\n")
	spans := "# flixlint-spans 2 stage=resolved columns=kind,file,sl,sc,el,ec,sym,owner,extra\n" +
		"def-decl\tsrc/World.flix\t1\t1\t1\t2\tWorld.generated\tWorld.generated\tpub\n" +
		"def-decl\tsrc/World.flix\t1\t1\t1\t2\t$pkg$Other.x\tOther.x\t\n"
	write(t, root, "build/refactor/spans-resolved.tsv", spans)
	if got := hitsOf(t, root, "docs/gen.md"); len(got) != 0 {
		t.Errorf("新しい索引: %v", got)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(filepath.Join(root, "build", "refactor", "spans-resolved.tsv"), old, old); err != nil {
		t.Fatal(err)
	}
	if got := hitsOf(t, root, "docs/gen.md"); len(got) != 1 {
		t.Errorf("古い索引は使わない: %v", got)
	}
}

func TestLocalAcceptsOnlySkip(t *testing.T) {
	root := gameRepo(t)
	write(t, root, "bin/lint-rules/doc-refs.local.json", `{"sources": ["lib"]}`)
	if _, err := LoadRules(root); err == nil || !strings.Contains(err.Error(), "skip") {
		t.Errorf("skip 以外の鍵は止める: %v", err)
	}
}

func TestScanFlixDecls(t *testing.T) {
	body, err := os.ReadFile(filepath.Join("testdata", "game", "src", "World.flix"))
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, d := range ScanFlix(string(body)) {
		got = append(got, d.Name)
	}
	want := []string{"World", "World.Phase", "World.Phase.Title", "World.Phase.Home", "World.Phase.Fight",
		"World.Rec", "World.Rec.phase", "World.Rec.turn", "World.Rec.clock", "World.initial", "World.step",
		"World.Ask", "World.Ask.ask"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("got  %v\nwant %v", got, want)
	}
}

func TestScanMarkdownSpansAndEnginePrefix(t *testing.T) {
	ext := map[string]bool{"md": true, "flix": true}
	refs := ScanMarkdown("engine の `docs/pacing.md` と `src/A.flix:3-5`\n|`Xx.yy` Bb.cc|\nプレーン Aa.bb\n", ext, nil)
	var got []string
	for _, r := range refs {
		s := r.Text
		if r.Engine {
			s += "(engine)"
		}
		got = append(got, s)
	}
	want := "docs/pacing.md(engine) src/A.flix:3-5 Xx.yy Bb.cc"
	if strings.Join(got, " ") != want {
		t.Errorf("got %v want %s", got, want)
	}
}

// git が無視するパス（作る物の置き場）は無くても数えない。
func TestIgnoredPathIsBuildProduct(t *testing.T) {
	root := gameRepo(t)
	write(t, root, ".gitignore", "artifact/\n")
	write(t, root, "artifact/.keep", "")
	write(t, root, "docs/made.md", "`artifact/game.fpkg` は make で作る。`artifact/../src/Nope.flix` は無い。\n")
	lintconf.GitInit(t, root)
	if got := hitsOf(t, root, "docs/made.md"); len(got) != 0 {
		t.Errorf("無視するパスは数えない: %v", got)
	}
}

// 頭に「手で直さない」と書いた生成物の文書は、名指ししても全部を流しても見ない（作る元を直す）。
func TestGeneratedDocIsNotChecked(t *testing.T) {
	root := gameRepo(t)
	write(t, root, "docs/ops.md", "# op の表（fge ops --md が作る。手で直さない）\n\n`World.nowhere` と `src/Gone.flix`\n")
	write(t, root, "docs/late.md", "# 手で書いた文書\n\n\n\n\n\n手で直さない（6 行目は頭でない） `World.nowhere`\n")
	if got := hitsOf(t, root, "docs/ops.md", "docs/late.md"); strings.Join(got, "\n") != "docs/late.md:7 World.nowhere doc-refs.name" {
		t.Errorf("生成物だけ見ない: %v", got)
	}
}

// `名前`（予定） と 表の 名前（予定） は数えない。印の無い同じ行の名前は数える。
func TestPlannedNamesAreNotCounted(t *testing.T) {
	root := gameRepo(t)
	write(t, root, "docs/plan.md", "`World.enter`（予定）と `World.arenaOf(f) / src/Arena.flix` (予定)、`World.later`\n| World.FightCtx（予定） | World.nope |\n")
	want := "docs/plan.md:1 World.later doc-refs.name\ndocs/plan.md:2 World.nope doc-refs.name"
	if got := hitsOf(t, root, "docs/plan.md"); strings.Join(got, "\n") != want {
		t.Errorf("got\n%s\nwant\n%s", strings.Join(got, "\n"), want)
	}
}

// 誤りの文が引く名前（` ` の中の '…'）は確かめない。引用の外の名前は確かめる。
func TestQuotedNamesInCodeSpanAreNotChecked(t *testing.T) {
	root := gameRepo(t)
	write(t, root, "docs/err.md", "`Undefined name 'World.gone'`（E2136）と `World.gone2 'x'`\n")
	if got := hitsOf(t, root, "docs/err.md"); strings.Join(got, "\n") != "docs/err.md:1 World.gone2 doc-refs.name" {
		t.Errorf("引用の中は見ない: %v", got)
	}
}

// 頭がこのリポのモジュールと同じ名前でも、flix.jar の標準ライブラリに在る名前は在ると数える。jar が無ければ知らせる。
func TestFlixStdlibNamesFromJar(t *testing.T) {
	root := gameRepo(t)
	write(t, root, "src/Clock.flix", "mod Clock { pub def tick(): Int32 = 1 }\n")
	write(t, root, "docs/std.md", "`run f() with Clock.runWithIO` と `Clock.tick` と `Clock.nope`\n")
	if got := hitsOf(t, root, "docs/std.md"); len(got) != 2 {
		t.Errorf("jar が無ければ標準の名前も無いに出る: %v", got)
	}
	jar, err := os.Create(filepath.Join(root, "bin", "flix.jar"))
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(jar)
	w, err := zw.Create("src/library/Time/Clock.flix")
	if err != nil {
		t.Fatal(err)
	}
	w.Write([]byte("pub mod Time.Clock {\n    pub def runWithIO(f: Unit -> a \\ ef): a \\ ef = f()\n}\n"))
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	jar.Close()
	if got := hitsOf(t, root, "docs/std.md"); strings.Join(got, "\n") != "docs/std.md:1 Clock.nope doc-refs.name" {
		t.Errorf("標準ライブラリの名前は在る: %v", got)
	}
}
