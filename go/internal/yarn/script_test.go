package yarn

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const scriptText = `// 演出:
//   <<lights 秒>>        暗闇から海の底が現れる（<<black 秒>> で黒へ落とす）
//   <<witch on|off>>     魔女が現れる／去る
//   <<puff>>             少女の口から泡

// ── 入り江: 少女が魔女に会う
title: Cove
---
<<declare $deep = true>>
<<lights 1.8>>
<<wait 0.6>>
witch: おや。／海の者でないね
[ruby=よる]夜[/ruby]の海は冷たい。
<<witch on>>
-> 上へ #act:up
<<puff>>
-> 上へ #act:up #mute
<<puff>>
-> 行く #act:up
    witch: ついておいで #line:a1
-> 戻る
    <<jump Cove>>
<<if $deep>>
    <<jump Deep>>
<<endif>>
<<jump Deep>>
===
// ── 海の底: 誰もいない
title: Deep
---
<<puff>>
<<se splash>>
<<jump Nowhere>>
<<stop>>
===
`

func scriptOfText(t *testing.T, text string, names, fileNotes map[string]string) []ScriptLine {
	t.Helper()
	prog, _ := buildText(t, text, nil)
	return BuildScript(ScriptSource{Prog: prog, Comments: NodeComments(text), Names: names,
		Notes: Notes{File: fileNotes, Comment: CommentNotes(text)}})
}

func scriptMD(t *testing.T) string {
	t.Helper()
	return RenderScript(scriptOfText(t, scriptText, map[string]string{"witch": "魔女"}, nil))
}

func TestScriptWritesSpeakerByDisplayName(t *testing.T) {
	if md := scriptMD(t); !strings.Contains(md, "魔女「おや。\n") {
		t.Fatalf("話し手が表示の名前で出ない:\n%s", md)
	}
}

func TestScriptIndentsContinuedLinesByNameWidth(t *testing.T) {
	if md := scriptMD(t); !strings.Contains(md, "\n　　　海の者でないね」\n") {
		t.Fatalf("続きの行が名前の幅で字下げされない:\n%s", md)
	}
}

func TestScriptWritesRubyAsReading(t *testing.T) {
	if md := scriptMD(t); !strings.Contains(md, "\n｜夜《よる》の海は冷たい。\n") {
		t.Fatalf("ルビが ｜字《よみ》 で出ない:\n%s", md)
	}
}

func TestScriptHeadingUsesFirstText(t *testing.T) {
	if md := scriptMD(t); !strings.Contains(md, "## 1「おや。」　〔Cove〕\n> 入り江: 少女が魔女に会う\n") {
		t.Fatalf("見出しとコメント:\n%s", md)
	}
}

func TestScriptHeadingWithoutTextUsesComment(t *testing.T) {
	if md := scriptMD(t); !strings.Contains(md, "## 2「〔海の底〕」　〔Deep〕") {
		t.Fatalf("文の無いノードの見出し:\n%s", md)
	}
}

func TestScriptWritesGateWithGuide(t *testing.T) {
	if md := scriptMD(t); !strings.Contains(md, "\n【↑ 上へ払う】　案内「上へ」\n") {
		t.Fatalf("ゲート:\n%s", md)
	}
}

func TestScriptMutedGateHasNoGuide(t *testing.T) {
	if md := scriptMD(t); !strings.Contains(md, "\n【↑ 上へ払う】\n") {
		t.Fatalf("#mute のゲート:\n%s", md)
	}
}

func TestScriptWritesChoiceWithMarks(t *testing.T) {
	if md := scriptMD(t); !strings.Contains(md, "◆ 選ぶ\n　・行く（↑）\n　　魔女「ついておいで」\n\n　・戻る\n") {
		t.Fatalf("選択肢:\n%s", md)
	}
}

func TestScriptJumpNamesTargetHeading(t *testing.T) {
	if md := scriptMD(t); !strings.Contains(md, "\n→ 2「〔海の底〕」 へ\n") {
		t.Fatalf("jump の行き先:\n%s", md)
	}
}

func TestScriptJumpToMissingNode(t *testing.T) {
	if md := scriptMD(t); !strings.Contains(md, "→ （無い場面 Nowhere） へ") {
		t.Fatalf("無いノードへの jump:\n%s", md)
	}
}

func TestScriptStopIsEnd(t *testing.T) {
	if md := scriptMD(t); !strings.Contains(md, "\n■ おわり\n") {
		t.Fatalf("stop:\n%s", md)
	}
}

func TestScriptJoinsCommandsAndWait(t *testing.T) {
	if md := scriptMD(t); !strings.Contains(md, "\n〔暗闇から海の底が現れる（1.8）〕（間 0.6 秒）\n") {
		t.Fatalf("演出と間:\n%s", md)
	}
}

func TestScriptNoteFromCommentAlternative(t *testing.T) {
	if md := scriptMD(t); !strings.Contains(md, "〔魔女が現れる〕") {
		t.Fatalf("on|off の 1 つ目:\n%s", md)
	}
}

func TestCommentNotesReadsAsideInParens(t *testing.T) {
	if got := CommentNotes(scriptText)["black"]; got != "黒へ落とす" {
		t.Fatalf("（）の中の <<black>>: %q", got)
	}
}

func TestScriptNoteFromFileWinsOverComment(t *testing.T) {
	md := RenderScript(scriptOfText(t, scriptText, nil, map[string]string{"puff": "泡がのぼる"}))
	if !strings.Contains(md, "〔泡がのぼる〕") {
		t.Fatalf("script-notes.json の言葉が先に効かない:\n%s", md)
	}
}

func TestScriptNoteFromFileReplacesArgs(t *testing.T) {
	md := RenderScript(scriptOfText(t, scriptText, nil, map[string]string{"se": "効果音 {args}"}))
	if !strings.Contains(md, "〔効果音 splash〕") {
		t.Fatalf("{args} の置き換え:\n%s", md)
	}
}

func TestScriptNoteFallsBackToCommandText(t *testing.T) {
	if md := scriptMD(t); !strings.Contains(md, "〔se splash〕") {
		t.Fatalf("どちらにも無いコマンド:\n%s", md)
	}
}

// editScript は今のシナリオ原稿の old を new に置き換えた物と、比べた差分を返す。
func editScript(t *testing.T, old, new string) string {
	t.Helper()
	base := scriptOfText(t, scriptText, map[string]string{"witch": "魔女"}, nil)
	md := RenderScript(base)
	if !strings.Contains(md, old) {
		t.Fatalf("原稿に %q が無い", old)
	}
	return DiffScript(base, strings.Replace(md, old, new, 1), map[string]string{"witch": "魔女"}, "／")
}

func TestDiffReplaceGivesYarnLineWithSpeakerID(t *testing.T) {
	got := editScript(t, "魔女「おや。\n　　　海の者でないね」", "魔女「おやおや。\n　　　海の者でないね」")
	if !strings.Contains(got, "## 1. 書き替え — t.yarn:12（Cove）") || !strings.Contains(got, "Yarn の行: `witch: おやおや。／海の者でないね`") {
		t.Fatalf("書き替え:\n%s", got)
	}
}

func TestDiffKeepsRubyRoundTrip(t *testing.T) {
	got := editScript(t, "｜夜《よる》の海は冷たい。", "｜夜《よる》の海は暗い。")
	if !strings.Contains(got, "Yarn の行: `[ruby=よる]夜[/ruby]の海は暗い。`") {
		t.Fatalf("ルビの往復:\n%s", got)
	}
}

func TestDiffInsertPointsAtPreviousLine(t *testing.T) {
	got := editScript(t, "｜夜《よる》の海は冷たい。\n", "｜夜《よる》の海は冷たい。\n\n波が寄せる。\n")
	if !strings.Contains(got, "書き足し（この行の後へ） — t.yarn:13（Cove）") || !strings.Contains(got, "Yarn の行: `波が寄せる。`") {
		t.Fatalf("書き足し:\n%s", got)
	}
}

func TestDiffDeleteNamesTheLine(t *testing.T) {
	got := editScript(t, "｜夜《よる》の海は冷たい。\n\n", "")
	if !strings.Contains(got, "## 1. 消した — t.yarn:13（Cove）") {
		t.Fatalf("消した:\n%s", got)
	}
}

func TestDiffNoteBlockIsDirectionRequest(t *testing.T) {
	got := editScript(t, "■ おわり\n", "〔雷が鳴る〕\n■ おわり\n")
	if !strings.Contains(got, "演出の要望") {
		t.Fatalf("〔〕の書き足し:\n%s", got)
	}
}

func TestDiffWithoutChangesSaysSo(t *testing.T) {
	if got := editScript(t, "■ おわり", "■ おわり"); !strings.Contains(got, "直しはありません。") {
		t.Fatalf("直しの無い時:\n%s", got)
	}
}

func TestScriptCommandWritesDefaultFileWithNotesFile(t *testing.T) {
	dir := t.TempDir()
	talk := filepath.Join(dir, "assets", "talk")
	for path, body := range map[string]string{
		filepath.Join(dir, "project.json"):               `{"title": "入り江"}`,
		filepath.Join(dir, "assets", "novel.story.json"): `{"names": {"witch": "魔女"}}`,
		filepath.Join(talk, "cove.yarn"):                 scriptText,
		filepath.Join(talk, scriptNotesName):             `{"puff": "泡がのぼる"}`,
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	var out, errOut strings.Builder
	if code := Run(&out, &errOut, dir, []string{"script", "assets/talk"}); code != 0 {
		t.Fatalf("code %d: %s %s", code, out.String(), errOut.String())
	}
	data, err := os.ReadFile(filepath.Join(dir, "build", "yarn-script.md"))
	if err != nil {
		t.Fatal(err)
	}
	if md := string(data); !strings.Contains(md, "# シナリオ原稿 — 入り江") || !strings.Contains(md, "〔泡がのぼる〕") || !strings.Contains(md, "魔女「") {
		t.Fatalf("書いた原稿:\n%s", md)
	}
}

func TestScriptCommandDiffPrintsReport(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "cove.yarn"), []byte(scriptText), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	if code := Run(&out, &errOut, dir, []string{"script", "cove.yarn", "--out", "s.md"}); code != 0 {
		t.Fatalf("code %d: %s", code, errOut.String())
	}
	data, _ := os.ReadFile(filepath.Join(dir, "s.md"))
	edited := strings.Replace(string(data), "■ おわり", "■ おしまい", 1)
	if err := os.WriteFile(filepath.Join(dir, "e.md"), []byte(edited), 0o644); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if code := Run(&out, &errOut, dir, []string{"script", "--diff", "e.md", "."}); code != 0 {
		t.Fatalf("code %d: %s", code, errOut.String())
	}
	if !strings.Contains(out.String(), "書き替え — cove.yarn:") || !strings.Contains(out.String(), "流れの直し") {
		t.Fatalf("報告:\n%s", out.String())
	}
}

func TestLineSeparatorFollowsScript(t *testing.T) {
	prog, _ := buildText(t, "title: A\n---\nme: 一\\n二\n===\n", nil)
	if got := lineSeparator(prog); got != `\n` {
		t.Fatalf("\\n で改行するシナリオの区切り: %q", got)
	}
}

func TestDiffSpeechInsideChoiceKeepsSpeakerID(t *testing.T) {
	// 選択肢の中の（字下げした）台詞の直しも、話し手の id と元のタグで反映の行を出す。
	got := editScript(t, "　　魔女「ついておいで」", "　　魔女「ついてきな」")
	if !strings.Contains(got, "Yarn の行: `witch: ついてきな #line:a1`") {
		t.Fatalf("選択肢の中の台詞:\n%s", got)
	}
}

func TestDiffIgnoresDroppedIndent(t *testing.T) {
	// 行頭の全角の空白を落としただけの原稿は、直しにならない。
	base := scriptOfText(t, scriptText, map[string]string{"witch": "魔女"}, nil)
	md := strings.ReplaceAll(RenderScript(base), "\n　", "\n")
	if got := DiffScript(base, md, map[string]string{"witch": "魔女"}, "／"); !strings.Contains(got, "直しはありません。") {
		t.Fatalf("字下げを落とした原稿:\n%s", got)
	}
}

func TestDiffOptionGivesChoiceLineWithTags(t *testing.T) {
	// 選択肢の字の直しは、元のタグを付け直した -> の行。
	got := editScript(t, "　・行く（↑）", "　・進む（↑）")
	if !strings.Contains(got, "Yarn の選択肢の行: `-> 進む #act:up`") {
		t.Fatalf("選択肢の字:\n%s", got)
	}
}

func TestDiffGateGuideGivesChoiceLine(t *testing.T) {
	// ゲートの案内の直しは、元のタグを付け直した -> の行。
	got := editScript(t, "【↑ 上へ払う】　案内「上へ」", "【↑ 上へ払う】　案内「上へ払って」")
	if !strings.Contains(got, "`-> 上へ払って #act:up`") {
		t.Fatalf("ゲートの案内:\n%s", got)
	}
}

func TestDiffConditionIsConditionEdit(t *testing.T) {
	// 〔もし …〕の直しは条件の直し（演出の要望と取り違えない）。
	if got := editScript(t, "〔もし $deep〕", "〔もし not $deep〕"); !strings.Contains(got, "条件の直し") {
		t.Fatalf("条件:\n%s", got)
	}
}

func TestDiffHeadingCommentIsCommentEdit(t *testing.T) {
	// > のコメントの直しは、title: の上の // ── コメントの直し。
	if got := editScript(t, "> 入り江: 少女が魔女に会う", "> 入り江: 少女が魔女に出会う"); !strings.Contains(got, "// ── コメントを直す") {
		t.Fatalf("コメント:\n%s", got)
	}
}

func TestDiffAdjacentEditsKeepTheirOwnLines(t *testing.T) {
	// 隣り合う 2 つの段落の直しは、それぞれの .yarn の行で 2 件に出る。
	base := scriptOfText(t, scriptText, map[string]string{"witch": "魔女"}, nil)
	md := RenderScript(base)
	md = strings.Replace(md, "魔女「おや。", "魔女「おやおや。", 1)
	md = strings.Replace(md, "の海は冷たい。", "の海は暗い。", 1)
	got := DiffScript(base, md, map[string]string{"witch": "魔女"}, "／")
	if !strings.Contains(got, "## 1. 書き替え — t.yarn:12") || !strings.Contains(got, "## 2. 書き替え — t.yarn:13") {
		t.Fatalf("隣り合う直し:\n%s", got)
	}
}

func TestDiffEscapesYarnMarks(t *testing.T) {
	// ライターの字の : や # は .yarn のエスケープを付ける（話し手やタグに読まれない）。
	got := editScript(t, "｜夜《よる》の海は冷たい。", "時刻は 10:00 #1")
	if !strings.Contains(got, "`時刻は 10\\:00 \\#1`") {
		t.Fatalf("エスケープ:\n%s", got)
	}
}

func TestDiffQuoteInNarrationStaysNarration(t *testing.T) {
	// 地の文の直しに「」があっても、話し手の行にしない。
	got := editScript(t, "｜夜《よる》の海は冷たい。", "誰か「おーい」と呼んだ。")
	if !strings.Contains(got, "Yarn の行: `誰か「おーい」と呼んだ。`") {
		t.Fatalf("地の文の「」:\n%s", got)
	}
}

func TestDiffKeepsExpressionRoundTrip(t *testing.T) {
	// {$x} の式はエスケープせずに戻す。
	got := editScript(t, "｜夜《よる》の海は冷たい。", "切符は {$deep} 枚")
	if !strings.Contains(got, "`切符は {$deep} 枚`") {
		t.Fatalf("式:\n%s", got)
	}
}

func TestDiffNewlineScriptJoinsWithBackslashN(t *testing.T) {
	// \n で改行するシナリオは、直した行も \n でつなぐ。
	text := "title: A\n---\nme: 一\\n二\n===\n"
	prog, _ := buildText(t, text, nil)
	base := BuildScript(ScriptSource{Prog: prog, Names: map[string]string{"me": "私"}})
	md := strings.Replace(RenderScript(base), "　　二」", "　　三」", 1)
	if got := DiffScript(base, md, map[string]string{"me": "私"}, lineSeparator(prog)); !strings.Contains(got, "`me: 一\\n三`") {
		t.Fatalf("\\n の往復:\n%s", got)
	}
}

func TestCommentNotesAlternativeSecondPart(t *testing.T) {
	// on|off の 2 つ目は説明の ／ の後ろ。
	if got := CommentNotes(scriptText)["witch off"]; got != "去る" {
		t.Fatalf("witch off: %q", got)
	}
}

func TestScriptCommandRejectsUnknownFlag(t *testing.T) {
	var out, errOut strings.Builder
	if code := Run(&out, &errOut, t.TempDir(), []string{"script", "--nope", "."}); code != 2 || !strings.Contains(errOut.String(), "知らない指定") {
		t.Fatalf("code %d: %s", code, errOut.String())
	}
}

func TestDiffWarnsWhenScriptChanged(t *testing.T) {
	// 原稿の頭の指紋が今の .yarn と違えば、--diff が errOut で知らせる。
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "cove.yarn"), []byte(scriptText), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "e.md"), []byte("<!-- yarn: 000000000000 -->\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	Run(&out, &errOut, dir, []string{"script", "--diff", "e.md", "."})
	if !strings.Contains(errOut.String(), "シナリオが変わっている") || strings.Contains(out.String(), "注意") {
		t.Fatalf("errOut: %s\nout: %s", errOut.String(), out.String())
	}
}

func TestForTapeWithoutYarnIsEmpty(t *testing.T) {
	// フォルダはあっても .yarn が無ければ、グラフもシナリオ原稿も作らない。
	g, md, err := ForTape(t.TempDir())
	if g != nil || md != "" || err != nil {
		t.Fatalf("%v %q %v", g, md, err)
	}
}

// 条件と <<set>> の〔〕は変数を「表示名（$名前）」で書き、台詞の {$x} はそのまま。--diff は何も直さなければ空で、
// 表示名の付いた条件を書き替えると「式を直す」と言う（表示名を .yarn へ戻さない）。
func TestScriptNamesVariablesAndDiffSurvives(t *testing.T) {
	text := "title: A\n---\n<<declare $closeness = 0>>\n<<set $closeness to 1>>\n<<if $closeness >= 2>>\nwitch: {$closeness} だね\n<<endif>>\n===\n"
	prog, _ := buildText(t, text, nil)
	names := map[string]string{"witch": "魔女"}
	base := BuildScript(ScriptSource{Prog: prog, Comments: NodeComments(text), Names: names,
		Notes: Notes{Comment: CommentNotes(text)}, Vars: map[string]string{"$closeness": "親しさ"}})
	md := RenderScript(base)
	if !strings.Contains(md, "〔もし 親しさ（$closeness） >= 2〕") || !strings.Contains(md, "〔親しさ（$closeness） を 1 にする〕") || !strings.Contains(md, "{$closeness} だね") {
		t.Fatalf("got\n%s", md)
	}
	if got := DiffScript(base, md, names, "／"); !strings.Contains(got, "直しはありません。") {
		t.Errorf("直さない原稿で差分: %s", got)
	}
	edited := strings.Replace(md, "親しさ（$closeness） >= 2", "親しさ（$closeness） >= 3", 1)
	if got := DiffScript(base, edited, names, "／"); !strings.Contains(got, "条件の直し") || strings.Contains(got, "Yarn の行: `親しさ") {
		t.Errorf("got %s", got)
	}
}

// 式の文字列の中の $ は変数の表示名にしない。
func TestVarLabelsSkipStringLiterals(t *testing.T) {
	got := withVarLabels(`$house == "$house \"x\"" and $house`, map[string]string{"$house": "家"})
	if got != `家（$house） == "$house \"x\"" and 家（$house）` {
		t.Errorf("got %s", got)
	}
}
