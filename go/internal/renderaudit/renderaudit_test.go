package renderaudit

// 何を守るか: 許す物の鍵の意味（一致・含む・字全体の正規表現・はみ出しの上限）、書いた鍵だけで絞ること、
// 表の読み方（見出しの名前で引く・引用符を解かない）、表が無いときは通すこと、reason の無い許す物を止めること、
// ゲームの local.json が table・hint を上書きすること。

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func row(shot, kind, excess, text, other string) Row {
	return Row{"shot": shot, "kind": kind, "excess": excess, "text": text, "other": other}
}

func ptr(f float64) *float64 { return &f }

func TestAllowedNeedsEveryWrittenKeyToMatch(t *testing.T) {
	rules := []AllowRule{{Kind: "Overflow", Shot: "fight_orb", Text: "盾"}}
	if Allowed(row("fight_orb", "Overlap", "1", "盾 3", ""), rules) {
		t.Fatal("kind が違うのに許した")
	}
}

func TestAllowedTextIsContains(t *testing.T) {
	rules := []AllowRule{{Kind: "Overflow", Text: "盾"}}
	if !Allowed(row("fight_orb", "Overflow", "7.3", "盾 3", ""), rules) {
		t.Fatal("text を含むのに許さなかった")
	}
}

func TestAllowedTextMatchIsWholeText(t *testing.T) {
	rules := []AllowRule{{TextMatch: "[0-9]+%?", match: regexp.MustCompile(`^(?:[0-9]+%?)$`)}}
	if Allowed(row("s", "Overflow", "1", "x12", ""), rules) {
		t.Fatal("字の一部だけ当たったのに許した")
	}
}

func TestAllowedMaxExcessIsInclusive(t *testing.T) {
	rules := []AllowRule{{Kind: "Overflow", MaxExcess: ptr(4.0)}}
	got := []bool{
		Allowed(row("s", "Overflow", "4.0", "1", ""), rules),
		Allowed(row("s", "Overflow", "4.5", "1", ""), rules),
	}
	if !got[0] || got[1] {
		t.Fatalf("上限ちょうどは許し・超えたら許さない: %v", got)
	}
}

func TestReadTableKeepsQuotesAndSkipsBlankLines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "t.tsv")
	os.WriteFile(path, []byte("shot\tkind\texcess\ttext\tother\na\tOverlap\t1.0\t\"引用\"\t\n\n"), 0o644)
	rows, err := ReadTable(path)
	if err != nil || len(rows) != 1 || rows[0]["text"] != `"引用"` {
		t.Fatalf("rows=%v err=%v", rows, err)
	}
}

func writeRepo(t *testing.T, files map[string]string) string {
	root := t.TempDir()
	for rel, body := range files {
		p := filepath.Join(root, filepath.FromSlash(rel))
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte(body), 0o644)
	}
	return root
}

const textRules = `{"table": "debug/ui-overflow.tsv", "hint": ""}`

func TestRunTextPassesWithoutTable(t *testing.T) {
	root := writeRepo(t, map[string]string{"bin/lint-rules/text-audit.json": textRules})
	var out strings.Builder
	code, err := RunText(&out, Options{Root: root})
	if err != nil || code != 0 {
		t.Fatalf("code=%d err=%v out=%s", code, err, out.String())
	}
}

func TestRunTextRejectsAllowWithoutReason(t *testing.T) {
	root := writeRepo(t, map[string]string{
		"bin/lint-rules/text-audit.json":       textRules,
		"bin/lint-rules/text-audit.local.json": `{"allow": [{"kind": "Overlap"}]}`,
	})
	var out strings.Builder
	if code, err := RunText(&out, Options{Root: root}); err == nil || code != 2 {
		t.Fatalf("reason の無い許す物を通した: code=%d", code)
	}
}

func TestRunZLocalOverridesTableAndHint(t *testing.T) {
	root := writeRepo(t, map[string]string{
		"bin/lint-rules/z-audit.json":       `{"table": "debug/z-audit.tsv", "hint": "engine の言い方"}`,
		"bin/lint-rules/z-audit.local.json": `{"table": "out/z.tsv", "hint": "ゲームの言い方"}`,
		"out/z.tsv":                         "shot\tz\twhat\tallowed\ntitle\t99\tBox\t0..31\n",
	})
	var out strings.Builder
	code, err := RunZ(&out, Options{Root: root})
	if err != nil || code != 1 || !strings.Contains(out.String(), "1 件 — ゲームの言い方") {
		t.Fatalf("code=%d err=%v out=%s", code, err, out.String())
	}
}
