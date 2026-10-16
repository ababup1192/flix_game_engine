package renderbudget

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// repoRoot はテストから見たリポジトリのルート (go/internal/renderbudget の 3 つ上)。
func repoRoot() string { return filepath.Join("..", "..", "..") }

// fixture は 1 ケース分の偽ゲームを作り、その根を返す。
func fixture(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
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
	code, err := Run(&out, &errOut, repoRoot(), append([]string{root}, args...))
	if err != nil {
		t.Fatalf("Run が失敗した: %v", err)
	}
	return out.String(), errOut.String(), code
}

func TestInsideBudgetIsGreen(t *testing.T) {
	root := fixture(t, map[string]string{
		"gallery/town.png":        "",
		"gallery/town.items.tsv":  "total=120\tpasses=1\tsurfaces=1\n",
		"gallery/town.static.tsv": "static=20\n",
		"reference/ITEMS.tsv":     "town\tdynamic=100\tstatic=20\n",
	})
	out, errOut, code := run(t, root)
	if code != 0 {
		t.Fatalf("終了コードが %d (期待 0)\n%s%s", code, out, errOut)
	}
	if out != "budget OK: 1 場面すべて予算の内側です\n" {
		t.Errorf("stdout が違う: %q", out)
	}
	if errOut != "" {
		t.Errorf("stderr に何か出た: %q", errOut)
	}
}

func TestOverDefaultCapFails(t *testing.T) {
	root := fixture(t, map[string]string{
		"gallery/town.png":        "",
		"gallery/town.items.tsv":  "total=2500\n",
		"gallery/town.static.tsv": "static=100\n",
	})
	out, errOut, code := run(t, root)
	if code != 1 {
		t.Fatalf("終了コードが %d (期待 1)", code)
	}
	want := "reference-check NG: 絵の値段\n" +
		"  town: 動的 2400 個 ≥ 上限 2000 個（既定）\n" +
		"  盤や群れを毎フレーム組んでいないか確かめてください（逆引き: make module Q=毎フレーム）。\n" +
		"  意図した増加なら make reference-update BUDGET=accept で基準を更新します。\n"
	if errOut != want {
		t.Errorf("stderr が違う:\n%s", errOut)
	}
	if out != "" {
		t.Errorf("stdout に何か出た: %q", out)
	}
}

func TestBriefHidesAdvice(t *testing.T) {
	root := fixture(t, map[string]string{
		"gallery/town.png":        "",
		"gallery/town.items.tsv":  "total=2500\n",
		"gallery/town.static.tsv": "static=100\n",
	})
	_, errOut, code := run(t, root, "--brief")
	if code != 1 {
		t.Fatalf("終了コードが %d (期待 1)", code)
	}
	if strings.Contains(errOut, "確かめてください") {
		t.Errorf("--brief なのに助言が出た:\n%s", errOut)
	}
}

func TestSceneCapOverridesDefault(t *testing.T) {
	files := map[string]string{
		"gallery/town.png":         "",
		"gallery/town.items.tsv":   "total=500\n",
		"reference/ITEMS.caps.tsv": "town\tcap=400\tnote=盤は毎フレーム組み直す\n",
	}
	root := fixture(t, files)
	_, errOut, code := run(t, root)
	if code != 1 {
		t.Fatalf("終了コードが %d (期待 1)", code)
	}
	if !strings.Contains(errOut, "town: 動的 500 個 ≥ 上限 400 個\n") {
		t.Errorf("場面ごとの上限が効いていない:\n%s", errOut)
	}
	if strings.Contains(errOut, "（既定）") {
		t.Errorf("場面ごとの上限なのに（既定）が付いた:\n%s", errOut)
	}
}

func TestCapWithoutNoteFails(t *testing.T) {
	root := fixture(t, map[string]string{
		"gallery/town.png":         "",
		"gallery/town.items.tsv":   "total=10\n",
		"reference/ITEMS.caps.tsv": "town\tcap=9999\n",
	})
	_, errOut, code := run(t, root)
	if code != 1 {
		t.Fatalf("終了コードが %d (期待 1)", code)
	}
	if !strings.Contains(errOut, "town: ITEMS.caps.tsv の cap に note がありません") {
		t.Errorf("note 忘れが鳴っていない:\n%s", errOut)
	}
	// note が無い行は caps に入らないので、上限は既定に戻る。
	if strings.Contains(errOut, "上限 9999") {
		t.Errorf("note の無い cap を上限に使った:\n%s", errOut)
	}
}

func TestCaplessOrderFollowsFile(t *testing.T) {
	root := fixture(t, map[string]string{
		"gallery/a.png":            "",
		"gallery/a.items.tsv":      "total=1\n",
		"reference/ITEMS.caps.tsv": "zz\tcap=1\naa\tcap=2\nzz\tcap=3\n",
	})
	_, errOut, _ := run(t, root)
	if !strings.HasPrefix(errOut, "reference-check NG: 絵の値段\n  zz: ") {
		t.Errorf("最初に出た名前が先に来ていない:\n%s", errOut)
	}
	if strings.Count(errOut, "zz: ITEMS.caps.tsv") != 1 {
		t.Errorf("同じ名前が 2 回出た:\n%s", errOut)
	}
}

func TestDriftOverBaselineFails(t *testing.T) {
	root := fixture(t, map[string]string{
		"gallery/town.png":       "",
		"gallery/town.items.tsv": "total=1000\n",
		"reference/ITEMS.tsv":    "town\tdynamic=100\n",
	})
	_, errOut, code := run(t, root)
	if code != 1 {
		t.Fatalf("終了コードが %d (期待 1)", code)
	}
	if !strings.Contains(errOut, "town: 動的 1000 個 — 基準 100 個から300 個を超えて増えたので増えすぎです\n") {
		t.Errorf("ドリフトの文面が違う:\n%s", errOut)
	}
}

func TestGateChangesVerbAndHead(t *testing.T) {
	root := fixture(t, map[string]string{
		"gallery/town.png":        "",
		"gallery/town.items.tsv":  "total=1000\n",
		"reference/ITEMS.old.tsv": "town\tdynamic=100\n",
	})
	_, errOut, code := run(t, root, "--gate", filepath.Join(root, "reference", "ITEMS.old.tsv"))
	if code != 1 {
		t.Fatalf("終了コードが %d (期待 1)", code)
	}
	if !strings.HasPrefix(errOut, "reference-update 中止: 絵の値段\n") {
		t.Errorf("--gate の見出しが違う:\n%s", errOut)
	}
	if !strings.Contains(errOut, "基準として焼けません\n") {
		t.Errorf("--gate の言い回しが違う:\n%s", errOut)
	}
	if !strings.Contains(errOut, "  意図した増加なら make reference-update BUDGET=accept で明示してください。\n") {
		t.Errorf("--gate の助言が違う:\n%s", errOut)
	}
}

func TestDriftFloorKeepsSmallScenesQuiet(t *testing.T) {
	// 基準 10 なら上限は max(15, 210) = 210。小さい場面は倍でも鳴らない。
	root := fixture(t, map[string]string{
		"gallery/town.png":       "",
		"gallery/town.items.tsv": "total=200\n",
		"reference/ITEMS.tsv":    "town\tdynamic=10\n",
	})
	_, errOut, code := run(t, root)
	if code != 0 {
		t.Fatalf("底上げが効いていない (終了コード %d)\n%s", code, errOut)
	}
}

func TestStaticExceedsTotalFails(t *testing.T) {
	root := fixture(t, map[string]string{
		"gallery/town.png":        "",
		"gallery/town.items.tsv":  "total=50\n",
		"gallery/town.static.tsv": "static=80\n",
	})
	_, errOut, code := run(t, root)
	if code != 1 {
		t.Fatalf("終了コードが %d (期待 1)", code)
	}
	if !strings.Contains(errOut, "town: 静的層の申告 80 が総数 50 を超えています\n") {
		t.Errorf("sanity の文面が違う:\n%s", errOut)
	}
}

func TestStaticWithoutItemsFails(t *testing.T) {
	root := fixture(t, map[string]string{
		"gallery/town.png":        "",
		"gallery/town.static.tsv": "static=80\n",
	})
	_, errOut, code := run(t, root)
	if code != 1 {
		t.Fatalf("終了コードが %d (期待 1)", code)
	}
	if !strings.Contains(errOut, "town: 静的層の申告だけがあり計測がありません（残骸か呼び順の誤り）\n") {
		t.Errorf("残骸の文面が違う:\n%s", errOut)
	}
}

func TestNoSidecarsIsNoteOnly(t *testing.T) {
	root := fixture(t, map[string]string{"gallery/town.png": ""})
	out, errOut, code := run(t, root)
	if code != 0 {
		t.Fatalf("終了コードが %d (期待 0)", code)
	}
	if out != "[budget] town: 予算 未計測（古い engine で生成した絵）\n" {
		t.Errorf("stdout が違う: %q", out)
	}
	if errOut != "" {
		t.Errorf("stderr に何か出た: %q", errOut)
	}
}

func TestEmptyStaticSidecarIsTreatedAsAbsent(t *testing.T) {
	// 中身が空の static.tsv は「無い」と同じ扱いで、残骸として鳴らない。
	root := fixture(t, map[string]string{
		"gallery/town.png":        "",
		"gallery/town.static.tsv": "\n",
	})
	out, errOut, code := run(t, root)
	if code != 0 {
		t.Fatalf("終了コードが %d (期待 0)\n%s", code, errOut)
	}
	if out != "[budget] town: 予算 未計測（古い engine で生成した絵）\n" {
		t.Errorf("stdout が違う: %q", out)
	}
}

func TestEmptyItemsSidecarCountsAsZero(t *testing.T) {
	// 中身が空の items.tsv は「読めた空の dict」なので total=0 として扱われる。
	root := fixture(t, map[string]string{
		"gallery/town.png":       "",
		"gallery/town.items.tsv": "\n",
	})
	out, _, code := run(t, root)
	if code != 0 {
		t.Fatalf("終了コードが %d (期待 0)", code)
	}
	if out != "budget OK: 1 場面すべて予算の内側です\n" {
		t.Errorf("stdout が違う: %q", out)
	}
}

func TestNoGalleryIsSilent(t *testing.T) {
	root := fixture(t, map[string]string{"reference/ITEMS.tsv": "town\tdynamic=1\n"})
	out, errOut, code := run(t, root)
	if code != 0 || out != "" || errOut != "" {
		t.Errorf("gallery が無いのに何か出た: %d %q %q", code, out, errOut)
	}
}

func TestScenesAreSortedByName(t *testing.T) {
	root := fixture(t, map[string]string{
		"gallery/b.png":       "",
		"gallery/b.items.tsv": "total=3000\n",
		"gallery/a.png":       "",
		"gallery/a.items.tsv": "total=3000\n",
	})
	_, errOut, _ := run(t, root)
	if !strings.Contains(errOut, "  a: ") || strings.Index(errOut, "  a: ") > strings.Index(errOut, "  b: ") {
		t.Errorf("場面の並びが名前順でない:\n%s", errOut)
	}
}

func TestRowMissingWantedKeyIsDropped(t *testing.T) {
	// dynamic を持たない行は基準の表に入らない (ドリフト判定に使われない)。
	root := fixture(t, map[string]string{
		"gallery/town.png":       "",
		"gallery/town.items.tsv": "total=1000\n",
		"reference/ITEMS.tsv":    "town\tstatic=100\n",
	})
	_, errOut, code := run(t, root)
	if code != 0 {
		t.Errorf("基準として使ってはいけない行で鳴った:\n%s", errOut)
	}
}

func TestCommentAndBlankLinesAreSkipped(t *testing.T) {
	root := fixture(t, map[string]string{
		"gallery/town.png":       "",
		"gallery/town.items.tsv": "total=1000\n",
		"reference/ITEMS.tsv":    "# town\tdynamic=100\n\ntown\tdynamic=900\n",
	})
	_, errOut, code := run(t, root)
	if code != 0 {
		t.Errorf("# の行を基準に使った:\n%s", errOut)
	}
}

func TestPyParseInt(t *testing.T) {
	cases := map[string]int64{
		"0": 0, "12": 12, "+12": 12, "-12": -12, " 7 ": 7, "1_000": 1000, "１２３": 123,
	}
	for in, want := range cases {
		got, ok := pyParseInt(in)
		if !ok || got != want {
			t.Errorf("pyParseInt(%q) = %d,%v (期待 %d)", in, got, ok, want)
		}
	}
	for _, in := range []string{"", "  ", "+", "1.0", "0x10", "1_", "_1", "1__0", "1 2", "abc"} {
		if got, ok := pyParseInt(in); ok {
			t.Errorf("pyParseInt(%q) が %d を返した (期待 失敗)", in, got)
		}
	}
}

func TestNonNumericFieldFallsBackToZero(t *testing.T) {
	root := fixture(t, map[string]string{
		"gallery/town.png":       "",
		"gallery/town.items.tsv": "total=abc\n",
	})
	out, _, code := run(t, root)
	if code != 0 || out != "budget OK: 1 場面すべて予算の内側です\n" {
		t.Errorf("数でない total を 0 に倒していない: %d %q", code, out)
	}
}

func TestDefaultRootIsCurrentDirectory(t *testing.T) {
	// 引数が無いときの根は "."。
	root := fixture(t, map[string]string{
		"gallery/town.png":       "",
		"gallery/town.items.tsv": "total=3000\n",
	})
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	abs, err := filepath.Abs(repoRoot())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(cwd)
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, abs, []string{"--brief"})
	if err != nil {
		t.Fatal(err)
	}
	if code != 1 || !strings.Contains(errOut.String(), "town: 動的 3000 個") {
		t.Errorf("カレントを根にしていない: %d %q", code, errOut.String())
	}
}
