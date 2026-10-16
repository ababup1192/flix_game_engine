package genrules

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// source of truthは bin/lint-rules/gen-rules.json。読み込みがそこからずれていないかを機械で見る。
// WhyNot: 目視の約束にしないのは、ルールを JSON 側だけ足したときにコードが
// 古い 3 本のまま緑を出すため。

var pyLiteral = regexp.MustCompile(`"([^"]*)"`)

func TestLoadRulesFromRepo(t *testing.T) {
	rules, err := LoadRules(repoRoot())
	if err != nil {
		t.Fatal(err)
	}
	if len(rules.Rules) == 0 {
		t.Fatal("ルールが 1 本も無い")
	}
	if rules.Rules[0].Out != "drawing.md" {
		t.Errorf("1 本目が %s (期待 drawing.md)", rules.Rules[0].Out)
	}
	if len(rules.OutDirs) != 2 {
		t.Errorf("配り先が %d 個", len(rules.OutDirs))
	}
	if !strings.Contains(rules.Banner, "{src}") {
		t.Errorf("banner に {src} が無い: %q", rules.Banner)
	}
}

func TestMissingRulesFileAborts(t *testing.T) {
	if _, err := LoadRules(t.TempDir()); err == nil {
		t.Fatal("規約ファイルが無いのにエラーを返さなかった")
	}
}

func TestPartialRulesFileAborts(t *testing.T) {
	root := t.TempDir()
	writeRules(t, root, `{"banner": "x"}`)
	err := loadErr(t, root)
	if !strings.Contains(err.Error(), "rules") {
		t.Errorf("欠けているキーの名前が出ていない: %v", err)
	}
}

func TestRuleWithoutSourceAborts(t *testing.T) {
	root := t.TempDir()
	writeRules(t, root, `{"banner":"x","rules":[{"out":"a.md"}],"outDirs":[]}`)
	if err := loadErr(t, root); !strings.Contains(err.Error(), "out か src") {
		t.Errorf("src の無い項目を受け入れてしまった: %v", err)
	}
}

func TestMoreWithoutMarkersAborts(t *testing.T) {
	root := t.TempDir()
	writeRules(t, root, `{"banner":"x","rules":[{"out":"a.md","src":"a","more":"詳しくは a"}],"outDirs":[]}`)
	if err := loadErr(t, root); !strings.Contains(err.Error(), "coreMarkers") {
		t.Errorf("印の無い more を受け入れてしまった: %v", err)
	}
}

func TestBrokenRulesFileAborts(t *testing.T) {
	root := t.TempDir()
	writeRules(t, root, "{")
	loadErr(t, root)
}

func writeRules(t *testing.T, root, body string) {
	t.Helper()
	path := filepath.Join(root, RulesPath)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func loadErr(t *testing.T, root string) error {
	t.Helper()
	_, err := LoadRules(root)
	if err == nil {
		t.Fatal("壊れた規約ファイルを受け入れてしまった")
	}
	return err
}
