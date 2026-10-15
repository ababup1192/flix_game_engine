package ztable

// 何を守るか: z を数で決める行だけを拾うこと、表のあるパッケージでは表の外だけが鳴ること、
// 表の無いパッケージでは 2 本以上に散ったときだけ鳴ること、別のファイルの同じ数を添えること、
// 除外と --warn の扱い。

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func testRules() *Rules {
	return &Rules{
		ScopeSuffixes:  []string{".flix"},
		SkipPrefixes:   []string{"build/", "testdata/"},
		SkipDirNames:   []string{"lib", "test"},
		TableFileNames: []string{"ZOrder.flix"},
		Const:          regexp.MustCompile(`^\s*(?:pub\s+)?def\s+(z[A-Z][A-Za-z0-9_]*)\s*\(\s*\)\s*:\s*Int32\s*=\s*(-?[0-9]+)\s*(?://.*)?$`),
		Exempt:         map[string]string{},
	}
}

func names(defs []Def) string {
	var out []string
	for _, d := range defs {
		out = append(out, d.Name+"="+d.Value)
	}
	return strings.Join(out, " ")
}

func TestPicksOnlyZConstantsDefinedByNumber(t *testing.T) {
	src := strings.Join([]string{
		"    def zHero(): Int32 = 10",
		"    pub def zHud(): Int32 = -3   // 手前",
		"    def zDust(): Int32 = zHero() + 2",
		"    def zoom(): Int32 = 4",
		"    // def zOld(): Int32 = 7",
		"    def zTable(): Float64 = 1.0",
	}, "\n")
	if got := names(testRules().DefsOf("a.flix", src)); got != "zHero=10 zHud=-3" {
		t.Fatalf("got %q", got)
	}
}

func defsFor(files map[string]string) ([]string, map[string][]Def) {
	r := testRules()
	var paths []string
	defs := map[string][]Def{}
	for p, body := range files {
		paths = append(paths, p)
		defs[p] = r.DefsOf(p, body)
	}
	return paths, defs
}

func hitNames(hits []Hit) string {
	var out []string
	for _, h := range hits {
		out = append(out, filepath.Base(h.Path)+":"+h.Name)
	}
	return strings.Join(out, " ")
}

func TestWithTableOnlyOutsideTableFires(t *testing.T) {
	files, defs := defsFor(map[string]string{
		"src/ZOrder.flix": "    def zBoard(): Int32 = 0",
		"src/View.flix":   "    def zPointer(): Int32 = 1000",
		"src/Fight.flix":  "    def zFight(): Int32 = ZOrder.zBoard() + 1",
	})
	if got := hitNames(testRules().PackageHits(files, defs)); got != "View.flix:zPointer" {
		t.Fatalf("got %q", got)
	}
}

func TestWithoutTableOneFileIsQuiet(t *testing.T) {
	files, defs := defsFor(map[string]string{
		"src/View.flix": "    def zSky(): Int32 = 0\n    def zHero(): Int32 = 10",
		"src/Main.flix": "    def main(): Unit = ()",
	})
	if hits := testRules().PackageHits(files, defs); len(hits) != 0 {
		t.Fatalf("鳴った: %s", hitNames(hits))
	}
}

func TestWithoutTableScatteredFilesFireWithSameValues(t *testing.T) {
	files, defs := defsFor(map[string]string{
		"src/ViewScene.flix": "    def zPlain(): Int32 = 6",
		"src/ViewRoad.flix":  "    def zGround(): Int32 = 6",
	})
	hits := testRules().PackageHits(files, defs)
	if got := hitNames(hits); got != "ViewRoad.flix:zGround ViewScene.flix:zPlain" {
		t.Fatalf("got %q", got)
	}
	if got := strings.Join(hits[0].Same, ""); got != "zPlain (src/ViewScene.flix)" {
		t.Fatalf("同じ数: %q", got)
	}
}

// 偽のリポを組んで Run を通す (パッケージの探し方・除外・--warn)。
func writeRepo(t *testing.T, exempt string) string {
	t.Helper()
	root := t.TempDir()
	put := func(rel, body string) {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	put("bin/lint-rules/z-table.json", `{"scopeSuffixes":[".flix"],"skipPrefixes":["testdata/"],`+
		`"skipDirNames":["lib","test"],"tableFileNames":["ZOrder.flix"],`+
		`"constPattern":"^\\s*(?:pub\\s+)?def\\s+(z[A-Z][A-Za-z0-9_]*)\\s*\\(\\s*\\)\\s*:\\s*Int32\\s*=\\s*(-?[0-9]+)\\s*(?://.*)?$",`+
		`"exempt":`+exempt+`}`)
	put("game/flix.toml", "")
	put("game/src/ZOrder.flix", "mod ZOrder {}")
	put("game/src/View.flix", "    def zPointer(): Int32 = 1000")
	put("game/test/TestView.flix", "    def zExpected(): Int32 = 5")
	put("other/flix.toml", "")
	put("other/src/View.flix", "    def zSky(): Int32 = 0")
	return root
}

func TestRunNamedFileReadsItsPackage(t *testing.T) {
	root := writeRepo(t, `{}`)
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, []string{"game/src/View.flix", "other/src/View.flix"})
	if err != nil || code != 1 || !strings.Contains(errOut.String(), "game/src/View.flix:1 zPointer = 1000") ||
		!strings.Contains(errOut.String(), "表 (game/src/ZOrder.flix) の外") ||
		strings.Contains(errOut.String(), "other/") {
		t.Fatalf("code=%d err=%v\n%s", code, err, errOut.String())
	}
}

func TestRunAllSkipsTestDirs(t *testing.T) {
	root := writeRepo(t, `{}`)
	var out, errOut strings.Builder
	Run(&out, &errOut, root, []string{"--all"})
	if strings.Contains(errOut.String(), "zExpected") || !strings.Contains(errOut.String(), "zPointer") {
		t.Fatalf("%s", errOut.String())
	}
}

func TestExemptSilencesAndStaleExemptFires(t *testing.T) {
	root := writeRepo(t, `{"game/src/View.flix::zPointer":"マウスの手は全部の層より上","game/src/View.flix::zGone":"消えた"}`)
	var out, errOut strings.Builder
	code, _ := Run(&out, &errOut, root, []string{"--all"})
	if code != 1 || strings.Contains(errOut.String(), "zPointer = ") || !strings.Contains(errOut.String(), "zGone は exempt") {
		t.Fatalf("code=%d\n%s", code, errOut.String())
	}
}

func TestWarnKeepsOutputButExitsZero(t *testing.T) {
	root := writeRepo(t, `{}`)
	var out, errOut strings.Builder
	code, _ := Run(&out, &errOut, root, []string{"--warn", "game/src/View.flix"})
	if code != 0 || !strings.Contains(errOut.String(), "zPointer") {
		t.Fatalf("code=%d\n%s", code, errOut.String())
	}
}
