package sprite

// 判定 1 つずつを最小の格子で縛る。文面は見本 (testdata) が縛るので、
// ここでは「鳴る / 鳴らない」と座標・個数だけを見る。

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func loadedRules(t *testing.T) *Rules {
	t.Helper()
	rules, err := LoadRules(repoRoot(t))
	if err != nil {
		t.Fatalf("規約を読めない: %v", err)
	}
	return rules
}

// docOfRows は legend 1 色・スプライト 1 個の最小 Doc を作る。
func docOfRows(t *testing.T, rows ...string) map[string]any {
	t.Helper()
	frame := make([]any, 0, len(rows))
	for _, row := range rows {
		frame = append(frame, row)
	}
	return map[string]any{
		"legend": map[string]any{"i": "ink", "s": "skin", "c": "cloth"},
		"sprites": map[string]any{
			"hero": map[string]any{"frames": map[string]any{"idle": frame}},
		},
	}
}

func lines(t *testing.T, rows ...string) (problems, warnings []string) {
	t.Helper()
	p, w, _, _ := loadedRules(t).checkDoc(docOfRows(t, rows...), nil, false)
	return p, w
}

func onlyLine(t *testing.T, got []string, needle string) string {
	t.Helper()
	for _, line := range got {
		if strings.Contains(line, needle) {
			return line
		}
	}
	t.Fatalf("「%s」を含む行が出ない (実際: %v)", needle, got)
	return ""
}

// orphan と connect は必ず同時に鳴る。
// WhyNot: 1 ケース 1 規則に割れないのは、MIN_ORPHAN_CELLS と MIN_CONNECT_CELLS が
// どちらも 4 で、浮いた 1 画素はそれ自体が 1 つの独立した 4 連結の塊になるため。
func TestOrphanAlwaysFiresWithConnect(t *testing.T) {
	problems, warnings := lines(t, "ii...", "ii..s", ".....", ".....")
	if got := onlyLine(t, problems, "浮いた 1 画素"); !strings.Contains(got, "(4,1)") {
		t.Errorf("浮いた画素の座標が違う: %s", got)
	}
	if got := onlyLine(t, warnings, "塊に分かれている"); !strings.Contains(got, "2 個の塊") {
		t.Errorf("塊の数が違う: %s", got)
	}
}

func TestOrphanSilentBelowMinCells(t *testing.T) {
	problems, warnings := lines(t, "i.i", "...")
	if len(problems) != 0 {
		t.Errorf("3 画素未満の粒で NG が出た: %v", problems)
	}
	for _, line := range warnings {
		if strings.Contains(line, "塊に分かれている") {
			t.Errorf("3 画素未満の粒で塊の分裂が出た: %s", line)
		}
	}
}

func TestConnectSplitsOnDiagonalTouch(t *testing.T) {
	_, warnings := lines(t, "ii....", "ii....", "..iii.", "..iii.")
	onlyLine(t, warnings, "塊に分かれている")
}

func TestTextureFrameSkipsShapeRules(t *testing.T) {
	problems, warnings := lines(t, "isis", "sisi", "isis", "sisi")
	if len(problems)+len(warnings) != 0 {
		t.Errorf("塗り率 90%% 以上のコマに形の規則が掛かった: %v %v", problems, warnings)
	}
}

func TestJaggyCountsStairNoise(t *testing.T) {
	_, warnings := lines(t,
		"iii............",
		"iiii...........",
		"iiiiiii........",
		"iiiiiiii.......",
		"iiiiiiiiiii....",
		"iiiiiiiiiiii...",
		"iiiiiiiiiiiiiii",
	)
	onlyLine(t, warnings, "輪郭の階段が")
}

func TestBandingFindsInnerRimOnlyColor(t *testing.T) {
	doc := map[string]any{
		"legend": map[string]any{"i": "ink", "s": "skin", "c": "cloth", "g": "glow"},
		"sprites": map[string]any{"hero": map[string]any{"frames": map[string]any{"idle": []any{
			"...........",
			"..iiiiiii..",
			".iggggggsi.",
			".igcccccsi.",
			".igcccccsi.",
			".igcccccsi.",
			".igssssssi.",
			"..iiiiiii..",
			"...........",
		}}}},
	}
	_, warnings, _, _ := loadedRules(t).checkDoc(doc, nil, false)
	onlyLine(t, warnings, "banding の疑い")
}

func TestCornerDoubleSpot(t *testing.T) {
	_, warnings := lines(t, "......", ".ii...", "..ii..", "......")
	onlyLine(t, warnings, "2 重")
}

func TestSilhouetteSparse(t *testing.T) {
	_, warnings := lines(t, "i.........", "..........", "..........", "..........", ".........i")
	if got := onlyLine(t, warnings, "スカスカ"); !strings.Contains(got, "枠 10x5 の 4%") {
		t.Errorf("スカスカの表示がずれている: %s", got)
	}
}

func TestSilhouetteElongatedIgnoredWhenSpanningGrid(t *testing.T) {
	// 格子の端から端まで届く帯はタイルの縁なので細長さを言わない。
	_, warnings := lines(t, "iiiiiiii")
	for _, line := range warnings {
		if strings.Contains(line, "細長すぎる") {
			t.Errorf("格子いっぱいの帯で細長さが出た: %s", line)
		}
	}
}

func TestStructureUnknownLegendChar(t *testing.T) {
	problems, _ := lines(t, "iii", "iiZ")
	onlyLine(t, problems, "legend に無い文字 'Z'")
}

func TestExemptRulesNarrowToListed(t *testing.T) {
	doc := docOfRows(t, "ii...", "ii..s", ".....", ".....")
	hero := doc["sprites"].(map[string]any)["hero"].(map[string]any)
	hero["lint-sprite"] = "対象外(orphan, connect) — 火の粉は浮かせたい"
	problems, warnings, excluded, _ := loadedRules(t).checkDoc(doc, nil, false)
	if len(problems)+len(warnings) != 0 {
		t.Errorf("除外したのに鳴った: %v %v", problems, warnings)
	}
	if len(excluded) != 1 || excluded[0].sprite != "hero" || excluded[0].reason != "火の粉は浮かせたい" {
		t.Errorf("除外の記録がずれている: %+v", excluded)
	}
}

func TestExemptWithoutParensCoversAllRules(t *testing.T) {
	doc := docOfRows(t, "ii", "i")
	doc["lint-sprite"] = "対象外 — 移行中の下書き"
	problems, _, excluded, _ := loadedRules(t).checkDoc(doc, nil, false)
	if len(problems) != 0 {
		t.Errorf("全規則の除外が効いていない: %v", problems)
	}
	if len(excluded) != 1 || excluded[0].sprite != "" {
		t.Errorf("ファイル単位の除外になっていない: %+v", excluded)
	}
}

func TestExemptWithoutReason(t *testing.T) {
	got, ok := loadedRules(t).exemptOf("対象外(jaggy)")
	if !ok || got.reason != noReason {
		t.Fatalf("理由が無いときの文面がずれている: %+v", got)
	}
}

// palette は 2 つの独立した判定に分かれている。ΔE 側と色数上限側の両方を縛る。
func TestPaletteDeltaEWarnsOnCloseColors(t *testing.T) {
	doc := map[string]any{
		"legend":  map[string]any{"a": "@one", "b": "@two"},
		"sprites": map[string]any{},
	}
	hexes := map[string]string{"@one": "#804030", "@two": "#814131"}
	_, warnings, _, _ := loadedRules(t).checkDoc(doc, hexes, true)
	onlyLine(t, warnings, "が近すぎる (ΔE")
}

func TestPaletteDeltaESilentOnFarColors(t *testing.T) {
	doc := map[string]any{"legend": map[string]any{}, "sprites": map[string]any{}}
	hexes := map[string]string{"@ink": "#000000", "@paper": "#ffffff"}
	_, warnings, _, _ := loadedRules(t).checkDoc(doc, hexes, true)
	if len(warnings) != 0 {
		t.Errorf("黒と白が近すぎる判定になっている: %v", warnings)
	}
}

func TestPaletteColorCountCap(t *testing.T) {
	legend := map[string]any{}
	row := ""
	for _, c := range "abcdefghijklm" {
		legend[string(c)] = "c" + string(c)
		row += string(c)
	}
	doc := map[string]any{
		"legend":  legend,
		"sprites": map[string]any{"hero": map[string]any{"frames": map[string]any{"idle": []any{row}}}},
	}
	_, warnings, _, _ := loadedRules(t).checkDoc(doc, nil, false)
	if got := onlyLine(t, warnings, "色数"); !strings.Contains(got, "色数 13 が目安 12") {
		t.Errorf("色数の勘定がずれている: %s", got)
	}
}

// TestSelfTestPasses は --self-test が全例通り、例の数が変わっていないかを見る。
func TestSelfTestPasses(t *testing.T) {
	var out, errOut strings.Builder
	if code := loadedRules(t).selfTest(&out, &errOut); code != 0 {
		t.Fatalf("self-test が落ちた: %s", errOut.String())
	}
	if out.String() != "self-test OK: 18 例\n" {
		t.Fatalf("self-test の出力がずれている: %q", out.String())
	}
}

// TestFixturesMatchExpected は testdata/lint/sprite/ の見本を Go だけで通す。
// WhyNot: 見本の突き合わせを外の道具に任せないのは、go test だけで
// 出力の退行を捕まえられるようにするため。
func TestFixturesMatchExpected(t *testing.T) {
	root := repoRoot(t)
	// 見本の expected.txt は「リポジトリのルートから相対パスで呼ぶ」形で記録されている。
	t.Chdir(root)
	dirs, err := os.ReadDir(filepath.Join(root, "testdata", "lint", "sprite"))
	if err != nil {
		t.Skipf("見本が無い: %v", err)
	}
	for _, d := range dirs {
		if !d.IsDir() {
			continue
		}
		caseDir := filepath.Join(root, "testdata", "lint", "sprite", d.Name())
		want, err := os.ReadFile(filepath.Join(caseDir, "expected.txt"))
		if err != nil {
			continue
		}
		input := filepath.Join("testdata", "lint", "sprite", d.Name(), "input.sprite.json")
		var out, errOut strings.Builder
		code, err := Run(&out, &errOut, root, []string{input})
		if err != nil {
			t.Fatalf("%s: 検査が動かなかった: %v", d.Name(), err)
		}
		// compare.sh と同じ順 (2>&1 では stderr が先) に組み立てる。
		got := errOut.String() + out.String() + "[exit=" + strconv.Itoa(code) + "]\n"
		if got != string(want) {
			t.Errorf("%s:\n--- 期待\n%s--- 実際\n%s", d.Name(), want, got)
		}
	}
}

// legend の値が "" の字は、エンジン（不透明に塗る）と検査（透明として数える）が食い違うので NG にする。
func TestStructureEmptyLegendKey(t *testing.T) {
	doc := docOfRows(t, "ii", "ix")
	doc["legend"].(map[string]any)["x"] = ""
	p, _, _, _ := loadedRules(t).checkDoc(doc, nil, false)
	onlyLine(t, p, "legend の字 'x' の色キーが空")
}

// CheckDoc は対象外の指定を当て、コマの件に場所を付けて返す。
func TestCheckDocFindingsCarryFrameAndExempt(t *testing.T) {
	doc := docOfRows(t, "ii...", "ii..s", ".....", ".....")
	got, _, _ := loadedRules(t).CheckDoc(doc, nil, false)
	found := false
	for _, f := range got {
		if f.Rule == "orphan" && f.Sprite == "hero" && f.Frame == "idle" && f.HasAt && f.At.X == 4 && f.At.Y == 1 {
			found = true
		}
	}
	if !found {
		t.Fatalf("orphan に場所が付かない: %+v", got)
	}
	doc["sprites"].(map[string]any)["hero"].(map[string]any)["lint-sprite"] = "対象外(orphan, connect) — 火の粉"
	got, _, _ = loadedRules(t).CheckDoc(doc, nil, false)
	if len(got) != 0 {
		t.Fatalf("対象外が当たらない: %+v", got)
	}
}
