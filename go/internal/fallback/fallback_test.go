package fallback

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// repoRoot はテストから見たリポジトリのルート (go/internal/fallback の 3 つ上)。
func repoRoot() string { return filepath.Join("..", "..", "..") }

// fixture は 1 ケース分の入れ子を作り、その根を返す。
func fixture(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	rules, err := os.ReadFile(filepath.Join(repoRoot(), RulesPath))
	if err != nil {
		t.Fatal(err)
	}
	if files == nil {
		files = map[string]string{}
	}
	files[RulesPath] = string(rules)
	for rel, body := range files {
		path := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func run(t *testing.T, root string, args ...string) (string, string, int) {
	t.Helper()
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, args)
	if err != nil {
		t.Fatalf("Run が失敗した: %v", err)
	}
	return out.String(), errOut.String(), code
}

func rulesOf(t *testing.T) *Rules {
	t.Helper()
	rules, err := LoadRules(repoRoot())
	if err != nil {
		t.Fatal(err)
	}
	return rules
}

func scanFuncs(t *testing.T, src string) []Hit {
	t.Helper()
	return rulesOf(t).Scan("x.flix", pxlib.SplitLines(src))
}

const violating = `mod Demo {
    pub def getThing(path: String): String =
        match loadThing(path) {
            case Err(_) => bug!("getThing")
        }
}
`

func TestBugOutsideOrBugFires(t *testing.T) {
	root := fixture(t, map[string]string{"a/Sample.flix": violating})
	out, _, code := run(t, root, filepath.Join(root, "a/Sample.flix"))
	if code != 1 {
		t.Fatalf("終了コードが %d (期待 1)\n%s", code, out)
	}
	if !strings.Contains(out, ":4: getThing の中で bug! を呼んでいます") {
		t.Errorf("指摘の字面が違う:\n%s", out)
	}
	if !strings.Contains(out, "[lint-fallback] 決まり 2 違反 1 件 (docs/error-handling.md)。") {
		t.Errorf("まとめの行が違う:\n%s", out)
	}
}

func TestBugInsideOrBugPasses(t *testing.T) {
	src := strings.Replace(violating, "getThing", "loadThingOrBug", 1)
	root := fixture(t, map[string]string{"a/Sample.flix": src})
	out, _, code := run(t, root, filepath.Join(root, "a/Sample.flix"))
	if code != 0 {
		t.Fatalf("*OrBug の中の bug! で落ちた (終了コード %d)\n%s", code, out)
	}
	if !strings.Contains(out, "(bug! 1 件を検査 / 除外 ") {
		t.Errorf("検査した件数が出ていない:\n%s", out)
	}
}

func TestExemptKeyIsNotAViolation(t *testing.T) {
	rules := rulesOf(t)
	hits := []Hit{{Path: "render_gl/src/RenderTexture.flix", Lineno: 1, Func: "loadTexture"}}
	if got := rules.Violations(hits); len(got) != 0 {
		t.Errorf("EXEMPT の鍵が違反として残った: %v", got)
	}
	hits[0].Path = "render_gl/src/Other.flix"
	if got := rules.Violations(hits); len(got) != 1 {
		t.Errorf("鍵が違うのに除外された: %v", got)
	}
}

func TestStringLiteralBugIsNotACall(t *testing.T) {
	if hits := scanFuncs(t, `    pub def quiet(): String = "bug! と書いた文字列"`); len(hits) != 0 {
		t.Errorf("文字列リテラルの中の bug! を呼び出しと数えた: %v", hits)
	}
}

func TestCommentBugIsNotACall(t *testing.T) {
	if hits := scanFuncs(t, "    // ここは bug! と書いてあるだけのコメント"); len(hits) != 0 {
		t.Errorf("コメントの中の bug! を呼び出しと数えた: %v", hits)
	}
}

// WhyNot: Go の \b をそのまま使うと `あbug!` を拾ってしまう (Go の語は ASCII 限定)。
func TestUnicodeWordBoundary(t *testing.T) {
	cases := map[string]int{
		"    あbug!(1)":  0,
		"    9bug!(1)":  0,
		"    _bug!(1)":  0,
		"    x bug!(1)": 1,
		"    (bug!(1))": 1,
	}
	for src, want := range cases {
		if got := len(scanFuncs(t, src)); got != want {
			t.Errorf("%q の bug! を %d 件と数えた (期待 %d)", src, got, want)
		}
	}
}

func TestNestedDefTracksEnclosingFunction(t *testing.T) {
	src := `mod M {
    pub def outer(): Unit =
        let obj = new Runnable {
            def run(_this: Runnable): Unit = ()
        };
        bug!("outer")
}
`
	hits := scanFuncs(t, src)
	if len(hits) != 1 || hits[0].Func != "outer" {
		t.Fatalf("入れ子の def から出た後の関数名が違う: %+v", hits)
	}
}

// WhyNot: バイトで切ると日本語の抜粋が字の途中で切れて壊れる。
func TestExcerptIsCutByRunes(t *testing.T) {
	src := "    pub def f(): Unit = bug!(\"" + strings.Repeat("あ", 100) + "\")"
	hits := scanFuncs(t, src)
	if len(hits) != 1 {
		t.Fatalf("bug! を %d 件と数えた", len(hits))
	}
	if n := len([]rune(hits[0].Excerpt)); n != 78 {
		t.Errorf("抜粋が %d 文字 (期待 78)", n)
	}
}

func TestStripComments(t *testing.T) {
	cases := map[string]string{
		`let s = "a // b" // c`: `let s = "a // b" `,
		`x // y`:                `x `,
		`"\" // z"`:             `"\" // z"`,
		`no comment`:            `no comment`,
	}
	for in, want := range cases {
		if got := StripComments(in); got != want {
			t.Errorf("StripComments(%q) = %q (期待 %q)", in, got, want)
		}
	}
}

func TestInScope(t *testing.T) {
	rules := rulesOf(t)
	yes := []string{"engine/src/App.flix", "render_gl/src/a/b/C.flix"}
	no := []string{"engine/test/TestApp.flix", "templates/x/src/Game.flix",
		"examples/x/src/Game.flix", "engine/src/App.txt", "engine/srcApp.flix"}
	for _, p := range yes {
		if !rules.InScope(p) {
			t.Errorf("%s が対象外になった", p)
		}
	}
	for _, p := range no {
		if rules.InScope(p) {
			t.Errorf("%s が対象になった", p)
		}
	}
}

func TestSelfTestPasses(t *testing.T) {
	out, errOut, code := run(t, repoRoot(), "--self-test")
	if code != 0 {
		t.Fatalf("self-test が落ちた (%d): %s", code, errOut)
	}
	if !strings.HasPrefix(out, "[lint-fallback] self-test OK (除外 ") {
		t.Errorf("self-test の字面が違う: %q", out)
	}
}

func TestUnknownFileIsSkipped(t *testing.T) {
	root := fixture(t, nil)
	out, _, code := run(t, root, "no/such/File.flix")
	if code != 0 || !strings.Contains(out, "(bug! 0 件を検査") {
		t.Errorf("無いファイルで止まった: %d %q", code, out)
	}
}

// TestStagedDiffIsScanned は既定の口 (ステージした差分の + 行だけ) を端から端まで動かす。
// WhyNot: 本物のリポの索引を使わないのは、他の人の作業中の索引を触らないため。
func TestStagedDiffIsScanned(t *testing.T) {
	root := fixture(t, nil)
	for _, args := range [][]string{
		{"init", "-q"},
		{"config", "user.email", "t@example.com"},
		{"config", "user.name", "t"},
	} {
		if _, err := git(root, args...); err != nil {
			t.Skipf("git が使えない: %v", err)
		}
	}
	path := filepath.Join(root, "engine", "src", "Sample.flix")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(violating), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := git(root, "add", "engine/src/Sample.flix"); err != nil {
		t.Fatal(err)
	}
	out, _, code := run(t, root)
	if code != 1 {
		t.Fatalf("ステージした違反を拾えていない (%d):\n%s", code, out)
	}
	if !strings.Contains(out, "engine/src/Sample.flix:4: getThing の中で bug! を呼んでいます") {
		t.Errorf("差分から拾った行が違う:\n%s", out)
	}
}
