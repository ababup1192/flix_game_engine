package migrationnotes

// What: 差分の塊の割り方、追随例の絞り込み（識別子の切れ目・削除行のある塊だけ・
// 大きすぎる塊は捨てる・同じコミットで engine を触っていれば名前だけで拾う）、
// 追随例が無いときに正直に言うこと、手書きの置き換え表の行を引くこと、--check の 3 通り、出す口と終了コード。

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/apidiff"
)

func changeOf(mod, name string, removed, added []string) apidiff.Change {
	return apidiff.Change{
		Key:            apidiff.Key{Package: "engine_world", Mod: mod, Name: name},
		Kind:           "changed",
		MembersRemoved: removed,
		MembersAdded:   added,
	}
}

// Sprite が withSpriteAtlases に当たると、関係のない差分が追随例として並ぶ。
func TestContainsIdentStopsAtIdentifierBoundary(t *testing.T) {
	if containsIdent("App.withSpriteAtlases(x)", "Sprite") {
		t.Error("識別子の途中に当たっています")
	}
	if !containsIdent("let s = PxSpriteDoc.Sprite", "Sprite") {
		t.Error("切れ目で終わる名前を拾えていません")
	}
	if !containsIdent("Sprite", "Sprite") {
		t.Error("名前そのものを拾えていません")
	}
}

// 足しただけの塊（新しいファイル・新しい関数）は、壊れた API の直し方を教えない。
func TestAdditionOnlyHunkIsNotAFollowUp(t *testing.T) {
	hunk := "# templates/a/src/Main.flix\n@@ -0,0 +1,3 @@\n+mod Main {\n+    // PxSprite.anchorOffsetOf を使う\n+}"
	c := apidiff.Change{Key: apidiff.Key{Mod: "PxSprite", Name: "anchorOffsetOf"}, Kind: "changed"}
	if hunkMentions(hunk, c, true) {
		t.Error("削除行の無い塊を追随例にしています")
	}
}

func TestCallSiteFixIsAFollowUp(t *testing.T) {
	hunk := "# templates/a/src/View.flix\n@@ -1,3 +1,3 @@\n" +
		"-        let a = PxSprite.anchorOffsetOf(doc, s, f, flipX, 1);\n" +
		"+        let a = PxSprite.anchorOffsetOf(doc, s, f, 1);"
	c := apidiff.Change{Key: apidiff.Key{Mod: "PxSprite", Name: "anchorOffsetOf"}, Kind: "changed"}
	if !hunkMentions(hunk, c, false) {
		t.Error("呼び出しを直した塊を拾えていません")
	}
}

// 巨大な塊が 1 つ混ざるだけで生成物が読めなくなる。
func TestHugeHunkIsDropped(t *testing.T) {
	var lines []string
	lines = append(lines, "# templates/a/src/View.flix", "@@ -1,90 +1,90 @@",
		"-        PxSprite.anchorOffsetOf(a, b, c, d, 1)")
	for i := 0; i < maxHunkLines; i++ {
		lines = append(lines, "+        x")
	}
	c := apidiff.Change{Key: apidiff.Key{Mod: "PxSprite", Name: "anchorOffsetOf"}, Kind: "changed"}
	if hunkMentions(strings.Join(lines, "\n"), c, false) {
		t.Error("大きすぎる塊を捨てていません")
	}
}

// `loop =` は他の型にも出る。その型の名前が同じ塊に居るときだけ採る。
func TestFieldNameNeedsItsTypeInTheSameHunk(t *testing.T) {
	c := changeOf("PxSpriteDoc", "Sprite", []string{"loop"}, []string{"clips"})
	other := "# templates/a/src/Anim.flix\n@@ -1,2 +1,2 @@\n-    loop = Forward,\n+    loop = Once,"
	if hunkMentions(other, c, false) {
		t.Error("型の名前が居ない塊を拾っています")
	}
	mine := "# templates/a/src/Doc.flix\n@@ -1,2 +1,2 @@\n" +
		"-    Sprite = { anchor = z, loop = Forward }\n+    Sprite = { anchor = z, clips = Map#{} }"
	if !hunkMentions(mine, c, false) {
		t.Error("型の名前が居る塊を拾えていません")
	}
}

// 旧 API の字を 1 つも残さない書き替えは、engine 側と同じコミットかどうかでしか拾えない。
func TestRewriteIsFoundOnlyWhenTheSameCommitTouchedEngine(t *testing.T) {
	c := apidiff.Change{Key: apidiff.Key{Mod: "ViewCar", Name: "pxQuad"}, Kind: "changed"}
	hunk := "# templates/a/src/View.flix\n@@ -1,2 +1,2 @@\n-    pxQuad(spec)\n+    quad(spec)"
	if hunkMentions(hunk, c, false) {
		t.Error("engine を触っていないコミットまで拾っています")
	}
	if !hunkMentions(hunk, c, true) {
		t.Error("同じコミットの追随を拾えていません")
	}
}

func TestSplitHunksKeepsTheFileName(t *testing.T) {
	diff := "diff --git a/templates/a.flix b/templates/a.flix\n" +
		"--- a/templates/a.flix\n+++ b/templates/a.flix\n" +
		"@@ -1,2 +1,2 @@\n-old\n+new\n@@ -9,2 +9,2 @@\n-old2\n+new2\n"
	got := splitHunks(diff)
	if len(got) != 2 {
		t.Fatalf("塊の数=%d: %v", len(got), got)
	}
	for _, h := range got {
		if !strings.HasPrefix(h, "# templates/a.flix") {
			t.Errorf("ファイル名が付いていません: %q", h)
		}
	}
}

// 追随例が 1 つも無いときに、あるかのように黙ると、読む人が探し続ける。
func TestBuildSaysWhenThereIsNoFollowUp(t *testing.T) {
	dir := t.TempDir()
	res := apidiff.Result{
		From:     "v0.1.0",
		Breaking: []apidiff.Change{changeOf("PxSpriteDoc", "Sprite", []string{"loop"}, []string{"clips"})},
	}
	body, unexplained, _ := build(dir, "0.2.0", res)
	if unexplained != 1 {
		t.Errorf("追随例の無い数=%d", unexplained)
	}
	if !strings.Contains(body, "追随例がありません") {
		t.Errorf("正直に言っていません:\n%s", body)
	}
}

func TestBuildListsAddedDeclarationsSeparately(t *testing.T) {
	dir := t.TempDir()
	res := apidiff.Result{
		From:  "v0.1.0",
		Added: []apidiff.Change{{Key: apidiff.Key{Package: "engine", Mod: "M", Name: "fresh"}, Kind: "added"}},
	}
	body, _, _ := build(dir, "0.2.0", res)
	if !strings.Contains(body, "読むだけでよい") || !strings.Contains(body, "M.fresh") {
		t.Errorf("増えた宣言が出ていません:\n%s", body)
	}
}

// schema の無い Doc の種を黙ると、「差分で全部拾える」と思わせる。
func TestBuildNamesUndiagnosableDocs(t *testing.T) {
	dir := t.TempDir()
	res := apidiff.Result{From: "v0.1.0", UndiagnosableDocs: []string{"shader"}}
	body, _, _ := build(dir, "0.2.0", res)
	if !strings.Contains(body, "診られない") || !strings.Contains(body, "shader") {
		t.Errorf("診られない物を言っていません:\n%s", body)
	}
}

func TestRunRejectsUnknownArgument(t *testing.T) {
	var out, errOut strings.Builder
	code, _ := Run(&out, &errOut, t.TempDir(), []string{"--nope"})
	if code != 2 || !strings.Contains(errOut.String(), "知らない引数") {
		t.Errorf("code=%d errOut=%q", code, errOut.String())
	}
}

func TestRunNeedsVersion(t *testing.T) {
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, t.TempDir(), nil)
	if code == 0 || err == nil {
		t.Errorf("Makefile が無いのに code=%d err=%v", code, err)
	}
}

// bump の後に API を触るコミットが入ると、材料が古いままリリースへ進んでしまう。
func TestCheckFailsWhenTheFileIsMissing(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "Makefile"), []byte("VERSION := 0.2.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	code, _ := Run(&out, &errOut, dir, []string{"--check", "--from", "v0.1.0"})
	if code == 0 {
		t.Errorf("材料が無いのに 0 で終わりました out=%q", out.String())
	}
}

// 消えたファイルは `+++ /dev/null` になる。そこで名前を更新しないと 1 つ前の
// ファイル名が貼られ、存在しないファイルを指す指示書になる。
func TestDeletedFileKeepsItsOwnName(t *testing.T) {
	diff := "diff --git a/templates/keep.flix b/templates/keep.flix\n" +
		"--- a/templates/keep.flix\n+++ b/templates/keep.flix\n" +
		"@@ -1,2 +1,2 @@\n-old\n+new\n" +
		"diff --git a/templates/gone.flix b/templates/gone.flix\n" +
		"--- a/templates/gone.flix\n+++ /dev/null\n" +
		"@@ -1,2 +0,0 @@\n-mod Gone {\n-}\n"
	got := splitHunks(diff)
	if len(got) != 2 {
		t.Fatalf("塊の数=%d: %v", len(got), got)
	}
	if !strings.HasPrefix(got[1], "# templates/gone.flix") {
		t.Errorf("消えたファイルの名前が違います: %q", got[1])
	}
}

// `\ No newline at end of file` で塊を切ると、直した後の行が丸ごと落ちる。
func TestNoNewlineMarkerDoesNotDropTheFixedLines(t *testing.T) {
	diff := "diff --git a/templates/a.flix b/templates/a.flix\n" +
		"--- a/templates/a.flix\n+++ b/templates/a.flix\n" +
		"@@ -1,2 +1,2 @@\n ctx\n-    old(a, b)\n\\ No newline at end of file\n+    new(a)\n"
	got := splitHunks(diff)
	if len(got) != 1 {
		t.Fatalf("塊の数=%d: %v", len(got), got)
	}
	if !strings.Contains(got[0], "+    new(a)") {
		t.Errorf("直した後の行が落ちています: %q", got[0])
	}
}

// Sprite のような一般名は別の mod にも居る。mod が違う塊を追随例にすると
// 「flipX を消せ」のような誤った直し方を読ませる。
func TestOtherModsSameNameIsNotAFollowUp(t *testing.T) {
	c := changeOf("PxSpriteDoc", "Sprite", []string{"loop"}, []string{"clips"})
	other := "# templates/a/src/View.flix\n@@ -1,2 +1,2 @@\n" +
		"-        Render.Item.Sprite({ flipX = true })\n+        Render.Item.Sprite({})"
	if hunkMentions(other, c, true) {
		t.Error("別の mod の同名を追随例にしています")
	}
	mine := "# templates/a/src/View.flix\n@@ -1,2 +1,2 @@\n" +
		"-        PxSpriteDoc.Sprite({ loop = x })\n+        PxSpriteDoc.Sprite({ clips = y })"
	if !hunkMentions(mine, c, false) {
		t.Error("同じ mod の追随を拾えていません")
	}
}

// Doc の実物に Flix の型名は 1 つも書かれていない。型名を求める判定にすると、
// この枝は永久に当たらない飾りになる（実際そうなっていた）。
func TestJSONFieldIsAFollowUpWithoutTheTypeName(t *testing.T) {
	c := changeOf("PxSpriteDoc", "Sprite", []string{"loop"}, []string{"clips"})
	hunk := "# templates/a/assets/a.sprite.json\n@@ -1,3 +1,3 @@\n" +
		"   \"sprites\": {\n-      \"loop\": \"forward\"\n+      \"clips\": {}"
	if !hunkMentions(hunk, c, false) {
		t.Error("JSON の書き方を見ていません")
	}
}

// JSON でも、足しただけの言及は追随の直し方を教えない。
func TestJSONFieldOnlyAddedIsNotAFollowUp(t *testing.T) {
	c := changeOf("PxSpriteDoc", "Sprite", []string{"loop"}, []string{"clips"})
	hunk := "# templates/a/assets/a.sprite.json\n@@ -1,3 +1,3 @@\n" +
		"-  \"title\": \"a\"\n+  \"title\": \"b\"\n+  \"clips\": {}"
	if hunkMentions(hunk, c, false) {
		t.Error("足しただけの JSON を追随例にしています")
	}
}

// 見出しはこちらが自分で足した行。走査に含めると Sprite.flix のようなファイル名だけで
// 「この型を直している」と読んでしまう。
func TestFileNameAloneIsNotAMention(t *testing.T) {
	c := apidiff.Change{Key: apidiff.Key{Mod: "PxSpriteDoc", Name: "Sprite"}, Kind: "changed"}
	hunk := "# templates/a/src/Sprite.flix\n@@ -1,2 +1,2 @@\n-    foo(a)\n+    foo(a, b)"
	if hunkMentions(hunk, c, true) {
		t.Error("ファイル名だけで追随例にしています")
	}
}

// 探せなかっただけなのに「追随例がありません」と断定すると、
// 読む人が本当は在る例を探しに行かなくなる。
func TestMissingGitIsToldApartFromNoFollowUp(t *testing.T) {
	res := apidiff.Result{
		From:     "v0.1.0",
		Breaking: []apidiff.Change{changeOf("M", "A", nil, nil)},
	}
	_, notices := findFollowUps(t.TempDir(), res)
	if len(notices) == 0 {
		t.Error("git log を呼べなかったことを知らせていません")
	}
}

// release-guard は `--from` を付けずに --check だけを呼ぶ。告知が --check の後ろにあると、
// いちばん要る場所（リリースの直前）で fail-open が無音になる。
func TestCheckStillTellsAboutFailOpen(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "Makefile", "VERSION := 0.2.0\n")
	write(t, dir, "bin/lint-rules/api-diff.json", `{"docKinds":["fx"]}`)
	write(t, dir, "engine_world/src/A.flix", "mod M {\n    pub def a(): Int32 = 0\n}\n")
	git(t, dir, "init", "--quiet")
	git(t, dir, "config", "user.email", "t@example.com")
	git(t, dir, "config", "user.name", "t")
	git(t, dir, "add", "-A")
	git(t, dir, "commit", "--quiet", "-m", "x")
	git(t, dir, "tag", "v0.1.0")

	var out, errOut strings.Builder
	// origin が無いので fetch は必ず失敗する（release-guard と同じ引数）。
	code, _ := Run(&out, &errOut, dir, []string{"--check"})
	if code == 0 {
		t.Fatalf("材料が無いのに 0 で終わりました out=%q", out.String())
	}
	if !strings.Contains(out.String(), "fail-open") {
		t.Errorf("--check で告知が消えています out=%q errOut=%q", out.String(), errOut.String())
	}
}

// パス名の辞書順で採ると、呼び出しの直し方が読める例が落ちて、
// 名前がかすっただけの例が残る。
func TestFollowUpsArePickedByTeachingPower(t *testing.T) {
	c := apidiff.Change{Key: apidiff.Key{Mod: "PxSprite", Name: "anchorOffsetOf"}, Kind: "changed"}
	weak := "# templates/a/src/A.flix\n@@ -1,2 +1,2 @@\n" +
		"-    // PxSprite.anchorOffsetOf は使わない\n-    old(x)\n+    new(x)\n+    new(y)"
	strong := "# templates/z/src/Z.flix\n@@ -1,2 +1,2 @@\n" +
		"-    PxSprite.anchorOffsetOf(d, s, f, flipX, 1)\n+    PxSprite.anchorOffsetOf(d, s, f, 1)"
	hunks := []string{weak, strong}
	sortByTeachingPower(hunks, c)
	if hunks[0] != strong {
		t.Errorf("置き換えの見える例が先頭に来ていません: %q", hunks[0])
	}
}

// 同点なら変更行の少ない方が読みやすい。並びが呼ぶたびに変わると --check が落ちる。
func TestFollowUpTieBreakIsSmallerThenPathName(t *testing.T) {
	c := apidiff.Change{Key: apidiff.Key{Mod: "M", Name: "f"}, Kind: "changed"}
	big := "# templates/a.flix\n@@ -1,4 +1,4 @@\n-    M.f(a, b)\n-    x\n+    M.f(a)\n+    y"
	small := "# templates/z.flix\n@@ -1,2 +1,2 @@\n-    M.f(a, b)\n+    M.f(a)"
	hunks := []string{big, small}
	sortByTeachingPower(hunks, c)
	if hunks[0] != small {
		t.Errorf("変更行の少ない方が先に来ていません: %q", hunks[0])
	}
}

// 上限が無いと非互換 81 件 × 追随例 3 個で 2,670 行になり、どこから直すか読めなくなる。
func TestTotalDiffBudgetTrimsAndSaysHowMany(t *testing.T) {
	var lines []string
	for i := 0; i < maxHunkLines-1; i++ {
		lines = append(lines, "-    M.f(a, b)")
	}
	hunk := "# templates/a.flix\n@@ -1,1 +1,1 @@\n" + strings.Join(lines, "\n")
	var breaking []apidiff.Change
	examples := map[string][]string{}
	for i := 0; i < 20; i++ {
		c := changeOf("M", fmt.Sprintf("f%02d", i), nil, nil)
		breaking = append(breaking, c)
		examples[c.QualifiedName()] = []string{hunk}
	}
	trimmed := trimToBudget(breaking, examples)
	if len(trimmed) == 0 {
		t.Fatalf("上限を超えても 1 件も省いていません")
	}
	if trimmed[0] {
		t.Error("1 件目まで省いています")
	}
	var b strings.Builder
	writeBreaking(&b, apidiff.Result{From: "v0.1.0", Breaking: breaking}, examples, nil)
	if !strings.Contains(b.String(), "件は追随例を省いて") {
		t.Errorf("省いたことを本文に書いていません:\n%s", b.String())
	}
	if !strings.Contains(b.String(), "追随例は省きました") {
		t.Errorf("省いた非互換の側に印がありません:\n%s", b.String())
	}
}

// make bump は VERSION と全 flix.toml を書き換えた後にこれを呼ぶ。
// タグが 1 つも無いときにここで止まると、書き換え済みで異常終了する。
func TestFirstReleaseWritesNotesAndExitsZero(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "Makefile", "VERSION := 0.1.0\n")
	write(t, dir, "bin/lint-rules/api-diff.json", `{"docKinds":["fx"]}`)
	write(t, dir, "engine_world/src/A.flix", "mod M {\n    pub def a(): Int32 = 0\n}\n")
	git(t, dir, "init", "--quiet")
	git(t, dir, "config", "user.email", "t@example.com")
	git(t, dir, "config", "user.name", "t")
	git(t, dir, "add", "-A")
	git(t, dir, "commit", "--quiet", "-m", "x")

	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, dir, nil)
	if code != 0 || err != nil {
		t.Fatalf("code=%d err=%v errOut=%q", code, err, errOut.String())
	}
	body, readErr := os.ReadFile(filepath.Join(dir, "docs", "migrations", "0.1.0.auto.md"))
	if readErr != nil {
		t.Fatal(readErr)
	}
	if !strings.Contains(string(body), "初リリース") {
		t.Errorf("初リリースだと書いていません:\n%s", body)
	}
}

// mod と eff の名前が同じだと Mod.Name が GameLogger.GameLogger.info になり、
// 見出しにも追随例を探す鍵にも無い名前が出る。
func TestQualifiedNameDoesNotRepeatTheModule(t *testing.T) {
	c := apidiff.Change{Key: apidiff.Key{Mod: "GameLogger", Name: "GameLogger.info"}, Kind: "added"}
	if got := c.QualifiedName(); got != "GameLogger.info" {
		t.Errorf("見出しが二重です: %q", got)
	}
	plain := apidiff.Change{Key: apidiff.Key{Mod: "Render", Name: "Item.Sprite"}, Kind: "changed"}
	if got := plain.QualifiedName(); got != "Render.Item.Sprite" {
		t.Errorf("別の mod の名前まで削っています: %q", got)
	}
}

// VERSION の読み方が 2 か所にあると、片方だけ直したときに何も出ないまま食い違う。
func TestVersionIsReadThroughApidiff(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "Makefile", "VERSION := 0.31.0\n")
	got, ok := apidiff.MakefileVersion(dir)
	if !ok || got != "0.31.0" {
		t.Errorf("VERSION を読めていません got=%q ok=%v", got, ok)
	}
}

func write(t *testing.T, dir, rel, body string) {
	t.Helper()
	path := filepath.Join(dir, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func git(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// 手書きの置き換え表に行がある非互換は、その行を節へのリンク付きで引き、「自分で考えて」とは言わない。
func TestBuildQuotesHandWrittenReplacementRow(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "docs/migrations/0.2.0.md", "# 手当て\n\n## 置き換え（1 行 1 件）\n\n"+
		"| 止まった名前 | 置き換え |\n|---|---|\n"+
		"| `Depth.zAt(範囲, 足元 y)` | `Depth.orderAt(足元 y)` |\n")
	res := apidiff.Result{
		From:     "v0.1.0",
		Breaking: []apidiff.Change{{Key: apidiff.Key{Package: "engine_world", Mod: "Depth", Name: "zAt"}, Kind: "removed"}},
	}
	body, unexplained, _ := build(dir, "0.2.0", res)
	if unexplained != 0 {
		t.Errorf("手書きの表で手当てされているのに追随例の無い数=%d", unexplained)
	}
	for _, want := range []string{
		"](0.2.0.md#置き換え1-行-1-件)",
		"- `Depth.zAt(範囲, 足元 y)` → `Depth.orderAt(足元 y)`",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("%q がありません:\n%s", want, body)
		}
	}
	if strings.Contains(body, "自分で考えてください") {
		t.Errorf("手当てがあるのに自分で考えてと言っています:\n%s", body)
	}
}

// 「同上」は前の行の置き換えに読み替え、列の中の \| は | に戻す（1 行だけ抜き出しても読めるように）。
func TestHandRowsResolveDittoAndEscapedPipe(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "docs/migrations/0.2.0.md", "## 置き換え\n\n| 止まった名前 | 置き換え |\n|---|---|\n"+
		"| `Render.zShiftedAll(d, 列)` | 別の葉にして積む |\n"+
		"| `Render.raiseZ(d, 物)` | 同上（1 個でも） |\n"+
		"| `Timeline.startOf(tag, clips)` | `clipOf(tag, 表) \\|> Option.map(c -> c#start)` |\n")
	rows := handRowsOf(dir, "0.2.0")
	if got := handRowsFor(rows, "Render.raiseZ"); len(got) != 1 || got[0].after != "別の葉にして積む（1 個でも）" {
		t.Errorf("同上を読み替えていません: %+v", got)
	}
	if got := handRowsFor(rows, "Timeline.startOf"); len(got) != 1 || !strings.Contains(got[0].after, "|> Option.map") {
		t.Errorf("\\| を戻していません: %+v", got)
	}
}
