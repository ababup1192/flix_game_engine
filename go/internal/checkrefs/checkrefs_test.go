package checkrefs

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newChecker(t *testing.T) *checker {
	t.Helper()
	root := repoRoot(t)
	rules, err := LoadRules(root)
	if err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	return &checker{rules: rules, root: root, out: &out, errOut: &errOut}
}

// TestAdjacentPathsAreNotSwallowed は、後読みで捨てた当たりの内側から始まる次の当たりを
// 取りこぼさないことを見る（先読み・後読みの文字まで消費する書き方だと消える）。
func TestAdjacentPathsAreNotSwallowed(t *testing.T) {
	c := newChecker(t)
	got := c.extractPaths("-docs/*bin/y")
	if len(got) != 1 || got[0] != "bin/y" {
		t.Fatalf("隣り合う語を取りこぼしました: %q", got)
	}
}

// TestAdjacentEchoIsNotSwallowed は先頭の \b を外した側の取りこぼしを見る。
func TestAdjacentEchoIsNotSwallowed(t *testing.T) {
	c := newChecker(t)
	if got := c.stripMkComments(`echoecho "x"`); got != `echoecho "x"` {
		t.Fatalf("語の途中の echo に当たりました: %q", got)
	}
	if got := c.stripMkComments(`echo "x" echo "y"`); got != `echo '' echo ''` {
		t.Fatalf("並んだ echo を落とし切れません: %q", got)
	}
}

func TestExtractPaths(t *testing.T) {
	c := newChecker(t)
	cases := []struct {
		text string
		want []string
	}{
		{".bin/a", nil},                        // 直前が . なので当てない
		{"x$bin/a docs/b", []string{"docs/b"}}, // 直前が $ なので当てない
		{"あdocs/a bin/b", []string{"bin/b"}},   // 直前が漢字かな = 語の文字
		{"*bin/x", []string{"bin/x"}},          // * は後読みの集合に入っていない
		{"bin/a.py, docs/b.md)", []string{"bin/a.py", "docs/b.md"}},
		{"$(ENGINE)/bin/x", nil}, // SKIP_MARKS の $(
		{"bin/__pycache__/x", nil},
		{"docs/<name>.md", nil},
		{"bin/a bin/a", []string{"bin/a"}},
	}
	for _, tc := range cases {
		got := c.extractPaths(tc.text)
		if len(got) != len(tc.want) {
			t.Errorf("%q: %q が欲しいのに %q", tc.text, tc.want, got)
			continue
		}
		for i := range got {
			if got[i] != tc.want[i] {
				t.Errorf("%q: %q が欲しいのに %q", tc.text, tc.want, got)
				break
			}
		}
	}
}

// 何を見るか: Makefile のコメント落としが、NBSP や全角空白も空白と数えること。
func TestStripMkComments(t *testing.T) {
	c := newChecker(t)
	cases := [][2]string{
		{"a #b", "a "},
		{"a #b", "a "}, // NBSP も \s
		{"a#b", "a#b"}, // 直前が空白でないので落とさない
		{"\t@# あ", "\t"},
		{"\t@echo \"docs/x.md は無い\"", "\t@echo ''"},
		{"\tprintf 'bin/x'", "\tprintf ''"},
		{"\tあecho \"x\" bin/y", "\tあecho \"x\" bin/y"},
	}
	for _, tc := range cases {
		if got := c.stripMkComments(tc[0]); got != tc[1] {
			t.Errorf("%q: %q が欲しいのに %q", tc[0], tc[1], got)
		}
	}
}

func TestPathLess(t *testing.T) {
	// 要素ごとに比べる（文字列そのものだと - が / より小さくて逆になる）。
	if !pathLess("templates/rpg/Makefile", "templates/rpg-starter/Makefile") {
		t.Error("要素ごとの並べ方になっていません")
	}
	if pathLess("mk/game.mk", "mk/base.mk") {
		t.Error("同じ深さの名前の順が逆です")
	}
}

func TestParentsOf(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"studio/app/resources/engine", []string{"studio/app/resources", "studio/app", "studio", "."}},
		{"bundle", []string{"."}},
		{".", nil},
		{"/a/b", []string{"/a", "/"}},
	}
	for _, tc := range cases {
		got := parentsOf(tc.in)
		if strings.Join(got, "|") != strings.Join(tc.want, "|") {
			t.Errorf("%q: %q が欲しいのに %q", tc.in, tc.want, got)
		}
	}
}

func TestFnmatchPy(t *testing.T) {
	cases := []struct {
		name, pat string
		want      bool
	}{
		{"a.md", "*.md", true},
		{"a.mdx", "*.md", false},
		{".hidden.md", "*.md", true},
		{"game.mk", "*.mk", true},
		{"abc", "a?c", true},
		{"ac", "a?c", false},
		{"anything", "*", true},
	}
	for _, tc := range cases {
		if got := fnmatchPy(tc.name, tc.pat); got != tc.want {
			t.Errorf("fnmatchPy(%q, %q) = %v", tc.name, tc.pat, got)
		}
	}
}

// TestBundleUsage は --bundle に DIR が無いときの出し方と終了コードを見る。
func TestBundleUsage(t *testing.T) {
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, repoRoot(t), []string{"--bundle"})
	if err != nil {
		t.Fatal(err)
	}
	if code != 2 {
		t.Errorf("終了コードは 2 のはずが %d", code)
	}
	if errOut.String() != "usage: fge check-refs --bundle DIR [--windows]\n" {
		t.Errorf("使い方の出し方が違います: %q", errOut.String())
	}
	if out.String() != "" {
		t.Errorf("stdout には何も出ないはずが %q", out.String())
	}
}

// TestBundleNotFound は無いフォルダを渡したときの出し方を見る。
func TestBundleNotFound(t *testing.T) {
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, repoRoot(t), []string{"--bundle", "nowhere-at-all"})
	if err != nil {
		t.Fatal(err)
	}
	if code != 1 {
		t.Errorf("終了コードは 1 のはずが %d", code)
	}
	if errOut.String() != "バンドルが見つかりません: nowhere-at-all\n" {
		t.Errorf("出し方が違います: %q", errOut.String())
	}
}

// TestRulesFileMissingStops は規約が読めないとき 2 で止まることを見る。
func TestRulesFileMissingStops(t *testing.T) {
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, t.TempDir(), nil)
	if err == nil {
		t.Fatal("規約が無いのにエラーになりません")
	}
	if code != 2 {
		t.Errorf("終了コードは 2 のはずが %d", code)
	}
}

func TestExistsInWithGlob(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "docs"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "docs", "a.md"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	c := newChecker(t)
	if !c.existsIn(root, "docs/*.md") {
		t.Error("docs/*.md が見つかりません")
	}
	if c.existsIn(root, "docs/*.txt") {
		t.Error("docs/*.txt が見つかってしまいました")
	}
	if c.existsIn(root, "docs/b.md") {
		t.Error("無いファイルが見つかってしまいました")
	}
}

// 組み立てで名前を付け替えて作る物 (package.fpkg → engine_full.fpkg) は、元がリポにあれば書き損じではない。
// 元も無ければ今までどおり止める。
func TestBundleManifestAcceptsRenamedArtifact(t *testing.T) {
	root := t.TempDir()
	write := func(rel, body string) {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("bin/lint-rules/stage-engine.json", `{"items":[{"src":"engine_full/artifact/package.fpkg","dest":"engine_full/artifact/engine_full.fpkg"}]}`)
	c := &checker{rules: &Rules{BundleRequired: []string{"engine_full/artifact/engine_full.fpkg"}}, root: root}
	var problems []string
	c.checkBundleManifest(&problems)
	if len(problems) != 1 {
		t.Fatalf("元が無いのに通った: %v", problems)
	}
	write("engine_full/artifact/package.fpkg", "fpkg")
	problems = nil
	c.checkBundleManifest(&problems)
	if len(problems) != 0 {
		t.Fatalf("元があるのに止まった: %v", problems)
	}
}
