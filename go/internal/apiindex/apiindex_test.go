package apiindex

// What: 判定を間違えやすい所（語の境界・コメント行・legacy 配下・
// ファイル名参照）と、出す口（stdout / stderr）と終了コードを縛る。

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWordInFindsWholeWord(t *testing.T) {
	if !wordIn("App", "- App — 走らせる入口") {
		t.Error("語として独立した App を見つけられない")
	}
}

func TestWordInRejectsPartOfLongerName(t *testing.T) {
	if wordIn("App", "- AppState — 別物") {
		t.Error("AppState の一部を App として拾っている")
	}
}

// Go の `\b` は ASCII しか語とみなさないので、日本語に挟まれた名前を語として拾ってしまう。
func TestWordInRejectsNameGluedToJapanese(t *testing.T) {
	if wordIn("App", "モジュールApp配下") {
		t.Error("前後が日本語の App を語として拾っている（Python は拾わない）")
	}
}

func TestDocFuncRefsFindsPair(t *testing.T) {
	refs := docFuncRefs("盤は Board.make で組む")
	if len(refs) != 1 || refs[0].Mod != "Board" || refs[0].Func != "make" {
		t.Errorf("拾えたのは %v", refs)
	}
}

// `_` は語の文字なので、後ろに続く名前は参照として拾わない。
func TestDocFuncRefsRejectsUnderscoreTail(t *testing.T) {
	if refs := docFuncRefs("Board.make_thing"); len(refs) != 0 {
		t.Errorf("拾ってはいけない参照を拾った: %v", refs)
	}
}

func TestDocFuncRefsRejectsGluedHead(t *testing.T) {
	if refs := docFuncRefs("xBoard.make"); len(refs) != 0 {
		t.Errorf("拾ってはいけない参照を拾った: %v", refs)
	}
}

func TestDocFuncRefsKeepsSecondRefAfterRejection(t *testing.T) {
	refs := docFuncRefs("xBoard.make と Depth.ui")
	if len(refs) != 1 || refs[0].Mod != "Depth" {
		t.Errorf("拾えたのは %v", refs)
	}
}

func TestStripCommentsDropsCommentLines(t *testing.T) {
	got := stripComments("mod A {\n    // pub def ghost(): Unit\n    pub def real(): Unit = ()\n}")
	if strings.Contains(got, "ghost") {
		t.Errorf("コメント行が残っている: %q", got)
	}
}

// fakeRepo は最小の偽リポを組む。docs の中身は呼ぶ側が差し替える。
func fakeRepo(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	base := map[string]string{
		"bin/lint-rules/check-api-index.json": `{
  "targets": [
    {"src": "engine/src", "doc": "docs/modules/engine.md"},
    {"src": "engine_world/src", "doc": "docs/module-index.md"}
  ],
  "extraDefSources": ["engine_tools/src"],
  "exempt": {"BootFontData": "生成物"},
  "skipDirs": ["legacy"],
  "fileExts": ["flix", "json", "md", "png", "py", "sh"]
}`,
		"engine/src/App.flix":          "mod App {\n    pub def run(): Unit = ()\n}\n",
		"engine_world/src/Board.flix":  "mod Board {\n    pub def make(): Unit = ()\n}\n",
		"engine_tools/src/Bakery.flix": "mod Bakery {\n    pub def bake(): Unit = ()\n}\n",
		"docs/modules/engine.md":  "- App — 入口\n",
		"docs/module-index.md":         "- Board — 盤\n",
	}
	for path, body := range files {
		base[path] = body
	}
	for path, body := range base {
		full := filepath.Join(dir, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func run(t *testing.T, dir string) (string, string, int) {
	t.Helper()
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, dir, nil, Options{})
	if err != nil {
		t.Fatalf("検査が動かなかった: %v", err)
	}
	return out.String(), errOut.String(), code
}

func TestRunGreenWritesOnlyToStdout(t *testing.T) {
	out, errOut, code := run(t, fakeRepo(t, nil))
	if code != 0 || errOut != "" {
		t.Fatalf("code=%d err=%q", code, errOut)
	}
	if out != "OK: 索引とソースの pub def はそろっています（除外 0 件）\n" {
		t.Errorf("out=%q", out)
	}
}

func TestRunMissingModuleGoesToStderr(t *testing.T) {
	dir := fakeRepo(t, map[string]string{
		"engine_world/src/Tilemap.flix": "mod Tilemap {\n    pub def toItems(): Unit = ()\n}\n",
	})
	out, errOut, code := run(t, dir)
	if code != 1 {
		t.Fatalf("code=%d", code)
	}
	if out != "" {
		t.Errorf("NG なのに stdout に出ている: %q", out)
	}
	want := "docs/module-index.md: モジュール Tilemap（engine_world/src 配下・pub def 1 本）が載っていません\n"
	if !strings.HasPrefix(errOut, want) {
		t.Errorf("errOut=%q", errOut)
	}
}

func TestRunGhostReferenceGoesToStderr(t *testing.T) {
	dir := fakeRepo(t, map[string]string{
		"docs/module-index.md": "- Board — 盤。Board.collapse で畳む\n",
	})
	_, errOut, code := run(t, dir)
	if code != 1 {
		t.Fatalf("code=%d", code)
	}
	want := "docs/module-index.md: Board.collapse は pub def に見つかりません（改名か削除の可能性）\n"
	if !strings.HasPrefix(errOut, want) {
		t.Errorf("errOut=%q", errOut)
	}
}

// partsRules は engine_world の索引を目次 + 分野ごとのファイルに分けた規約。
const partsRules = `{
  "targets": [
    {"src": "engine/src", "doc": "docs/modules/engine.md"},
    {"src": "engine_world/src", "doc": "docs/module-index.md", "parts": "docs/modules/*.md"}
  ],
  "extraDefSources": ["engine_tools/src"],
  "exempt": {},
  "skipDirs": ["legacy"],
  "fileExts": ["flix", "json", "md", "png", "py", "sh"]
}`

func TestRunModuleListedOnlyInPartIsGreen(t *testing.T) {
	dir := fakeRepo(t, map[string]string{
		"bin/lint-rules/check-api-index.json": partsRules,
		"docs/module-index.md":                "| [map.md](modules/map.md) | 盤面 |\n",
		"docs/modules/map.md":                 "- **Board** — 盤\n",
	})
	_, errOut, code := run(t, dir)
	if code != 0 {
		t.Errorf("分野のファイルにだけ載るモジュールを見落としている: %q", errOut)
	}
}

func TestRunGhostReferenceInPartNamesThePart(t *testing.T) {
	dir := fakeRepo(t, map[string]string{
		"bin/lint-rules/check-api-index.json": partsRules,
		"docs/modules/map.md":                 "- **Board** — 盤。Board.collapse で畳む\n",
	})
	_, errOut, code := run(t, dir)
	if code != 1 {
		t.Fatalf("code=%d", code)
	}
	want := "docs/modules/map.md: Board.collapse は pub def に見つかりません（改名か削除の可能性）\n"
	if !strings.HasPrefix(errOut, want) {
		t.Errorf("errOut=%q", errOut)
	}
}

func TestRunFileNameIsNotAFunctionRef(t *testing.T) {
	dir := fakeRepo(t, map[string]string{
		"docs/module-index.md": "- Board — 盤。Board.flix にある\n",
	})
	_, _, code := run(t, dir)
	if code != 0 {
		t.Error("Board.flix をファイル名でなく関数参照として扱っている")
	}
}

func TestRunUnknownModuleRefIsIgnored(t *testing.T) {
	dir := fakeRepo(t, map[string]string{
		"docs/module-index.md": "- Board — 盤。List.map を使う\n",
	})
	_, _, code := run(t, dir)
	if code != 0 {
		t.Error("別リポのモジュール参照を照合している")
	}
}

func TestRunSkipsLegacyDir(t *testing.T) {
	dir := fakeRepo(t, map[string]string{
		"engine_world/src/legacy/MapCodec.flix": "mod MapCodec {\n    pub def decode(): Unit = ()\n}\n",
	})
	_, _, code := run(t, dir)
	if code != 0 {
		t.Error("legacy 配下を数えている")
	}
}

func TestRunExemptModuleIsListedOnStdout(t *testing.T) {
	dir := fakeRepo(t, map[string]string{
		"engine/src/BootFontData.flix": "mod BootFontData {\n    pub def rows(): Unit = ()\n}\n",
	})
	out, _, code := run(t, dir)
	if code != 0 {
		t.Fatalf("code=%d", code)
	}
	if !strings.HasPrefix(out, "除外: BootFontData — 生成物\n") {
		t.Errorf("out=%q", out)
	}
}

func TestRunUnreadableIndexGoesToStderrWithCode1(t *testing.T) {
	dir := fakeRepo(t, nil)
	if err := os.Remove(filepath.Join(dir, "docs", "module-index.md")); err != nil {
		t.Fatal(err)
	}
	out, errOut, code := run(t, dir)
	if code != 1 {
		t.Fatalf("code=%d", code)
	}
	if errOut != "読めません: docs/module-index.md\n" || out != "" {
		t.Errorf("out=%q err=%q", out, errOut)
	}
}

func TestRunFailsWhenRulesMissing(t *testing.T) {
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, t.TempDir(), nil, Options{})
	if err == nil || code != 2 {
		t.Errorf("規約が無いのに code=%d err=%v", code, err)
	}
}
