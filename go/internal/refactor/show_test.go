package refactor

import (
	"strings"
	"testing"
)

// def は索引の ext= の範囲（match の本文の閉じ括弧まで）。
func TestShowDefUsesTheIndexExtent(t *testing.T) {
	s, err := ShowDecl(loadFixture(t, Resolved), "area", fixtureSrc())
	must(t, err)
	if s.Kind != "def" || s.Start != 15 || s.End != 19 || !strings.HasSuffix(s.Text, "    }") {
		t.Errorf("%+v", s)
	}
}

// enum は括弧を数えて閉じるまで。case はそれを持つ enum を見せる。
func TestShowCaseShowsItsEnum(t *testing.T) {
	rows := loadFixture(t, Resolved)
	s, err := ShowDecl(rows, "Shape.Dot", fixtureSrc())
	must(t, err)
	if s.Kind != "enum" || s.Via != "Shapes.Shape.Dot" || s.Start != 5 || s.End != 9 {
		t.Errorf("%+v", s)
	}
}

// 1 行の型 alias は `=` の行で終わる（`{ … }` を閉じた所）。
func TestShowOneLineAlias(t *testing.T) {
	s, err := ShowDecl(loadFixture(t, Resolved), "Shapes.World", fixtureSrc())
	must(t, err)
	if s.Start != 11 || s.End != 11 {
		t.Errorf("%+v", s)
	}
}

// 括弧を数える時、字の列とコメントの中の物は数えない。上の /// と @ は範囲に入れる。
func TestBodyEndSkipsStringsAndTakesDoc(t *testing.T) {
	lines := strings.Split("    /// doc {\n    @Deprecated\n    pub enum E {\n        case A // }\n        case B(String) \"}\"\n    }\n    def x(): Int32 = 1", "\n")
	r := Row{Kind: KindEnumDecl, Line: 3, Col: 14}
	if s, e := declRange(r, lines); s != 1 || e != 6 {
		t.Errorf("%d-%d（1-6 のはず）", s, e)
	}
}
