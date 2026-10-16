package ztable

// 何を守るか: z を数で決める行だけを拾うこと、表のあるパッケージでは表の外だけが鳴ること、
// 表の無いパッケージでは 2 本以上に散ったときだけ鳴ること、別のファイルの同じ数を添えること、
// 除外と --warn の扱い、instance SortingLayer[ の宣言も表になること、付け替えの関数の一覧、
// ゲームの除外 (z-table.local.json)、移行の口 (SortingLayer.z・leafAbsolute) を表の外で止めること。

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
		Table:          regexp.MustCompile(`\binstance\s+SortingLayer\s*\[`),
		Remap:          regexp.MustCompile(`\b(zMapped|zShiftedAll|zShifted|raiseZ|Depth\.placeOne|Depth\.place)\s*\(`),
		LayerZ:         regexp.MustCompile(`\bSortingLayer\.z\s*\(`),
		LeafAbs:        regexp.MustCompile(`\bleafAbsolute\s*\(`),
		LeafZLow:       0,
		LeafZHigh:      31,
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

func defsFor(files map[string]string) ([]string, map[string][]Def, map[string]bool) {
	r := testRules()
	var paths []string
	defs := map[string][]Def{}
	for p, body := range files {
		paths = append(paths, p)
		defs[p] = r.DefsOf(p, body)
	}
	return paths, defs, r.TablesOf(files)
}

func hitNames(hits []Hit) string {
	var out []string
	for _, h := range hits {
		out = append(out, filepath.Base(h.Path)+":"+h.Name)
	}
	return strings.Join(out, " ")
}

func TestWithTableOnlyOutsideTableFires(t *testing.T) {
	files, defs, tables := defsFor(map[string]string{
		"src/ZOrder.flix": "    def zBoard(): Int32 = 0",
		"src/View.flix":   "    def zPointer(): Int32 = 1000",
		"src/Fight.flix":  "    def zFight(): Int32 = ZOrder.zBoard() + 1",
	})
	if got := hitNames(testRules().PackageHits(files, defs, tables)); got != "View.flix:zPointer" {
		t.Fatalf("got %q", got)
	}
}

// 葉の中の小さな z (0..31) は表の外でも鳴らさない。32 以上と負の数は層の区画の数と
// 見分けが付かないので鳴る。
func TestWithTableLeafZIsQuiet(t *testing.T) {
	files, defs, tables := defsFor(map[string]string{
		"src/ZOrder.flix":    "    def zBoard(): Int32 = 0",
		"src/TitleView.flix": "    def zText(): Int32 = 2\n    def zTop(): Int32 = 31",
		"src/CardsView.flix": "    def zCard(): Int32 = 32\n    def zBack(): Int32 = -1",
	})
	if got := hitNames(testRules().PackageHits(files, defs, tables)); got != "CardsView.flix:zCard CardsView.flix:zBack" {
		t.Fatalf("got %q", got)
	}
}

// 表の無いパッケージは葉の数でも散らばりとして鳴る (葉の数を許すのは表を持つパッケージだけ)。
func TestWithoutTableLeafZStillScatters(t *testing.T) {
	files, defs, tables := defsFor(map[string]string{
		"src/ViewA.flix": "    def zA(): Int32 = 1",
		"src/ViewB.flix": "    def zB(): Int32 = 2",
	})
	if got := hitNames(testRules().PackageHits(files, defs, tables)); got != "ViewA.flix:zA ViewB.flix:zB" {
		t.Fatalf("got %q", got)
	}
}

func TestWithoutTableOneFileIsQuiet(t *testing.T) {
	files, defs, tables := defsFor(map[string]string{
		"src/View.flix": "    def zSky(): Int32 = 0\n    def zHero(): Int32 = 10",
		"src/Main.flix": "    def main(): Unit = ()",
	})
	if hits := testRules().PackageHits(files, defs, tables); len(hits) != 0 {
		t.Fatalf("鳴った: %s", hitNames(hits))
	}
}

func TestWithoutTableScatteredFilesFireWithSameValues(t *testing.T) {
	files, defs, tables := defsFor(map[string]string{
		"src/ViewScene.flix": "    def zPlain(): Int32 = 6",
		"src/ViewRoad.flix":  "    def zGround(): Int32 = 6",
	})
	hits := testRules().PackageHits(files, defs, tables)
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
		`"tablePattern":"\\binstance\\s+SortingLayer\\s*\\[",`+
		`"layerZPattern":"\\bSortingLayer\\.z\\s*\\(","leafAbsolutePattern":"\\bleafAbsolute\\s*\\(","leafZRange":[0,31],`+
		`"constPattern":"^\\s*(?:pub\\s+)?def\\s+(z[A-Z][A-Za-z0-9_]*)\\s*\\(\\s*\\)\\s*:\\s*Int32\\s*=\\s*(-?[0-9]+)\\s*(?://.*)?$",`+
		`"remapPattern":"\\b(zMapped|zShiftedAll|zShifted|raiseZ|Depth\\.placeOne|Depth\\.place)\\s*\\(",`+
		`"exempt":`+exempt+`}`)
	put("game/flix.toml", "")
	put("game/src/ZOrder.flix", "mod ZOrder {}")
	put("game/src/View.flix", "    def zPointer(): Int32 = 1000")
	put("game/test/TestView.flix", "    def zExpected(): Int32 = 5")
	put("other/flix.toml", "")
	put("other/src/View.flix", "    def zSky(): Int32 = 0")
	return root
}

func putFile(t *testing.T, root, rel, body string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
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
	if code != 1 || strings.Contains(errOut.String(), "zPointer = ") || !strings.Contains(errOut.String(), "zGone は bin/lint-rules/z-table.json の exempt") {
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

func TestRemapFiresOnlyWhereThereIsATable(t *testing.T) {
	withTable := map[string]string{
		"src/ZOrder.flix":  "mod ZOrder {\n    pub def f(): Int32 = 0\n}",
		"src/Opening.flix": "mod Opening {\n    def a(xs: List[Int32]): List[Int32] = xs |> Render.zMapped(z -> z / 4)\n    // Render.zMapped( はコメント\n}",
	}
	r := testRules()
	if got := hitNames(r.RemapHits(withTable, r.TablesOf(withTable))); got != "Opening.flix:zMapped" {
		t.Fatalf("got %q", got)
	}
	delete(withTable, "src/ZOrder.flix")
	if hits := r.RemapHits(withTable, r.TablesOf(withTable)); len(hits) != 0 {
		t.Fatalf("表の無いパッケージで鳴った: %s", hitNames(hits))
	}
}

// 1. 名前が ZOrder.flix でなくても、instance SortingLayer[ の宣言 (コメントの外) があれば表。
func TestInstanceDeclarationMakesATable(t *testing.T) {
	files, defs, tables := defsFor(map[string]string{
		"src/Layers.flix": "instance SortingLayer[Layer] {\n    pub def zRange(l: Layer): (Int32, Int32) = (0, 9)\n}\n    def zPointer(): Int32 = 5",
		"src/Note.flix":   "// instance SortingLayer[Layer] { はコメント\n    def zHud(): Int32 = 50",
	})
	if got := hitNames(testRules().PackageHits(files, defs, tables)); got != "Note.flix:zHud" {
		t.Fatalf("got %q", got)
	}
}

func TestLoadRulesNeedsTablePattern(t *testing.T) {
	root := writeRepo(t, `{}`)
	path := filepath.Join(root, RulesPath)
	data, _ := os.ReadFile(path)
	broken := strings.Replace(string(data), `"tablePattern"`, `"tablePatternX"`, 1)
	if err := os.WriteFile(path, []byte(broken), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadRules(root); err == nil || !strings.Contains(err.Error(), "tablePattern") {
		t.Fatalf("err=%v", err)
	}
}

// 2. 付け替えの関数は zMapped の他も鳴り、Name は呼んだ関数の名前になる。
func TestRemapCoversAllShiftFunctions(t *testing.T) {
	bodies := map[string]string{
		"src/ZOrder.flix": "mod ZOrder {}",
		"src/View.flix": "mod View {\n    def a() = Render.zShiftedAll(3, xs) |> List.map(Render.zShifted(1))\n" +
			"    def b() = Render.raiseZ(2, it)\n    def c() = Depth.place(r, y, xs) :: Depth.placeOne(r, y, p) :: Nil\n}",
	}
	r := testRules()
	if got := hitNames(r.RemapHits(bodies, r.TablesOf(bodies))); got != "View.flix:zShiftedAll View.flix:zShifted View.flix:raiseZ View.flix:Depth.place View.flix:Depth.placeOne" {
		t.Fatalf("got %q", got)
	}
}

// エンジンのパッケージ (表を持たない) で付け替えの関数を使っても鳴らない。
func TestRemapIgnoresEnginePackageWithoutTable(t *testing.T) {
	root := writeRepo(t, `{}`)
	putFile(t, root, "engine_world/flix.toml", "")
	putFile(t, root, "engine_world/src/Depth.flix", "mod Depth {\n    def a() = Render.zShiftedAll(3, Depth.place(r, y, xs))\n}")
	var out, errOut strings.Builder
	Run(&out, &errOut, root, []string{"--all"})
	if strings.Contains(errOut.String(), "engine_world/") {
		t.Fatalf("%s", errOut.String())
	}
}

// 3. ゲームの除外 (z-table.local.json) で黙り、古くなれば local のファイル名つきで鳴る。
func TestLocalExemptSilencesAndStaleNamesTheFile(t *testing.T) {
	root := writeRepo(t, `{}`)
	putFile(t, root, "bin/lint-rules/z-table.local.json",
		`{"exempt":{"game/src/View.flix::zPointer":"マウスの手は全部の層より上","game/src/View.flix::zGone":"消えた"}}`)
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, []string{"--all"})
	if err != nil || code != 1 || strings.Contains(errOut.String(), "zPointer = ") ||
		!strings.Contains(errOut.String(), "zGone は bin/lint-rules/z-table.local.json の exempt") {
		t.Fatalf("code=%d err=%v\n%s", code, err, errOut.String())
	}
}

func TestExemptInBothFilesIsAnError(t *testing.T) {
	root := writeRepo(t, `{"game/src/View.flix::zPointer":"エンジン側"}`)
	putFile(t, root, "bin/lint-rules/z-table.local.json", `{"exempt":{"game/src/View.flix::zPointer":"ゲーム側"}}`)
	if _, err := LoadRules(root); err == nil || !strings.Contains(err.Error(), "両方") {
		t.Fatalf("err=%v", err)
	}
}

// 4. 表を持つパッケージでは、表の外の移行の口を鳴らす (宣言・コメント・表の中は鳴らさない)。
// 名指しでも --all でも同じ。除外の鍵は "パス::呼んだ口の名前"。
func TestMigrationCallsOutsideTableFire(t *testing.T) {
	root := writeRepo(t, `{}`)
	putFile(t, root, "game/src/ZOrder.flix", "mod ZOrder {\n    instance SortingLayer[Layer] {}\n    def a() = SortingLayer.z(Layer.Hud, 0)\n}")
	putFile(t, root, "game/src/Scene.flix", "mod Scene {\n    def a() = SortingLayer.z(Layer.Scene, 1) + SortingLayer.z(Layer.Scene, 2)\n"+
		"    def b() = ZStack.leafAbsolute(xs)\n    // SortingLayer.z(Layer.Scene, 3)\n    pub def leafAbsolute(xs: List[Int32]) = xs\n}")
	for _, args := range [][]string{{"--all"}, {"game/src/Scene.flix"}} {
		var out, errOut strings.Builder
		code, err := Run(&out, &errOut, root, args)
		e := errOut.String()
		if err != nil || code != 1 || strings.Count(e, "Scene.flix:2 SortingLayer.z") != 2 ||
			!strings.Contains(e, "Scene.flix:3 leafAbsolute") || strings.Contains(e, "ZOrder.flix:") ||
			strings.Contains(e, "Scene.flix:4") || strings.Contains(e, "Scene.flix:5") {
			t.Fatalf("%v: code=%d err=%v\n%s", args, code, err, e)
		}
	}
}

// 表の無いパッケージ (エンジン・見本) の移行の口は鳴らさない。除外に載せた口は鳴らさない。
func TestMigrationOutsideTablePackageIsQuietAndExemptSilences(t *testing.T) {
	root := writeRepo(t, `{"game/src/Scene.flix::leafAbsolute": "理由"}`)
	putFile(t, root, "other/src/Scene.flix", "mod Scene {\n    def a() = SortingLayer.z(Layer.Scene, 1)\n}")
	putFile(t, root, "game/src/ZOrder.flix", "mod ZOrder {\n    instance SortingLayer[Layer] {}\n}")
	putFile(t, root, "game/src/Scene.flix", "mod Scene {\n    def b() = ZStack.leafAbsolute(xs)\n}")
	var out, errOut strings.Builder
	if code, _ := Run(&out, &errOut, root, []string{"other/src/Scene.flix", "game/src/Scene.flix"}); code != 0 {
		t.Fatalf("code=%d\n%s", code, errOut.String())
	}
}

// 表のファイルの中でも、葉の中の z (0..31) の外の数は鳴る (表に数を足して手前に出す古い形)。
// 層の範囲 (zRange の case の行) は def ではないので見ない。
func TestTableFileBigNumberFires(t *testing.T) {
	files, defs, tables := defsFor(map[string]string{
		"src/ZOrder.flix": "    def zShared(): Int32 = 3\n    def zConfirm(): Int32 = 950\n" +
			"    instance SortingLayer[Layer] {\n        case Layer.Talk => (200, 299)\n    }",
	})
	if got := hitNames(testRules().PackageHits(files, defs, tables)); got != "ZOrder.flix:zConfirm" {
		t.Fatalf("got %q", got)
	}
}
