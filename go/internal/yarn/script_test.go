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
-> 戻る
    <<jump Cove>>
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
	if md := scriptMD(t); !strings.Contains(md, "◆ 選ぶ\n　・行く（↑）\n　・戻る\n") {
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

// editScript は今の読み台本の old を new に置き換えた物と、照らした結果を返す。
func editScript(t *testing.T, old, new string) string {
	t.Helper()
	base := scriptOfText(t, scriptText, map[string]string{"witch": "魔女"}, nil)
	md := RenderScript(base)
	if !strings.Contains(md, old) {
		t.Fatalf("読み台本に %q が無い", old)
	}
	return DiffScript(base, strings.Replace(md, old, new, 1), map[string]string{"witch": "魔女"}, "／")
}

func TestDiffReplaceGivesYarnLineWithSpeakerID(t *testing.T) {
	got := editScript(t, "魔女「おや。\n　　　海の者でないね」", "魔女「おやおや。\n　　　海の者でないね」")
	if !strings.Contains(got, "## 1. 書き替え — t.yarn:11（Cove）") || !strings.Contains(got, "Yarn の行: `witch: おやおや。／海の者でないね`") {
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
	if !strings.Contains(got, "書き足し（この行の後へ） — t.yarn:12（Cove）") || !strings.Contains(got, "Yarn の行: `波が寄せる。`") {
		t.Fatalf("書き足し:\n%s", got)
	}
}

func TestDiffDeleteNamesTheLine(t *testing.T) {
	got := editScript(t, "｜夜《よる》の海は冷たい。\n\n", "")
	if !strings.Contains(got, "## 1. 消した — t.yarn:12（Cove）") {
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
	if md := string(data); !strings.Contains(md, "# 読み台本 — 入り江") || !strings.Contains(md, "〔泡がのぼる〕") || !strings.Contains(md, "魔女「") {
		t.Fatalf("書いた台本:\n%s", md)
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
	if !strings.Contains(out.String(), "書き替え — cove.yarn:") || !strings.Contains(out.String(), "流れの行") {
		t.Fatalf("報告:\n%s", out.String())
	}
}

func TestLineSeparatorFollowsScript(t *testing.T) {
	prog, _ := buildText(t, "title: A\n---\nme: 一\\n二\n===\n", nil)
	if got := lineSeparator(prog); got != `\n` {
		t.Fatalf("\\n で改行するシナリオの区切り: %q", got)
	}
}
