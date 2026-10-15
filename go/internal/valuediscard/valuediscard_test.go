package valuediscard

// 何を守るか: let _ = を行のどこに置いても見つけること、
// コメント・文字列・_ で始まる名前・discard では鳴らないこと。

import (
	"regexp"
	"testing"
)

func testRules() *Rules {
	return &Rules{
		ScopeSuffixes: []string{".flix"},
		SkipPrefixes:  []string{"build/", "testdata/"},
		Pattern:       regexp.MustCompile(`(?:^|[\s({;>])let\s+_\s*(?::[^=]*)?=(?:[^=>]|$)`),
		Hint:          "直し方",
	}
}

func TestFindsLetUnderscore(t *testing.T) {
	for _, code := range []string{
		`        let _ = Log.warn("x");`,
		`    def f(): Int32 = let _ = g(); 1`,
		`        { let _ = List.forEach(h, xs);`,
		`        let _: Unit = g();`,
		`        let _ =`,
		`        xs |> List.map(x ->let _ = f(x); x)`,
	} {
		if hits := testRules().textHits("a.flix", code); len(hits) != 1 {
			t.Fatalf("%q: %d 件", code, len(hits))
		}
	}
}

func TestQuietOnLookAlikes(t *testing.T) {
	for _, code := range []string{
		"    // let _ = Log.warn(..) と書かない",    // コメント
		"    /// `let _ = f(x)` は消える",          // doc コメント
		`    let msg = "let _ = は消える";`,        // 文字列の中
		"    let _unused = 1;",                 // _ で始まる名前
		"    discard List.foldLeft(f, 0, xs);", // 効果のある式を捨てる正しい形
		"        case _ => 0",                  // match の矢印
	} {
		if hits := testRules().textHits("a.flix", code); len(hits) != 0 {
			t.Fatalf("%q で鳴った", code)
		}
	}
}

func TestNamedPathIgnoresSkipPrefixes(t *testing.T) {
	r := testRules()
	if !r.IsFlix("testdata/lint/x/sample.flix") || r.InScope("testdata/lint/x/sample.flix") {
		t.Fatal("名指しと全量の見分けが違う")
	}
}
