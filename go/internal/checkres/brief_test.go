package checkres

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBriefCutsTheSitesAndEndsWithNext(t *testing.T) {
	lines := []string{"src/A.flix:1:1\tA.f", "src/A.flix:2:1\tA.g", "src/B.flix:3:1\tB.h"}
	s := Sites{Lines: lines, Limit: 2}
	path := filepath.Join(t.TempDir(), "last.txt")
	s.Save(path)
	b := Brief{Head: "usages A.f", Count: "3 か所", Notes: []string{"1", "2", "3", "4"}, Sites: s, Next: "bin/fge x", NextWhy: "訳"}
	text := b.Text()
	got := strings.Split(strings.TrimRight(text, "\n"), "\n")
	want := []string{
		"usages A.f", "  3 か所", "  1", "  2", "  3", "  （注ほか 1 行は -v で）",
		"  src/A.flix:1:1  A.f", "  src/A.flix:2:1  A.g",
		"  ファイルごと: src/A.flix 2・src/B.flix 1",
		"  …ほか 1 件（全部は " + path + "・--all で画面に）",
		"next: bin/fge x", "  （訳）",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("got\n%s\nwant\n%s", text, strings.Join(want, "\n"))
	}
	data, err := os.ReadFile(path)
	if err != nil || strings.Count(string(data), "\n") != 3 {
		t.Errorf("全部のファイル: %v\n%s", err, data)
	}
}

func TestSitesSaveWritesNothingWhenAllAreShown(t *testing.T) {
	s := Sites{Lines: []string{"a:1:1"}, Limit: 10}
	path := filepath.Join(t.TempDir(), "last.txt")
	s.Save(path)
	if _, err := os.Stat(path); err == nil || s.Path != "" {
		t.Error("切らない時にファイルを書いた")
	}
}
