package refactor

import "testing"

func syms(fs []Found) []string {
	out := make([]string, len(fs))
	for i, f := range fs {
		out[i] = f.Sym
	}
	return out
}

// 名前がそのまま → 頭が同じ → 語の頭から → 途中に含む。同じ内は src → test。
func TestSearchRanksExactThenPrefixThenWordThenSubstring(t *testing.T) {
	all := []Found{
		{Sym: "G.center", Kind: "def", File: "src/G.flix"},
		{Sym: "R.pickEnter", Kind: "def", File: "src/R.flix"},
		{Sym: "T.enterTest", Kind: "def", File: "test/T.flix"},
		{Sym: "W.enterFight", Kind: "def", File: "src/W.flix"},
		{Sym: "W.enter", Kind: "def", File: "src/W.flix"},
		{Sym: "W.Exit", Kind: "enum", File: "src/W.flix"},
	}
	got := syms(Search(all, "enter", ""))
	want := []string{"W.enter", "W.enterFight", "T.enterTest", "R.pickEnter", "G.center"}
	if len(got) != len(want) {
		t.Fatalf("%v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("%v（%v のはず）", got, want)
		}
	}
	if got := syms(Search(all, "W.enter", "def")); len(got) != 2 || got[0] != "W.enter" {
		t.Errorf("mod つき: %v", got)
	}
}

// 直したファイルは字から拾う: mod の直下の宣言と enum の case。局所の def（字下げが深い）は拾わない。
func TestTextDeclsTakesTopLevelOnly(t *testing.T) {
	src := "mod Foo {\n    pub enum E {\n        case A\n        case B(Int32)\n    }\n    def f(): Int32 =\n        def loop(x) = x;\n        loop(1)\n    pub type alias R = { x = Int32 }\n}\n"
	got := textDecls("src/Foo.flix", src)
	want := []string{"Foo.E", "Foo.E.A", "Foo.E.B", "Foo.f", "Foo.R"}
	if s := syms(got); len(s) != len(want) || s[3] != "Foo.f" || s[4] != "Foo.R" {
		t.Fatalf("%v（%v のはず）", s, want)
	}
	if !got[0].Pub || got[3].Pub || got[3].Line != 6 || !got[3].Text {
		t.Errorf("%+v", got)
	}
}

// outline は行の順に頭の行つき。1 行の enum の case は出さない。
func TestOutlineSortsAndSkipsOneLineEnumCase(t *testing.T) {
	src := &srcCache{root: "testdata/spans"}
	all := []Found{
		{Sym: "Shapes.area", Kind: "def", File: "src/Shapes.flix", Line: 15},
		{Sym: "Shapes.Shape", Kind: "enum", File: "src/Shapes.flix", Line: 5},
		{Sym: "Shapes.Shape.Dot", Kind: "case", File: "src/Shapes.flix", Line: 8},
		{Sym: "Shapes.Shape.X", Kind: "case", File: "src/Shapes.flix", Line: 5},
	}
	got := Outline(all, "src/Shapes.flix", src)
	if len(got) != 3 || got[0].Line != 5 || got[1].Line != 8 || got[2].Sig != "pub def area(s: Shape): Int32 = match s {" {
		t.Errorf("%+v", got)
	}
}
