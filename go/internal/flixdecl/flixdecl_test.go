package flixdecl

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func repoRoot() string { return filepath.Join("..", "..", "..") }

// declsOf は 1 つの mod の宣言本文だけを取り出す。
func declsOf(t *testing.T, src, mod string) []string {
	t.Helper()
	for _, md := range ScanText(src) {
		if md.Mod != mod {
			continue
		}
		var out []string
		for _, d := range md.Decls {
			out = append(out, d.Text)
		}
		return out
	}
	return nil
}

func TestDefSignatureStopsAtBody(t *testing.T) {
	got := declsOf(t, "mod M {\n    pub def add(a: Int32, b: Int32): Int32 = a + b\n}\n", "M")
	if len(got) != 1 || got[0] != "pub def add(a: Int32, b: Int32): Int32" {
		t.Fatalf("シグネチャが %q", got)
	}
}

func TestDefSignatureKeepsComparisonOperators(t *testing.T) {
	src := "mod M {\n    pub def near(a: Int32): Bool = a == 1 and a != 2\n}\n"
	got := declsOf(t, src, "M")
	if len(got) != 1 || got[0] != "pub def near(a: Int32): Bool" {
		t.Fatalf("`==` を本体の開始と読み違えた: %q", got)
	}
}

func TestDefSignatureKeepsFatArrow(t *testing.T) {
	src := "mod M {\n    pub def apply(f: Int32 -> Int32 \\ ef): Int32 \\ ef = f(1)\n}\n"
	got := declsOf(t, src, "M")
	if len(got) != 1 || !strings.HasSuffix(got[0], "\\ ef") {
		t.Fatalf("効果注釈まで拾えていない: %q", got)
	}
}

func TestDefSignatureSpansLines(t *testing.T) {
	src := "mod M {\n    pub def wide(\n        a: Int32,\n        b: Int32\n    ): Int32 =\n        a + b\n}\n"
	got := declsOf(t, src, "M")
	if len(got) != 1 || got[0] != "pub def wide( a: Int32, b: Int32 ): Int32" {
		t.Fatalf("複数行のシグネチャが %q", got)
	}
}

func TestTypeAliasSpansLines(t *testing.T) {
	src := "mod M {\n    pub type alias V = {\n        at = Vec2.Vec2,\n        alpha = Float32\n    }\n}\n"
	got := declsOf(t, src, "M")
	if len(got) != 1 || got[0] != "pub type alias V = { at = Vec2.Vec2, alpha = Float32 }" {
		t.Fatalf("複数行の type alias が %q", got)
	}
}

func TestEffOpsAreListed(t *testing.T) {
	src := "mod M {\n    pub eff Audio {\n        /// 音量\n        def setVolume(name: String): Unit\n        def stop(): Unit\n    }\n}\n"
	got := declsOf(t, src, "M")
	want := []string{
		"pub eff Audio",
		"pub eff Audio { def setVolume(name: String): Unit }",
		"pub eff Audio { def stop(): Unit }",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("eff の op が %q", got)
	}
}

// TestTopLevelEffGoesToSameNamedMod は mod の外の eff を同じ名前の mod の宣言として返す
func TestTopLevelEffGoesToSameNamedMod(t *testing.T) {
	src := "pub eff Load {\n    def report(done: Int32): Unit\n}\n\npub mod Load {\n    pub def runNoop(): Unit = ()\n}\n"
	got := declsOf(t, src, "Load")
	want := []string{
		"pub eff Load",
		"pub eff Load { def report(done: Int32): Unit }",
		"pub def runNoop(): Unit",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("mod の外の eff が %q", got)
	}
}

// TestEffEndsAtBraceInsideString は eff の範囲だけ文字列リテラルの中の括弧も数える
// ことを縛る。
func TestEffEndsAtBraceInsideString(t *testing.T) {
	src := "mod M {\n    pub eff E {\n        def a(): Unit\n        def brace(): String = \"}\"\n        def c(): Unit\n    }\n}\n"
	got := declsOf(t, src, "M")
	want := []string{"pub eff E", "pub eff E { def a(): Unit }"}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("eff の終わりが Python とずれている: %q", got)
	}
}

func TestCommentAndStringAreNotParsed(t *testing.T) {
	src := "mod M {\n    // pub def ghost(): Unit\n    pub def quiet(): String = \"pub def inside\"\n}\n"
	got := declsOf(t, src, "M")
	if len(got) != 1 || got[0] != "pub def quiet(): String" {
		t.Fatalf("コメントか文字列の中を宣言と読んだ: %q", got)
	}
}

func TestDocCommentTakesFirstLineOnly(t *testing.T) {
	src := "mod M {\n    /// さきの行\n    /// あとの行\n    pub def f(): Unit = ()\n}\n"
	mods := ScanText(src)
	if len(mods) != 1 || len(mods[0].Decls) != 1 {
		t.Fatalf("宣言が %v", mods)
	}
	if mods[0].Decls[0].Doc != "さきの行" {
		t.Fatalf("doc が %q", mods[0].Decls[0].Doc)
	}
}

func TestDeclOutsideModIsDropped(t *testing.T) {
	if got := ScanText("pub def loose(): Unit = ()\n"); len(got) != 0 {
		t.Fatalf("mod の外の宣言を拾った: %v", got)
	}
}

func TestNestedModIsTracked(t *testing.T) {
	src := "mod Outer {\n    mod Inner {\n        pub def deep(): Unit = ()\n    }\n    pub def shallow(): Unit = ()\n}\n"
	var mods []string
	for _, md := range ScanText(src) {
		mods = append(mods, md.Mod)
	}
	if strings.Join(mods, ",") != "Inner,Outer" {
		t.Fatalf("mod の並びが %v", mods)
	}
}

func TestDeclName(t *testing.T) {
	cases := map[string]string{
		"pub def setScale(v: Float32): Unit":      "setScale",
		"pub enum Shape { case Box }":             "Shape",
		"pub type alias V = { a = Float32 }":      "V",
		"pub eff Audio":                           "Audio",
		"pub eff Audio { def setVolume(): Unit }": "Audio.setVolume",
		"どれでもない":                                  "?",
	}
	for decl, want := range cases {
		if got := DeclName(decl); got != want {
			t.Errorf("DeclName(%q) = %q (期待 %q)", decl, got, want)
		}
	}
}

func TestCollapseHandlesFullWidthSpace(t *testing.T) {
	if got := Collapse("　pub  def\tf()　"); got != "pub def f()" {
		t.Fatalf("全角空白の潰し方が %q", got)
	}
}

func TestTruncateCountsRunes(t *testing.T) {
	if got := Truncate("あいうえお", 3); got != "あいう" {
		t.Fatalf("文字数でなくバイト数で切っている: %q", got)
	}
}

func TestScanFileOnMissingPath(t *testing.T) {
	if _, err := ScanFile(filepath.Join(t.TempDir(), "無い.flix")); err == nil {
		t.Fatal("無いファイルでエラーが返らない")
	}
}

func TestFlixFilesIsSorted(t *testing.T) {
	root := t.TempDir()
	src := filepath.Join(root, "pkg", "src")
	if err := os.MkdirAll(filepath.Join(src, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, rel := range []string{"b.flix", "a.flix", filepath.Join("sub", "c.flix"), "d.txt"} {
		if err := os.WriteFile(filepath.Join(src, rel), []byte("mod M {}\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	var got []string
	for _, p := range FlixFiles(root, "pkg/src") {
		got = append(got, RelTo(root, p))
	}
	want := "pkg/src/a.flix,pkg/src/b.flix,pkg/src/sub/c.flix"
	if strings.Join(got, ",") != want {
		t.Fatalf("並びが %v (期待 %s)", got, want)
	}
}
