package refactor

import (
	"os"
	"path/filepath"
	"sort"
	"testing"
)

// --def で名指した時は、名指しの def と、それを消して初めて呼び手が 0 になる物（道連れ）だけを消す。名指しと関係の無い
// 呼び手 0 の pub（testdata/refmore の A.caller・A.letCaller・A.selfUse・A.lonely・B.b）は残し、数えるだけ。
// 期待は refmore の A.flix・B.flix の呼び出しの形から手で書いた物。

func refmoreRows(t *testing.T) []Row {
	t.Helper()
	rows, err := ReadIndex(filepath.Join("testdata", "refmore-spans-resolved.tsv"), Resolved)
	must(t, err)
	return rows
}

func targetSyms(p DeadPlan) []string {
	var out []string
	for _, f := range p.Targets {
		out = append(out, f.Sym)
	}
	sort.Strings(out)
	return out
}

func equalSyms(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// 道連れの無い名指し: 名指しの 1 つだけを消し、ほかの呼び手 0 の pub 4 つは Others に数える。
func TestRemoveDeadWithDefKeepsUnrelatedUnreferencedPubs(t *testing.T) {
	plan, err := PlanDead(fixtureRoot(t, "refmore"), refmoreRows(t), DeadQuery{TestDirs: []string{"test"}, Def: "A.lonely"})
	must(t, err)
	if got, want := targetSyms(plan), []string{"A.lonely"}; !equalSyms(got, want) {
		t.Fatalf("消す def %v（want %v）", got, want)
	}
	if plan.Others != 4 {
		t.Fatalf("ほかの呼び手 0 の def %d（want 4: A.caller・A.letCaller・A.selfUse・B.b）", plan.Others)
	}
}

// 道連れのある名指し: A.wrap の呼び手 A.caller・A.letCaller を名指すと、呼び手が 0 になる pub の A.wrap も消す。
// 名指しと関係の無い A.selfUse・A.lonely・B.b は残す。
func TestRemoveDeadWithDefTakesOnlyTheChainOfTheNamedDefs(t *testing.T) {
	plan, err := PlanDead(fixtureRoot(t, "refmore"), refmoreRows(t), DeadQuery{TestDirs: []string{"test"}, Def: "A.caller, A.letCaller"})
	must(t, err)
	if got, want := targetSyms(plan), []string{"A.caller", "A.letCaller", "A.wrap"}; !equalSyms(got, want) {
		t.Fatalf("消す def %v（want %v）", got, want)
	}
	if plan.Others != 3 {
		t.Fatalf("ほかの呼び手 0 の def %d（want 3: A.selfUse・A.lonely・B.b）", plan.Others)
	}
}

// 道連れは use で名前を入れる所がある pub を残す（B が use A.{onlyUsed} する）。
func TestRemoveDeadChainKeepsAPubThatAnotherModImports(t *testing.T) {
	plan, err := PlanDead(fixtureRoot(t, "refmore"), refmoreRows(t), DeadQuery{TestDirs: []string{"test"}, Def: "A.selfUse"})
	must(t, err)
	if got, want := targetSyms(plan), []string{"A.selfUse"}; !equalSyms(got, want) {
		t.Fatalf("消す def %v（want %v）", got, want)
	}
}

// 名指しの def が候補にならない時は 0 件で黙らず理由を fix に並べ、前の回（名指し無し）の last.diff を残さない。
func TestRemoveDeadWithDefThatCannotGoSaysWhyAndDropsTheOldDiff(t *testing.T) {
	root := fixtureRoot(t, "refmore")
	code, out := runRefmore(t, root, nil, "remove-dead")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	if _, err := os.Stat(filepath.Join(root, "build", "refactor", "last.diff")); err != nil {
		t.Fatalf("名指し無しの dry-run が last.diff を書いていない: %v", err)
	}
	code, out = runRefmore(t, root, nil, "remove-dead", "--def", "A.keep")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, out, "A.keep（ほかの mod の src から 1 か所呼ばれる（消せない））", "ほかにも呼び手 0 の def が 5")
	if _, err := os.Stat(filepath.Join(root, "build", "refactor", "last.diff")); !os.IsNotExist(err) {
		t.Fatalf("0 件の回に前の last.diff が残る（%v）", err)
	}
}

// 旗なしの名前（ファイル）を名指しと読み違えて全部の候補に当てない。
func TestRemoveDeadAndMakePrivateRefuseANameWithoutDef(t *testing.T) {
	root := fixtureRoot(t, "refmore")
	for _, op := range []string{"remove-dead", "make-private"} {
		code, out := runRefmore(t, root, nil, op, "A.lonely")
		if code != 2 {
			t.Fatalf("%s A.lonely: 終了コード %d（want 2）:\n%s", op, code, out)
		}
		mustContain(t, out, "--def <Mod.name>")
	}
}

// make-private も同じ決まり: 名指しの def だけを外し、ほかに外せる def は数えて知らせるだけ。
func TestMakePrivateWithDefCountsTheOthers(t *testing.T) {
	root := fixtureRoot(t, "refmore")
	code, out := runRefmore(t, root, nil, "make-private", "--def", "A.helper")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, out, "ほかにも同じ mod の中だけの pub の def が 1")
}

// 並んだ 2 つの def を消す時、間の空行を両方が取る書き換えは 1 つにまとめる（解けない重なりで断らない）。
func TestMergeDeletesJoinsDeletesThatShareABlankLine(t *testing.T) {
	src := "mod M {\n    def a(): Int32 = 1\n\n    def b(): Int32 = 2\n\n    def c(): Int32 = 3\n}\n"
	del := func(s, e int) Edit {
		return Edit{File: "M.flix", Start: s, End: e, Make: func(string) (string, error) { return "", nil }}
	}
	aStart := len("mod M {\n")
	bStart := aStart + len("    def a(): Int32 = 1\n")
	bEnd := bStart + len("\n    def b(): Int32 = 2\n")
	edits := []Edit{del(aStart, bStart+1), del(bStart, bEnd+1)}
	if _, err := ApplyEdits(src, edits); err == nil {
		t.Fatalf("まとめる前から重ならない（試験の前提が違う）")
	}
	got, err := ApplyEdits(src, mergeDeletes(edits))
	must(t, err)
	if want := "mod M {\n    def c(): Int32 = 3\n}\n"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}
