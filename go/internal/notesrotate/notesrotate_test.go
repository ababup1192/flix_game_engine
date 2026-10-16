package notesrotate

// 何を守るか: 先頭から keepEntries 個・maxLines 行を超えた古い項だけが月ごとのファイルへ送られること、
// 見出し（make status が読む所）は残ること、送り先の既存の項の前に新しい順で入ること、
// 区切りの見出し（# NOTES）は送らずに名指しで落とすこと、--check は書かずに 1 を返すこと。

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const rulesJSON = `{
  "notesFile": "NOTES.md",
  "archiveDir": "notes",
  "keepEntries": 2,
  "maxLines": 100,
  "entryPatterns": ["^\\*\\*(\\d{4})-(\\d{2})-\\d{2}", "^#{1,4}\\s+(\\d{4})-(\\d{2})-\\d{2}"],
  "archiveHeader": "# NOTES {month}"
}`

const notes = `## やること（次のセッションの入口）

**2026-10-17 (c): 3 つ目**
- c の続き

**2026-10-16 (b): 2 つ目**
- b の続き

**2026-10-02 (a): 1 つ目**
- a の続き

# NOTES

## 2026-08-17 — 古い項
本文
`

func setup(t *testing.T, archive map[string]string) string {
	t.Helper()
	root := t.TempDir()
	write := func(rel, body string) {
		p := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(RulesPath, rulesJSON)
	write("NOTES.md", notes)
	for k, v := range archive {
		write(k, v)
	}
	return root
}

func read(t *testing.T, root, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(root, rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func run(t *testing.T, root string, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, args)
	if err != nil {
		t.Fatal(err)
	}
	return code, out.String() + errOut.String()
}

func TestKeepsHeadAndNewestEntries(t *testing.T) {
	root := setup(t, nil)
	if code, _ := run(t, root); code != 0 {
		t.Fatalf("code %d", code)
	}
	want := "## やること（次のセッションの入口）\n\n**2026-10-17 (c): 3 つ目**\n- c の続き\n\n**2026-10-16 (b): 2 つ目**\n- b の続き\n"
	if got := read(t, root, "NOTES.md"); got != want {
		t.Fatalf("NOTES.md:\n%s", got)
	}
}

func TestMovesByMonthAndDropsSeparator(t *testing.T) {
	root := setup(t, nil)
	_, out := run(t, root)
	oct := read(t, root, "notes/2026-10.md")
	if oct != "# NOTES 2026-10\n\n**2026-10-02 (a): 1 つ目**\n- a の続き\n" {
		t.Fatalf("2026-10:\n%s", oct)
	}
	aug := read(t, root, "notes/2026-08.md")
	if !strings.Contains(aug, "## 2026-08-17 — 古い項\n本文") {
		t.Fatalf("2026-08:\n%s", aug)
	}
	if !strings.Contains(out, "区切りの見出しを落とす: # NOTES") {
		t.Fatalf("out:\n%s", out)
	}
}

func TestPrependsBeforeExistingArchive(t *testing.T) {
	root := setup(t, map[string]string{"notes/2026-10.md": "# NOTES 2026-10\n\n**2026-10-01 (z): もっと古い**\n"})
	run(t, root)
	oct := read(t, root, "notes/2026-10.md")
	a := strings.Index(oct, "2026-10-02")
	z := strings.Index(oct, "2026-10-01")
	if a < 0 || z < 0 || a > z {
		t.Fatalf("新しい順になっていない:\n%s", oct)
	}
}

func TestMaxLinesKeepsAtLeastOne(t *testing.T) {
	root := setup(t, nil)
	if err := os.WriteFile(filepath.Join(root, RulesPath),
		[]byte(strings.Replace(rulesJSON, `"maxLines": 100`, `"maxLines": 1`, 1)), 0o644); err != nil {
		t.Fatal(err)
	}
	run(t, root)
	got := read(t, root, "NOTES.md")
	if !strings.Contains(got, "2026-10-17") || strings.Contains(got, "2026-10-16") {
		t.Fatalf("NOTES.md:\n%s", got)
	}
}

func TestCheckDoesNotWrite(t *testing.T) {
	root := setup(t, nil)
	code, out := run(t, root, "--check")
	if code != 1 || !strings.Contains(out, "bin/fge notes-rotate") {
		t.Fatalf("code %d out %s", code, out)
	}
	if read(t, root, "NOTES.md") != notes {
		t.Fatal("--check が書き換えた")
	}
	if _, err := os.Stat(filepath.Join(root, "notes")); !os.IsNotExist(err) {
		t.Fatal("--check が notes/ を作った")
	}
}

func TestUnderLimitIsOK(t *testing.T) {
	root := setup(t, nil)
	run(t, root)
	if code, _ := run(t, root, "--check"); code != 0 {
		t.Fatalf("送った後の --check が %d", code)
	}
}

func TestShippedRulesLoad(t *testing.T) {
	if _, err := LoadRules(filepath.Join("..", "..", "..")); err != nil {
		t.Fatal(err)
	}
}
