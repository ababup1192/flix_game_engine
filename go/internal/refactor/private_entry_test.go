package refactor

import (
	"path/filepath"
	"strings"
	"testing"
)

// --def で 1 つ名指しした時は、その def だけ pub を外す（同じ mod の中だけの def がほかにあっても当てない）。
func TestMakePrivateWithDefTouchesOnlyTheNamedDef(t *testing.T) {
	root := fixtureRoot(t, "refmore")
	var cmds []string
	code, out := runRefmore(t, root, verifyWith(0, "", &cmds), "make-private", "--def", "A.helper", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	src := read(t, root, "src/A.flix")
	if !strings.Contains(src, "pub def wrap(a: Int32)") {
		t.Fatalf("名指ししていない A.wrap（同じ mod の中だけ）の pub まで外した:\n%s", src)
	}
	if strings.Contains(out, "A.wrap") || !strings.Contains(out, "done: 1 defs") {
		t.Fatalf("名指しの 1 つのほかに当てた:\n%s", out)
	}
}

// 入口の表（常駐の jobs()）の中から使う def と、入口のファイルに Mod.x が出る時の Mod.xJob は入口として外さない。
func TestEntryTablesAndJobNamesAreEntries(t *testing.T) {
	rows, err := ReadIndex(filepath.Join("testdata", "refmore-spans-resolved.tsv"), Resolved)
	must(t, err)
	// A.jobs() の表が A.wrap を入口として持つ（同じ mod の中からの参照＝外の使い手は 0）。
	rows = append(rows, Row{Kind: KindDefUse, File: "src/A.flix", Line: 30, Col: 5, EndLine: 30, EndCol: 9, Sym: "A.wrap", Owner: "A.jobs"})
	m := Mentions{Entry: map[string]string{}}.withEntryDefs(rows, []string{"jobs"})
	plan, err := PlanPrivate(fixtureRoot(t, "refmore"), rows, PrivateQuery{TestDirs: []string{"test"}, Outside: m.Entry})
	must(t, err)
	for _, x := range plan.Targets {
		if x.Sym == "A.wrap" {
			t.Fatalf("入口の表の A.wrap の pub を外す: %+v", plan.Targets)
		}
	}
	found := false
	for _, f := range plan.Fix {
		found = found || (f.Sym == "A.wrap" && strings.Contains(f.Why, "入口の表 A.jobs()"))
	}
	if !found {
		t.Fatalf("A.wrap を入口として fix に並べていない: %+v", plan.Fix)
	}
	// Makefile が A.play を名指せば、中身の A.playJob も入口。
	jm := Mentions{Entry: map[string]string{"A.play": "Makefile"}}.withEntryDefs([]Row{{Kind: KindDefDecl, Sym: "A.playJob"}}, nil)
	if !strings.Contains(jm.Entry["A.playJob"], "Makefile") {
		t.Fatalf("入口 A.play の中身 A.playJob を入口に数えない: %v", jm.Entry)
	}
}
