package headlessrun

import (
	"bufio"
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// unbracedBeforeWide は、変数（Makefile の $$x も）の直後に ASCII でない字が続く所。
// bash は全角の字のバイトを変数名の続きと読むので、"（鍵: $lock）" は set -u で「lock�: unbound variable」になる
// （2026-10 に Mac mini で headless-run が落ち、ゲームの reference-check と make flow が全部止まった）。${lock} と書く。
var unbracedBeforeWide = regexp.MustCompile(`\$\$?[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]`)

// shellFiles は bin/ と bin/githooks/ のシェル（頭の #! に sh を含む物）・Makefile・mk/*.mk。
func shellFiles(t *testing.T) []string {
	t.Helper()
	var files []string
	for _, dir := range []string{"bin", filepath.Join("bin", "githooks")} {
		entries, err := os.ReadDir(filepath.Join(repoRoot(), dir))
		if err != nil {
			t.Fatal(err)
		}
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			path := filepath.Join(repoRoot(), dir, e.Name())
			if isShell(path) {
				files = append(files, path)
			}
		}
	}
	mks, err := filepath.Glob(filepath.Join(repoRoot(), "mk", "*.mk"))
	if err != nil {
		t.Fatal(err)
	}
	files = append(files, filepath.Join(repoRoot(), "Makefile"))
	return append(files, mks...)
}

func isShell(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	head := make([]byte, 64)
	n, _ := f.Read(head)
	line, _, _ := bytes.Cut(head[:n], []byte("\n"))
	return bytes.HasPrefix(line, []byte("#!")) && bytes.Contains(line, []byte("sh"))
}

func TestNoUnbracedVariableBeforeWideChar(t *testing.T) {
	files := shellFiles(t)
	if len(files) < 3 {
		t.Fatalf("見るファイルが少なすぎる（%d 本）: %v", len(files), files)
	}
	for _, path := range files {
		f, err := os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		for n := 1; sc.Scan(); n++ {
			line := sc.Text()
			if strings.HasPrefix(strings.TrimSpace(line), "#") {
				continue
			}
			if m := unbracedBeforeWide.FindString(line); m != "" {
				t.Errorf("%s:%d: %q — 変数の直後に全角の字。${名前} と書く", path, n, m)
			}
		}
		f.Close()
	}
}

// TestPatternCatchesTheIncident は、落ちた行の形を正規表現が拾うこと（拾えなければ上のテストは素通りする）。
func TestPatternCatchesTheIncident(t *testing.T) {
	for _, line := range []string{`"（鍵: $lock）"`, `.claude=$$b）。`} {
		if !unbracedBeforeWide.MatchString(line) {
			t.Errorf("拾えない: %s", line)
		}
	}
	for _, line := range []string{`"（鍵: ${lock}）"`, `.claude=$${b}）。`, `$lock の`} {
		if unbracedBeforeWide.MatchString(line) {
			t.Errorf("拾いすぎ: %s", line)
		}
	}
}
