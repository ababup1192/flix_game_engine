package precommit

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// repoRoot はこのリポジトリのルート（テストの cwd は go/internal/precommit）。
// WhyNot: 相対のまま持ち回らないのは、Run が根へ chdir するため。
func repoRoot(t *testing.T) string {
	t.Helper()
	abs, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return abs
}

// fakeRepo は規約データだけを持つ使い捨ての根を作る。bin/ に何も置かないのは、
// 検査の中身がこのバイナリ自身の中にあり、外の道具の実在に左右されないことを
// テストの形でも押さえるため。
func fakeRepo(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	rules := filepath.Join(root, "bin", "lint-rules")
	if err := os.MkdirAll(rules, 0o755); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(repoRoot(t), RulesPath))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(rules, "precommit.json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

// gateRun は 1 回ゲートを走らせて「親の知らせ・子の stdout・子の stderr・終了コード」を返す。
func gateRun(t *testing.T, root string, args []string, lints map[string]Lint, images func(string) int) (string, string, string, int) {
	t.Helper()
	var parent, child, childErr strings.Builder
	code, err := Run(&parent, Options{
		Root: root, Args: args, Stdout: &child, Stderr: &childErr,
		Lints: lints, Images: images,
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	return parent.String(), child.String(), childErr.String(), code
}

// okLints は「何も言わずに通る」検査の表。
func okLints(t *testing.T) map[string]Lint {
	t.Helper()
	rules, err := LoadRules(repoRoot(t))
	if err != nil {
		t.Fatal(err)
	}
	m := map[string]Lint{}
	for _, c := range rules.Checks {
		m[c.Sub] = func(out, errOut *strings.Builder, args []string) int { return 0 }
	}
	return m
}

func TestStagedNothingSaysNothing(t *testing.T) {
	root := fakeRepo(t)
	parent, _, _, code := gateRun(t, root, []string{"--files", "notes.txt"}, okLints(t), nil)
	if parent != "" || code != 0 {
		t.Errorf("何も鳴らないはずが parent=%q code=%d", parent, code)
	}
}

func TestChecksRunInRulesOrder(t *testing.T) {
	root := fakeRepo(t)
	var order []string
	lints := map[string]Lint{}
	rules, err := LoadRules(repoRoot(t))
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range rules.Checks {
		sub := c.Sub
		lints[sub] = func(out, errOut *strings.Builder, args []string) int {
			order = append(order, sub)
			return 0
		}
	}
	staged := []string{"--files", "engine/src/A.flix", "a.ui.json", "b.sprite.json"}
	if _, _, _, code := gateRun(t, root, staged, lints, nil); code != 0 {
		t.Fatalf("通るはずが code=%d", code)
	}
	got := strings.Join(order, ",")
	if got != "flix-reserved,view,palette,ui-overflow,fallback,f32,z-table,record-wrap,jargon" {
		t.Errorf("並びが規約と違う: %s", got)
	}
}

func TestUIOverflowGetsStrictAndOnlyUIFiles(t *testing.T) {
	root := fakeRepo(t)
	var got []string
	lints := okLints(t)
	lints["ui-overflow"] = func(out, errOut *strings.Builder, args []string) int {
		got = args
		return 0
	}
	gateRun(t, root, []string{"--files", "a.ui.json", "b.flix"}, lints, nil)
	if strings.Join(got, " ") != "--strict a.ui.json" {
		t.Errorf("引数が違う: %q", got)
	}
}

func TestViewGetsEveryFlixFile(t *testing.T) {
	root := fakeRepo(t)
	var got []string
	lints := okLints(t)
	lints["view"] = func(out, errOut *strings.Builder, args []string) int {
		got = args
		return 0
	}
	gateRun(t, root, []string{"--files", "a.flix", "b.md", "c.flix"}, lints, nil)
	if strings.Join(got, " ") != "a.flix c.flix" {
		t.Errorf("引数が違う: %q", got)
	}
}

func TestF32OnlyForEngineSources(t *testing.T) {
	root := fakeRepo(t)
	called := 0
	lints := okLints(t)
	lints["f32"] = func(out, errOut *strings.Builder, args []string) int {
		called++
		return 0
	}
	gateRun(t, root, []string{"--files", "game/src/A.flix"}, lints, nil)
	if called != 0 {
		t.Errorf("engine の外の .flix で f32 が走った")
	}
	gateRun(t, root, []string{"--files", "engine_world/src/A.flix"}, lints, nil)
	if called != 1 {
		t.Errorf("engine_world/src の .flix で f32 が走らなかった")
	}
}

func TestFailingLintStopsWithFinalNotice(t *testing.T) {
	root := fakeRepo(t)
	// WhyNot: .flix でなく .ui.json を裁かせるのは、.flix が配線検査 (make) も
	// 引き当ててしまい、make の有無でテストが揺れるため。
	lints := okLints(t)
	lints["ui-overflow"] = func(out, errOut *strings.Builder, args []string) int {
		fmt.Fprintln(out, "はみ出します")
		fmt.Fprintln(errOut, "つまずきました")
		return 1
	}
	parent, child, childErr, code := gateRun(t, root, []string{"--files", "a.ui.json"}, lints, nil)
	if code != 1 {
		t.Fatalf("止まるはずが code=%d", code)
	}
	if child != "はみ出します\n" || childErr != "つまずきました\n" {
		t.Errorf("子の出力が親の側へ混ざっている: %q / %q", child, childErr)
	}
	want := "[pre-commit] 止めました。直してから再コミット (どうしても通すなら git commit --no-verify)\n"
	if parent != want {
		t.Errorf("親の知らせが違う: %q", parent)
	}
}

// TestChecksRunWithEmptyBin は bin/ に規約データしか無くても検査が走って止まることを見る。
// WhyNot: 通る側でなく止まる側を見るのは、ゲートが黙って開いても終了コード 0 は
// 「問題なし」と見分けが付かないため。実際にこの形で全検査がスキップしていた。
func TestChecksRunWithEmptyBin(t *testing.T) {
	root := fakeRepo(t)
	lints := okLints(t)
	lints["ui-overflow"] = func(out, errOut *strings.Builder, args []string) int { return 1 }
	_, _, _, code := gateRun(t, root, []string{"--files", "a.ui.json"}, lints, nil)
	if code != 1 {
		t.Fatalf("止まるはずが code=%d", code)
	}
}

func TestImageOutsideAllowedPlaceStops(t *testing.T) {
	root := fakeRepo(t)
	parent, _, _, code := gateRun(t, root, []string{"--files", "gallery/town.png"}, okLints(t), nil)
	if code != 1 {
		t.Fatalf("止まるはずが code=%d", code)
	}
	want := "[pre-commit] 画像 1 件:\n" +
		"  gallery/town.png — 追跡してよい置き場ではありません。生成した絵は git に入れない決まりです。" +
		"人に見せる絵なら docs/gallery/ へ (上限あり)\n" +
		"[pre-commit] 止めました。直してから再コミット (どうしても通すなら git commit --no-verify)\n"
	if parent != want {
		t.Errorf("文面が違う: %q", parent)
	}
}

func TestTopLevelAssetsIsNotAllowed(t *testing.T) {
	root := fakeRepo(t)
	parent, _, _, _ := gateRun(t, root, []string{"--files", "assets/tiles.png"}, okLints(t), nil)
	if !strings.Contains(parent, "assets/tiles.png — 追跡してよい置き場ではありません") {
		t.Errorf("リポ直下の assets/ が通ってしまった: %q", parent)
	}
	parent, _, _, code := gateRun(t, root, []string{"--files", "game/assets/tiles.png"}, okLints(t), nil)
	if parent != "" || code != 0 {
		t.Errorf("*/assets/ は通るはず: %q code=%d", parent, code)
	}
}

func TestGalleryImageOverLimitStops(t *testing.T) {
	root := fakeRepo(t)
	big := filepath.Join(root, "docs", "gallery")
	if err := os.MkdirAll(big, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(big, "big.png"), make([]byte, 400000), 0o644); err != nil {
		t.Fatal(err)
	}
	parent, _, _, code := gateRun(t, root, []string{"--files", "docs/gallery/big.png"}, okLints(t), nil)
	if code != 1 {
		t.Fatalf("止まるはずが code=%d", code)
	}
	want := "  docs/gallery/big.png が 391KB — 1 枚の上限 300KB (docs/gallery/README.md)\n"
	if !strings.Contains(parent, want) {
		t.Errorf("文面が違う: %q", parent)
	}
}

func TestLegacyImageViolationIsNoticeOnly(t *testing.T) {
	root := fakeRepo(t)
	parent, _, _, code := gateRun(t, root, []string{"--files", "docs/gallery/new.png"}, okLints(t),
		func(string) int { return 1 })
	if code != 0 {
		t.Fatalf("止めないはずが code=%d", code)
	}
	want := "[pre-commit] 注意: 過去から追跡されている絵に違反が残っています" +
		" (このコミットは止めません): bin/fge images で一覧\n"
	if parent != want {
		t.Errorf("文面が違う: %q", parent)
	}
}

func TestUppercaseExtensionIsStillAnImage(t *testing.T) {
	root := fakeRepo(t)
	parent, _, _, _ := gateRun(t, root, []string{"--files", "gallery/TOWN.PNG"}, okLints(t), nil)
	if !strings.Contains(parent, "gallery/TOWN.PNG — 追跡してよい置き場ではありません") {
		t.Errorf("大文字の拡張子を見落とした: %q", parent)
	}
}

func TestFilesFlagAloneReadsStage(t *testing.T) {
	// --files の後ろが空なら「対象なし」ではなく、ステージを読みに行く。
	root := fakeRepo(t)
	var parent strings.Builder
	_, err := Run(&parent, Options{Root: root, Args: []string{"--files"},
		Stdout: &strings.Builder{}, Stderr: &strings.Builder{}, Lints: okLints(t)})
	if err == nil {
		t.Errorf("git の無い偽リポなのでステージを読みに行って失敗するはず")
	}
}

func TestHuman(t *testing.T) {
	cases := []struct {
		n    int64
		want string
	}{
		{0, "0KB"},
		{400000, "391KB"},
		{300 * 1024, "300KB"},
		{1024 * 1024, "1.0MB"},
		{1536 * 1024, "1.5MB"},
	}
	for _, c := range cases {
		if got := human(c.n); got != c.want {
			t.Errorf("human(%d) = %s, want %s", c.n, got, c.want)
		}
	}
}

func TestMatcherBasenameIsNotSuffix(t *testing.T) {
	m := Matcher{Basenames: []string{"Makefile"}}
	for _, p := range []string{"Makefile", "game/Makefile"} {
		if !m.Match(p) {
			t.Errorf("%s は当たるはず", p)
		}
	}
	for _, p := range []string{"MyMakefile", "Makefile.am", "makefile"} {
		if m.Match(p) {
			t.Errorf("%s は当たらないはず", p)
		}
	}
}

func TestMatcherFieldsAreAndAnyOfIsOr(t *testing.T) {
	and := Matcher{Suffixes: []string{".flix"}, Prefixes: []string{"engine/src/"}}
	if and.Match("game/src/A.flix") || and.Match("engine/src/A.md") {
		t.Errorf("1 つの Matcher の中は AND のはず")
	}
	if !and.Match("engine/src/A.flix") {
		t.Errorf("両方に当たるパスが落ちた")
	}
	or := Matcher{AnyOf: []Matcher{{Suffixes: []string{".sprite.json"}}, {Substrings: []string{"palette"}}}}
	if !or.Match("a/b.sprite.json") || !or.Match("docs/palette.md") {
		t.Errorf("anyOf は OR のはず")
	}
	if or.Match("docs/notes.md") {
		t.Errorf("どちらにも当たらないパスが通った")
	}
}
