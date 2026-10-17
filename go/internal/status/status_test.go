package status

// 細かい意味づけ（切る位置・並び・空白の範囲）を縛る。

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fixedNow() time.Time { return time.Unix(1_770_000_000, 0) }

// build は 1 画面を組んで行に割る。
func build(t *testing.T, root string) []string {
	t.Helper()
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, repoRoot(t), nil, Options{Root: root, Now: fixedNow()})
	if err != nil {
		t.Fatalf("組み立てに失敗しました: %v", err)
	}
	if code != 0 {
		t.Fatalf("終了コードは必ず 0 です: %d", code)
	}
	if errOut.Len() != 0 {
		t.Fatalf("status は標準エラーへ書きません: %q", errOut.String())
	}
	body := out.String()
	if !strings.HasSuffix(body, "\n") {
		t.Fatalf("末尾の改行がありません: %q", body)
	}
	return strings.Split(strings.TrimSuffix(body, "\n"), "\n")
}

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("置き場を作れません: %v", err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("書けません: %v", err)
	}
}

func touch(t *testing.T, path string, ago time.Duration) {
	t.Helper()
	at := fixedNow().Add(-ago)
	if err := os.Chtimes(path, at, at); err != nil {
		t.Fatalf("更新時刻を変えられません: %v", err)
	}
}

func TestHeaderUsesRootBasenameAndNow(t *testing.T) {
	root := filepath.Join(t.TempDir(), "偽ゲーム")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatalf("作れません: %v", err)
	}
	want := "== 偽ゲーム 状態 " + fixedNow().Format("01-02 15:04") + " =="
	if got := build(t, root)[0]; got != want {
		t.Errorf("見出しが違います:\n  got  %s\n  want %s", got, want)
	}
}

func TestNoTestLogsSaysNoRecord(t *testing.T) {
	lines := build(t, t.TempDir())
	want := "テスト   記録なし (make test / make test-par を一度も通していない)"
	if !has(lines, want) {
		t.Errorf("記録なしの行が出ません: %v", lines)
	}
}

func TestAgeBuckets(t *testing.T) {
	cases := []struct {
		ago  time.Duration
		want string
	}{
		{time.Second, "たった今"},
		{89 * time.Second, "たった今"},
		{90 * time.Second, "1分前"},
		{59*time.Minute + 59*time.Second, "59分前"},
		{time.Hour, "1時間前"},
		{23*time.Hour + 59*time.Minute, "23時間前"},
		{24 * time.Hour, "1日前"},
		{100 * 24 * time.Hour, "100日前"},
	}
	for _, c := range cases {
		root := t.TempDir()
		p := filepath.Join(root, ".test-logs", "engine.log")
		write(t, p, "")
		touch(t, p, c.ago)
		want := "  OK: engine(" + c.want + ")"
		if !has(build(t, root), want) {
			t.Errorf("%v の表示が %s になりません", c.ago, c.want)
		}
	}
}

func TestGreensCutAtEight(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j"} {
		p := filepath.Join(root, ".test-logs", name+".log")
		write(t, p, "")
		touch(t, p, time.Minute)
	}
	line := find(t, build(t, root), "  OK: ")
	if !strings.HasSuffix(line, " 他2") {
		t.Errorf("9 本目以降が「他2」になりません: %s", line)
	}
	if strings.Count(line, "(たった今)") != 8 {
		t.Errorf("並ぶのは 8 本までです: %s", line)
	}
}

func TestFailLogGoesToNG(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, ".test-logs", "engine.log"), "")
	write(t, filepath.Join(root, ".test-logs", "engine.fail"), "")
	touch(t, filepath.Join(root, ".test-logs", "engine.log"), time.Minute)
	want := "  NG: engine(たった今) — 詳細は .test-logs/ の同名ログ"
	if !has(build(t, root), want) {
		t.Errorf("NG の行が出ません")
	}
}

func TestRenderLogsAreExcludedButFailsShow(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, ".test-logs", "render-title.log"), "")
	write(t, filepath.Join(root, ".test-logs", "render-title.fail"), "")
	lines := build(t, root)
	if !has(lines, "テスト   記録なし (make test / make test-par を一度も通していない)") {
		t.Errorf("render- の記録は数に入れません: %v", lines)
	}
}

func TestReferenceOKCountsMatches(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "gallery", "title.png"), "絵")
	// "絵" の sha256。
	write(t, filepath.Join(root, "reference", "SHA256SUMS.txt"),
		"91ec0fa1c48b4d67e4d4c8f0ef9e6d2d0c9f0e6f8a0a0d5a5f2b0b8a0a3c1d2e  title.png\n")
	lines := build(t, root)
	if find(t, lines, "reference NG") == "" {
		t.Fatal("ハッシュ違いは NG になります")
	}
}

func TestReferenceBadListCutAtFour(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "gallery", "keep.png"), "絵")
	var sums strings.Builder
	for _, n := range []string{"a", "b", "c", "d", "e", "f"} {
		sums.WriteString(strings.Repeat("0", 64) + "  " + n + ".png\n")
	}
	write(t, filepath.Join(root, "reference", "SHA256SUMS.txt"), sums.String())
	line := find(t, build(t, root), "reference NG")
	if !strings.Contains(line, " 他3 (意図した変更なら") {
		t.Errorf("5 つ目以降が「他3」になりません: %s", line)
	}
}

func TestStyleHintWhenNoLocalDoc(t *testing.T) {
	lines := build(t, t.TempDir())
	if !has(lines, "[画風] AGENTS.local.md の「この画面の画風」が未定（無い/仮置きのまま） → 絵を描く前に /style-interview") {
		t.Errorf("画風の促しが出ません: %v", lines)
	}
}

func TestStyleQuietWhenInterviewTrace(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "AGENTS.local.md"), "<!-- style-interview 済み -->\n")
	if line := find(t, build(t, root), "[画風]"); line != "" {
		t.Errorf("聞き取り済みなら黙ります: %s", line)
	}
}

func TestStyleQuietWhenHeadingFilled(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "AGENTS.local.md"), "## このゲームの画風\n\n夕暮れの港町。\n")
	if line := find(t, build(t, root), "[画風]"); line != "" {
		t.Errorf("節が書かれていれば黙ります: %s", line)
	}
}

func TestStyleHintWhenPlaceholderLeft(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "AGENTS.local.md"), "## この画面の画風\n\n最初に決めて、ここに書く\n")
	if line := find(t, build(t, root), "[画風]"); line == "" {
		t.Error("仮置きのままなら促します")
	}
}

func TestTemplatesRepoSkipsGameOnlySections(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "templates", "rpg-starter", "keep"), "")
	write(t, filepath.Join(root, "flix.toml"),
		"\"github:ababup1192/flix_game_engine\" = { version = \"0.0.1\" }\n")
	lines := build(t, root)
	for _, bad := range []string{"[画風]", "pack     ", "engine   "} {
		if line := find(t, lines, bad); line != "" {
			t.Errorf("engine リポでは出ません: %s", line)
		}
	}
}

func TestEngineDriftReportsPinnedVersion(t *testing.T) {
	root := t.TempDir()
	engine := filepath.Join(t.TempDir(), "engine")
	write(t, filepath.Join(engine, "Makefile"), "VERSION := 9.9.9\n")
	write(t, filepath.Join(root, "local.mk"), "ENGINE := "+engine+"\n")
	write(t, filepath.Join(root, "flix.toml"),
		"\"github:ababup1192/flix_game_engine\" = { version = \"0.0.1\" }\n")
	line := find(t, build(t, root), "engine   バージョンズレ")
	if !strings.Contains(line, "このゲームは v0.0.1 / いまの engine は v9.9.9") {
		t.Errorf("ズレの中身が違います: %s", line)
	}
}

func TestPackStampReportsOldVersion(t *testing.T) {
	root := t.TempDir()
	engine := filepath.Join(t.TempDir(), "engine")
	write(t, filepath.Join(engine, "Makefile"), "VERSION := 9.9.9\n")
	write(t, filepath.Join(root, "local.mk"), "ENGINE := "+engine+"\n")
	write(t, filepath.Join(root, "AGENTS.md"), "# agents-pack (engine v0.0.1) の見出し\n")
	line := find(t, build(t, root), "pack     古い")
	if !strings.Contains(line, "engine v0.0.1 / いまの engine は v9.9.9") {
		t.Errorf("pack の中身が違います: %s", line)
	}
	if !strings.Contains(line, "GAME=\""+resolveRoot(root)+"\"") {
		t.Errorf("GAME に見に行った先が入りません: %s", line)
	}
}

// WhyNot: 先頭 400 を「バイト」で切らないのは、日本語が並ぶ AGENTS.md では
// 3 倍ずれて、刻印を読み落とすため。
func TestPackStampCutIsCountedInRunes(t *testing.T) {
	root := t.TempDir()
	engine := filepath.Join(t.TempDir(), "engine")
	write(t, filepath.Join(engine, "Makefile"), "VERSION := 9.9.9\n")
	write(t, filepath.Join(root, "local.mk"), "ENGINE := "+engine+"\n")
	// 300 文字（900 バイト）の日本語の後に刻印。文字で数えれば届く。
	write(t, filepath.Join(root, "AGENTS.md"),
		strings.Repeat("あ", 300)+"agents-pack (engine v0.0.1)\n")
	if line := find(t, build(t, root), "pack     古い"); line == "" {
		t.Error("400 文字目までに入る刻印を読めていません")
	}
}

func TestNotesShowsSixLinesCutAtEighty(t *testing.T) {
	root := t.TempDir()
	long := strings.Repeat("あ", 100)
	write(t, filepath.Join(root, "NOTES.md"),
		"# 見出し\n\n"+long+"\n- 3\n- 4\n- 5\n- 6\n- 7 (出ない)\n")
	touch(t, filepath.Join(root, "NOTES.md"), time.Hour)
	lines := build(t, root)
	if !has(lines, "引き継ぎ NOTES.md (1時間前):") {
		t.Errorf("引き継ぎの見出しが出ません: %v", lines)
	}
	if has(lines, "  - 7 (出ない)") {
		t.Error("7 行目まで出ています")
	}
	if !has(lines, "  "+strings.Repeat("あ", 80)) {
		t.Error("80 文字で切れていません")
	}
}

func TestTicketsNewestFirst(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"old", "mid", "new", "余り"} {
		dir := filepath.Join(root, "debug", "annotations", name)
		write(t, filepath.Join(dir, "README.md"), "### "+name+" のまとめ\n")
	}
	base := filepath.Join(root, "debug", "annotations")
	touch(t, filepath.Join(base, "old"), 5*time.Hour)
	touch(t, filepath.Join(base, "mid"), 3*time.Hour)
	touch(t, filepath.Join(base, "new"), time.Hour)
	touch(t, filepath.Join(base, "余り"), 10*time.Hour)
	lines := build(t, root)
	if !has(lines, "チケット 注釈 4 件 (新しい順):") {
		t.Errorf("件数の行が出ません: %v", lines)
	}
	if !has(lines, "  new (1時間前) new のまとめ") {
		t.Errorf("新しい順で並びません: %v", lines)
	}
	if has(lines, "  余り (10時間前) 余り のまとめ") {
		t.Error("4 件目まで出ています")
	}
}

func TestTooLongIsCut(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 60; i++ {
		name := string(rune('a'+i%26)) + strings.Repeat("x", i)
		p := filepath.Join(root, ".test-logs", name+".log")
		write(t, p, "")
		write(t, filepath.Join(root, ".test-logs", name+".fail"), "")
		touch(t, p, time.Minute)
	}
	lines := build(t, root)
	rules, err := LoadRules(repoRoot(t))
	if err != nil {
		t.Fatalf("規約データを読めません: %v", err)
	}
	if len(lines) != rules.MaxLines+1 {
		t.Fatalf("切った後は %d 行になります: %d", rules.MaxLines+1, len(lines))
	}
	if lines[len(lines)-1] != "  … (長すぎるので切った。bin/fge status で全文)" {
		t.Errorf("末尾が切った印になりません: %s", lines[len(lines)-1])
	}
}

func TestHiddenNamesAreNotGlobbed(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, ".test-logs", ".hidden.log"), "")
	if !has(build(t, root), "テスト   記録なし (make test / make test-par を一度も通していない)") {
		t.Error("先頭が . の名前は * に当たりません")
	}
}

func TestUnknownSectionIsAnError(t *testing.T) {
	root := t.TempDir()
	writeRule(t, root, `{"maxLines":40,"buildWarnEntries":1,"sections":["section_知らない"],
	  "ageJustNowSeconds":90,"ageMinuteSeconds":3600,"ageHourSeconds":86400,"gitLogCount":3,
	  "greensShown":8,"referenceBadShown":4,"budgetDetailLines":3,"ticketsShown":3,
	  "ticketSummaryWidth":60,"notesShown":6,"notesWidth":80,"testLogsDir":".test-logs",
	  "buildGlobs":[],"buildDirs":[]}`)
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, nil, Options{Root: t.TempDir(), Now: fixedNow()})
	if err == nil {
		t.Fatal("知らない節があるのにエラーになりません")
	}
	if code != 2 {
		t.Errorf("検査が動かなかったときは 2 です: %d", code)
	}
}

// ---- pyutil ---------------------------------------------------------------

func TestPyBasenameOnTrailingSlash(t *testing.T) {
	// WhyNot: filepath.Base だと "b" が返る。ここでは空文字が要る。
	if got := pyBasename("a/b/"); got != "" {
		t.Errorf("末尾が / のときは空文字です: %q", got)
	}
}

func TestPyStripDropsFileSeparators(t *testing.T) {
	if got := pyStrip("\x1c\x1f あ \x1e"); got != "あ" {
		t.Errorf("\\x1c〜\\x1f も落とします: %q", got)
	}
}

func TestPyHeadCountsRunes(t *testing.T) {
	if got := pyHead("あいうえお", 2); got != "あい" {
		t.Errorf("コードポイントで切ります: %q", got)
	}
}

func TestPyFileLinesIsNarrowerThanSplitLines(t *testing.T) {
	s := "a\x0bb\nc"
	if got := len(pyFileLines(s)); got != 2 {
		t.Errorf("ファイルの行反復は \\v で切りません: %d", got)
	}
	if got := len(pySplitLines(s)); got != 3 {
		t.Errorf("str.splitlines() は \\v でも切ります: %d", got)
	}
}

func TestUniversalNewlinesFoldsCRLF(t *testing.T) {
	if got := universalNewlines("a\r\nb\rc"); got != "a\nb\nc" {
		t.Errorf("読み込みで行末を均します: %q", got)
	}
}

func TestPySplitWS1KeepsRest(t *testing.T) {
	got := pySplitWS1("  hash   name with space \n")
	if len(got) != 2 || got[0] != "hash" || got[1] != "name with space \n" {
		t.Errorf("split(None, 1) と同じに切れません: %q", got)
	}
}

func TestEngineDirPrefersEnv(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "local.mk"), "ENGINE := /from/mk\n")
	t.Setenv("ENGINE", "/from/env")
	if got := ReadEngineDir(root); got != "/from/env" {
		t.Errorf("環境変数が先です: %s", got)
	}
	t.Setenv("ENGINE", "")
	if got := ReadEngineDir(root); got != "/from/mk" {
		t.Errorf("空なら local.mk へ落ちます: %s", got)
	}
}

func TestEngineDirAcceptsWideSpace(t *testing.T) {
	root := t.TempDir()
	t.Setenv("ENGINE", "")
	// WhyNot: Go の \s は ASCII だけなので使えない。全角空白も落とす必要がある。
	write(t, filepath.Join(root, "local.mk"), "ENGINE ?= /a/b　\n")
	if got := ReadEngineDir(root); got != "/a/b" {
		t.Errorf("全角空白を落とせていません: %q", got)
	}
}

// FindEngineDir は 根自身 → local.mk → Makefile の ENGINE の順で、marker が実在する所を返す。
func TestFindEngineDirOrder(t *testing.T) {
	root := t.TempDir()
	t.Setenv("ENGINE", "")
	write(t, filepath.Join(root, "eng", "mk", "game.mk"), "")
	write(t, filepath.Join(root, "Makefile"), "# ENGINE := /comment\nENGINE ?= eng\n")
	write(t, filepath.Join(root, "local.mk"), "ENGINE := /no/such\n")
	if got, self := FindEngineDir(root, "mk/game.mk"); got != filepath.Join(root, "eng") || self {
		t.Errorf("local.mk が無い所なら Makefile の ENGINE へ落ちます: %s %v", got, self)
	}
	write(t, filepath.Join(root, "mk", "game.mk"), "")
	if got, self := FindEngineDir(root, "mk/game.mk"); got != root || !self {
		t.Errorf("根に marker があれば根自身です: %s %v", got, self)
	}
}

func TestParseNowRejectsGarbage(t *testing.T) {
	if _, err := ParseNow("きのう"); err == nil {
		t.Fatal("数でない --now はエラーです")
	}
}

// ---- 小物 ----------------------------------------------------------------

func has(lines []string, want string) bool {
	for _, line := range lines {
		if line == want {
			return true
		}
	}
	return false
}

func find(t *testing.T, lines []string, prefix string) string {
	t.Helper()
	for _, line := range lines {
		if strings.Contains(line, prefix) {
			return line
		}
	}
	return ""
}
