package refactor

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 出力の約束（設計 §8.3）: 既定は数行で、全部の操作が終わりに next を出す。場所が多ければ上位だけ見せ、全部をファイルへ。

func TestEveryOpEndsWithTheNextCommandOrNothingElse(t *testing.T) {
	for _, args := range [][]string{
		{"refs", "Shapes.area"},
		{"usages", "Shapes.area"},
		{"match-sites", "Shape"},
		{"field-sites", "--label", "count", "--receiver", "World"},
	} {
		code, text := run(t, project(t), args...)
		lines := strings.Split(strings.TrimRight(text, "\n"), "\n")
		if code != 0 || len(lines) > 16 {
			t.Errorf("%v: exit %d・%d 行（16 行まで）\n%s", args, code, len(lines), text)
		}
		for i, l := range lines {
			if strings.HasPrefix(l, "next: ") && i < len(lines)-2 {
				t.Errorf("%v: next が終わりに無い\n%s", args, text)
			}
		}
		if strings.Contains(text, "want:") || strings.Contains(text, "索引 resolved") {
			t.Errorf("%v: 既定に -v の行が出た\n%s", args, text)
		}
	}
}

func TestLimitWritesEverySiteToAFileAndSaysWhere(t *testing.T) {
	root := project(t)
	_, text := run(t, root, "usages", "Shapes.Shape", "--limit", "1")
	data, err := os.ReadFile(filepath.Join(root, "build", "refactor", "last-usages.txt"))
	if err != nil || !strings.Contains(text, "全部は build/refactor/last-usages.txt") || !strings.Contains(text, "ファイルごと:") {
		t.Fatalf("%v\n%s", err, text)
	}
	if n := strings.Count(string(data), "\n"); n < 2 {
		t.Errorf("ファイルの行 %d（2 以上のはず）\n%s", n, data)
	}
}

func TestVerboseKeepsTheFullText(t *testing.T) {
	_, text := run(t, project(t), "refs", "Shapes.area", "-v")
	if !strings.Contains(text, "got:") || !strings.Contains(text, "索引 resolved") {
		t.Errorf("-v に got・索引の行が無い\n%s", text)
	}
}

// 依存（lib/）が無い時: 道具は make を流さず、flixlint の止めた文の後に next: make check を出す（設計 §8.1）。
func TestMissingDependenciesNameMakeCheckWithoutRunningIt(t *testing.T) {
	root := project(t)
	verified := 0
	var out, errOut strings.Builder
	runner := func(_ Stage, _, _ string, _ []string, log string) int {
		os.WriteFile(log, []byte("flixlint: lib/github/x/y/1.0/y-1.0.fpkg is missing; run 'flix check' once in "+root+"\n"), 0o644)
		return 4
	}
	code := Run(&out, &errOut, root, []string{"refs", "Shapes.area", "--flixlint", filepath.Join(root, "flixlint")},
		Options{Run: runner, Log: io.Discard, Verify: func(string, string, string) int { verified++; return 0 }})
	if code != 2 || verified != 0 || !strings.Contains(errOut.String(), "next: make check") {
		t.Errorf("exit %d・確かめの口 %d 回\n%s", code, verified, errOut.String())
	}
}

// 前の版の refactor.local.json に prepare が残っていても読める（欄は消した。make を流す設定は無い）。
func TestConfigIgnoresTheRemovedPrepareField(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "bin", "lint-rules")
	must(t, os.MkdirAll(dir, 0o755))
	must(t, os.WriteFile(filepath.Join(dir, "refactor.local.json"), []byte(`{"prepare": "make check"}`), 0o644))
	if _, err := LoadConfig(root); err != nil {
		t.Error(err)
	}
}
