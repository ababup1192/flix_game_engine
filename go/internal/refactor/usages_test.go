package refactor

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 索引は testdata/spans-*.tsv（flixlint の test/expected-spans-*.txt の写し）、元は testdata/src/Shapes.flix と Uses.flix。

func fixtureSrc() *srcCache { return &srcCache{root: filepath.Join("testdata", "spans")} }

func whats(us []UsageSite) map[UsageWhat]int {
	n := map[UsageWhat]int{}
	for _, u := range us {
		n[u.What]++
	}
	return n
}

// area は呼び出し 4（isRound の 2・fromParam・wide）、piped の List.map(Shapes.area) は関数を値で渡す参照、use 1。
func TestUsagesOfDefTellsCallsFromReferences(t *testing.T) {
	rows := loadFixture(t, Resolved)
	tg, err := ResolveTarget(rows, "area")
	must(t, err)
	n := whats(SymbolUsages(rows, tg, fixtureSrc()))
	if tg.Kind != "def" || n[WhatCall] != 4 || n[WhatRef] != 1 || n[WhatUse] != 1 || len(n) != 3 {
		t.Errorf("%+v %v", tg, n)
	}
}

// enum は case を作る・当てる所と、型の注記（alias の本体・シグネチャ・List[Shape] の中）と use。
func TestUsagesOfEnumIncludesItsCasesAndTypes(t *testing.T) {
	rows := loadFixture(t, Resolved)
	tg, err := ResolveTarget(rows, "Shapes.Shape")
	must(t, err)
	n := whats(SymbolUsages(rows, tg, fixtureSrc()))
	if n[WhatConstruct] != 3 || n[WhatPattern] != 3 || n[WhatType] != 6 || n[WhatUse] != 1 {
		t.Errorf("%v（組み立て 3・パターン 3・型の注記 6・use 1 のはず）", n)
	}
}

// 型 alias は型の注記と use だけ（`Shapes.World` と完全名で書いた所も同じ alias）。
func TestUsagesOfAlias(t *testing.T) {
	rows := loadFixture(t, Resolved)
	tg, err := ResolveTarget(rows, "World")
	must(t, err)
	n := whats(SymbolUsages(rows, tg, fixtureSrc()))
	if tg.Kind != "alias" || n[WhatType] != 7 || n[WhatUse] != 1 {
		t.Errorf("%+v %v", tg, n)
	}
}

func TestResolveTargetListsCandidatesWithTheirKind(t *testing.T) {
	rows := []Row{
		{Kind: KindDefDecl, Sym: "A.run", File: "src/A.flix", Line: 3, Col: 9},
		{Kind: KindAliasDecl, Sym: "B.run", File: "src/B.flix", Line: 7, Col: 16},
	}
	_, err := ResolveTarget(rows, "run")
	if err == nil || !strings.Contains(err.Error(), "A.run（def・src/A.flix:3:9）") || !strings.Contains(err.Error(), "B.run（alias・src/B.flix:7:16）") {
		t.Errorf("候補の並べ方: %v", err)
	}
}

// 欄 count の受け手が World の物: 読み 3・書き 1・組み立て 1（make の { shape = …, count = 0 }）。open の r#count は開いた row で数えない。
func TestUsagesOfFieldCountsReadsWritesAndConstructions(t *testing.T) {
	code, text := run(t, project(t), "usages", "World#count", "--json")
	var rep struct {
		Sites []UsageSite `json:"sites"`
		Maybe []UsageSite `json:"maybe"`
	}
	if err := json.Unmarshal([]byte(text), &rep); err != nil {
		t.Fatalf("%v\n%s", err, text)
	}
	n := whats(rep.Sites)
	if code != 0 || n[WhatRead] != 3 || n[WhatWrite] != 1 || n[WhatConstruct] != 1 || len(rep.Maybe) != 1 {
		t.Errorf("exit %d %v maybe %d\n%s", code, n, len(rep.Maybe), text)
	}
}

// x は Point と Size の 2 つの型にある（欄の組も同じ）。受け手を決めずに数えれば grep と同じなので、候補を並べて止まる。
func TestUsagesOfFieldStopsOnAnAmbiguousLabel(t *testing.T) {
	code, text := run(t, project(t), "usages", "--label", "x")
	if code != 2 || !strings.Contains(text, "Shapes.Point#x") || !strings.Contains(text, "Shapes.Size#x") {
		t.Errorf("exit %d\n%s", code, text)
	}
}

func TestCallerTreeFollowsCallersOfCallersOnce(t *testing.T) {
	// leaf ← mid ← top ← mid（再帰の輪）。top は 2 段目、mid の 2 度目は ↑ で止まる。
	rows := []Row{
		{Kind: KindDefUse, Sym: "M.leaf", Owner: "M.mid", File: "src/M.flix", Line: 2, Col: 5},
		{Kind: KindDefUse, Sym: "M.mid", Owner: "M.top", File: "src/M.flix", Line: 5, Col: 5},
		{Kind: KindDefUse, Sym: "M.top", Owner: "M.mid", File: "src/M.flix", Line: 3, Col: 5},
	}
	first := groupCallers([]UsageSite{usageOf(rows[0], WhatCall, "")})
	tree := CallerTree(rows, first, 3, "M.leaf")
	if len(tree) != 1 || tree[0].Owner != "M.mid" || len(tree[0].Callers) != 1 || tree[0].Callers[0].Owner != "M.top" {
		t.Fatalf("%+v", tree)
	}
	back := tree[0].Callers[0].Callers
	if len(back) != 1 || back[0].Owner != "M.mid" || !back[0].Seen || countCallers(tree) != 2 {
		t.Errorf("輪の止め方: %+v（数 %d）", back, countCallers(tree))
	}
}

// use isRound は呼ばない。use World は入れたが、コードは Shapes.World と完全名で書いている。use Shape と use Shapes.area は使う。
func TestUnusedUsesReadsTheWrittenName(t *testing.T) {
	got, unjudged := UnusedUses(loadFixture(t, Resolved), fixtureSrc())
	var syms []string
	for _, u := range got {
		syms = append(syms, u.Sym)
	}
	if strings.Join(syms, ",") != "Shapes.isRound,Shapes.World" || unjudged != 0 {
		t.Errorf("got %v unjudged %d", syms, unjudged)
	}
}

func TestUnusedDefsSortsByWhy(t *testing.T) {
	n := map[string]int{}
	for _, u := range UnusedDefs(loadFixture(t, Resolved), []string{"test"}) {
		n[u.Why]++
	}
	// area は Shapes の中からだけ（pub を外せる）。make は pub でない。ほかの pub 12 はどこからも参照されない。
	if n["own-mod"] != 1 || n["unreferenced"] != 12 || n["test-only"] != 0 {
		t.Errorf("%v", n)
	}
}

// typed の索引（use・type-use の行は resolved の段だけ）では、型の注記・use を数えていないと書く（0 件と言わない）。
func TestUsagesSaysWhenTheIndexHasNoTypeRows(t *testing.T) {
	root := project(t)
	var out, errOut strings.Builder
	code := Run(&out, &errOut, root, []string{"usages", "Shapes.area", "--stage", "typed", "--flixlint", filepath.Join(root, "flixlint")}, Options{Run: fakeRunner(new(int)), Log: os.Stderr})
	if code != 0 || !strings.Contains(out.String(), "型の注記・use は数えていない") {
		t.Errorf("exit %d\n%s%s", code, out.String(), errOut.String())
	}
}

func TestUsagesTextIsShort(t *testing.T) {
	code, text := run(t, project(t), "usages", "Shapes.area")
	lines := strings.Split(strings.TrimRight(text, "\n"), "\n")
	// 頭 1・数 1・場所 6。
	if code != 0 || len(lines) != 8 || !strings.HasPrefix(lines[0], "usages Shapes.area（def・src/Shapes.flix:15:13）") {
		t.Errorf("exit %d・%d 行\n%s", code, len(lines), text)
	}
}

func TestUsagesUnusedRun(t *testing.T) {
	code, text := run(t, project(t), "usages", "--unused", "--max", "0")
	if code != 1 || !strings.Contains(text, "使っていない use 2") || !strings.Contains(text, "fail:") {
		t.Errorf("exit %d\n%s", code, text)
	}
}
