package lintconf

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// TestRepo は検査のテスト用の使い捨てリポを組む。規約は engine の bin/lint-rules/<名前>.json を
// そのまま写す (配る規約が壊れていたらテストが落ちる)。files の鍵は根からの相対。
func TestRepo(t *testing.T, name string, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	rulesRel, _ := Paths(name)
	body, err := os.ReadFile(filepath.Join("..", "..", "..", rulesRel))
	if err != nil {
		t.Fatal(err)
	}
	all := map[string]string{rulesRel: string(body)}
	for k, v := range files {
		all[k] = v
	}
	for rel, text := range all {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// GitInit は TestRepo を git のリポにする (--all は git ls-files で数えるため)。コミットはしない。
func GitInit(t *testing.T, root string) {
	t.Helper()
	for _, args := range [][]string{{"init", "-q"}, {"add", "-A"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = root
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
}
