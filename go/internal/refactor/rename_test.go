package refactor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRenameInUseTakesTheNameOnly(t *testing.T) {
	cases := []struct{ text, want string }{
		{"World.moveTo", "World.goTo"},
		{"World.{moveTo, phaseOf}", "World.{goTo, phaseOf}"},
		{"World.{phaseOf, moveTo}", "World.{phaseOf, goTo}"},
		{"World.{moveTo => mv}", "World.{goTo => mv}"},
	}
	for _, c := range cases {
		got, ok := renameInUse(c.text, "moveTo", "goTo")
		if !ok || got != c.want {
			t.Errorf("%q: got %q (%v), want %q", c.text, got, ok, c.want)
		}
	}
	if _, ok := renameInUse("World.{phaseOf}", "moveTo", "goTo"); ok {
		t.Error("a use without the name was renamed")
	}
}

// renameFixture は World.moveTo の宣言・修飾した呼び出し・use で取り込んだ呼び出し・別名で取り込んだ呼び出しの 4 ファイル。
func renameFixture(t *testing.T) (string, []Row) {
	t.Helper()
	root := t.TempDir()
	files := map[string]string{
		"src/World.flix": "mod World {\n    pub def moveTo(x: Int32): Int32 = x\n}\n",
		"src/A.flix":     "mod A {\n    pub def a(): Int32 = World.moveTo(1)\n}\n",
		"src/B.flix":     "mod B {\n    use World.{moveTo, phaseOf}\n    pub def b(): Int32 = moveTo(2)\n}\n",
		"src/C.flix":     "mod C {\n    use World.{moveTo => mv}\n    pub def c(): Int32 = mv(3)\n}\n",
	}
	for f, src := range files {
		if err := os.MkdirAll(filepath.Join(root, filepath.Dir(f)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, f), []byte(src), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	rows := []Row{
		{Kind: KindDefDecl, File: "src/World.flix", Line: 2, Col: 13, EndLine: 2, EndCol: 19, Sym: "World.moveTo", Owner: "World.moveTo", Extra: "pub"},
		{Kind: KindDefUse, File: "src/A.flix", Line: 2, Col: 26, EndLine: 2, EndCol: 38, Sym: "World.moveTo", Owner: "A.a"},
		{Kind: KindUse, File: "src/B.flix", Line: 2, Col: 9, EndLine: 2, EndCol: 32, Sym: "World.moveTo", Owner: "B", Extra: "alias=moveTo what=def"},
		{Kind: KindDefUse, File: "src/B.flix", Line: 3, Col: 26, EndLine: 3, EndCol: 32, Sym: "World.moveTo", Owner: "B.b"},
		{Kind: KindUse, File: "src/C.flix", Line: 2, Col: 9, EndLine: 2, EndCol: 29, Sym: "World.moveTo", Owner: "C", Extra: "alias=mv what=def"},
		{Kind: KindDefUse, File: "src/C.flix", Line: 3, Col: 26, EndLine: 3, EndCol: 28, Sym: "World.moveTo", Owner: "C.c"},
	}
	return root, rows
}

func TestRenameWritesEveryPlaceButTheAlias(t *testing.T) {
	root, rows := renameFixture(t)
	p, err := PlanRename(root, rows, "World.moveTo", "goTo", nil, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Fix) != 0 {
		t.Fatalf("fix: %v", p.Fix)
	}
	byFile := map[string][]Edit{}
	for _, e := range p.Edits {
		byFile[e.File] = append(byFile[e.File], e)
	}
	got := map[string]string{}
	for f, es := range byFile {
		src, _ := os.ReadFile(filepath.Join(root, f))
		out, err := ApplyEdits(string(src), es)
		if err != nil {
			t.Fatal(err)
		}
		got[f] = out
	}
	want := map[string]string{
		"src/World.flix": "mod World {\n    pub def goTo(x: Int32): Int32 = x\n}\n",
		"src/A.flix":     "mod A {\n    pub def a(): Int32 = World.goTo(1)\n}\n",
		"src/B.flix":     "mod B {\n    use World.{goTo, phaseOf}\n    pub def b(): Int32 = goTo(2)\n}\n",
		"src/C.flix":     "mod C {\n    use World.{goTo => mv}\n    pub def c(): Int32 = mv(3)\n}\n",
	}
	for f, w := range want {
		if got[f] != w {
			t.Errorf("%s:\n got %q\nwant %q", f, got[f], w)
		}
	}
	if len(p.Sites) != 5 {
		t.Errorf("sites %d, want 5 (the alias c's call is not one)", len(p.Sites))
	}
}

func TestRenameStopsOnANameThatIsThere(t *testing.T) {
	root, rows := renameFixture(t)
	rows = append(rows, Row{Kind: KindDefDecl, File: "src/World.flix", Line: 9, Col: 13, EndLine: 9, EndCol: 17, Sym: "World.goTo", Owner: "World.goTo"})
	if _, err := PlanRename(root, rows, "World.moveTo", "goTo", nil, false); err == nil || !strings.Contains(err.Error(), "もう在る") {
		t.Fatalf("err %v, want it to stop on World.goTo", err)
	}
}
