package doclookup

// 何を守るか: 旧 make api・module・src（grep・mk/module.sed・mk/src-index.awk）と同じ行を同じ形で出すこと。

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestModuleTableRowBecomesArrow(t *testing.T) {
	got, _ := moduleLine("docs/modules/ui.md", 11, "| 長い内容を覗く | UiScroll |")
	if want := "docs/modules/ui.md:11  長い内容を覗く → UiScroll"; got != want {
		t.Fatalf("%q (want %q)", got, want)
	}
}

func TestModuleItemDropsTheBold(t *testing.T) {
	got, _ := moduleLine("docs/modules/fx.md", 24, "- **Scatter** — 撒き方")
	if want := "docs/modules/fx.md:24  Scatter — 撒き方"; got != want {
		t.Fatalf("%q (want %q)", got, want)
	}
}

func TestModuleDropsTableHeaderAndQuote(t *testing.T) {
	for _, s := range []string{"| やりたいこと | モジュール |", "| 症状 | モジュール |", "|---|---|", "> 案内"} {
		if _, keep := moduleLine("f.md", 1, s); keep {
			t.Errorf("%q を落とさなかった", s)
		}
	}
}

func TestModuleReadsEngineMdLast(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "docs/modules/engine.md"), "x engine\n")
	write(t, filepath.Join(root, "docs/modules/ui.md"), "x ui\n")
	var out strings.Builder
	Module(&out, root, "", "x")
	if want := "docs/modules/ui.md:1  x ui\ndocs/modules/engine.md:1  x engine\n"; out.String() != want {
		t.Fatalf("%q", out.String())
	}
}

func TestSrcDeclTrimsIndentAndTrailingEquals(t *testing.T) {
	got, ok := srcDecl("    pub def f(x: Int32): Int32 =")
	if !ok || got != "pub def f(x: Int32): Int32" {
		t.Fatalf("%q %v", got, ok)
	}
}

func TestSrcDeclSkipsPrivateDef(t *testing.T) {
	if _, ok := srcDecl("    def f(): Int32 = 1"); ok {
		t.Fatal("pub でない def を拾った")
	}
}

func TestSrcDeclCutsLongLinesAt160Chars(t *testing.T) {
	got, _ := srcDecl("pub def " + strings.Repeat("あ", 200))
	if n := len([]rune(got)); n != 160 || !strings.HasSuffix(got, "...") {
		t.Fatalf("%d 字 %q", n, got)
	}
}

func TestSrcPrintsPathRelativeToTheGame(t *testing.T) {
	game := t.TempDir()
	write(t, filepath.Join(game, "src/a/B.flix"), "mod B {\n    pub enum Talk {\n")
	var out strings.Builder
	Src(&out, game, "talk")
	if want := "src/a/B.flix:2: pub enum Talk\n"; out.String() != want {
		t.Fatalf("%q", out.String())
	}
}

func TestBasicRegexKeepsGrepMeanings(t *testing.T) {
	cases := map[string][2]string{
		`draw.*Text`: {"drawBigText", "draw"},
		`a\|b`:       {"xb", "c"},
		`f(x)`:       {"f(x)", "fx"},
		`a+`:         {"a+", "aa"},
		`*x`:         {"*x", "x"},
		`[A-Z]oom`:   {"Zoom", "zoom!"},
	}
	for q, c := range cases {
		re := compileGrep(q)
		if !re.MatchString(c[0]) {
			t.Errorf("%q が %q に当たらない", q, c[0])
		}
		if q != `[A-Z]oom` && re.MatchString(c[1]) {
			t.Errorf("%q が %q に当たった", q, c[1])
		}
	}
}

func TestAPIStopsAt40Lines(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "docs/api-digest/engine.md"), strings.Repeat("hit\n", 50))
	var out strings.Builder
	API(&out, root, "hit")
	if n := strings.Count(out.String(), "\n"); n != MaxLines {
		t.Fatalf("%d 行", n)
	}
}
