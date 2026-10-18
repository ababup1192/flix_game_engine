package snd

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// 結果は newFinding の 1 か所で組み立てる（got と want を必ず持たせる）。
func TestFindingsAreBuiltInOnePlace(t *testing.T) {
	files, _ := filepath.Glob("*.go")
	lit := regexp.MustCompile(`\bfinding\{[A-Z]`)
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		data, _ := os.ReadFile(f)
		for i, line := range strings.Split(string(data), "\n") {
			if lit.MatchString(line) && !strings.Contains(line, "return finding{Check: check, Level: lv, Got: got, Want: want, Msg: msg}") {
				t.Errorf("%s:%d: finding{…} を直に書いている（newFinding で組み立てる）", f, i+1)
			}
		}
	}
}

// 表の snd の code には直し方の文がある。
func TestEveryCodeHasHint(t *testing.T) {
	for _, c := range sndCodes {
		if fixHints[c.Name] == "" {
			t.Errorf("%s の直し方の文が fixHints に無い", c.Name)
		}
	}
}
