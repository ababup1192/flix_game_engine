package reference

// What: update が作る SHA256SUMS.txt と ITEMS.tsv の形（shasum -a 256 と同じ・名前はバイト順・gallery の名前だけ）、
// check が増えた絵・消えた絵・中身の違う絵を落とし、一致すれば絵の値段の判定まで流すこと、BUDGET=accept の扱い。

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func put(t *testing.T, dir, rel, body string) {
	t.Helper()
	p := filepath.Join(dir, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func get(t *testing.T, dir, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(rel)))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func hashOf(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

type fakeFge struct {
	calls []string
	fail  bool
}

func deps(f *fakeFge) (Deps, *strings.Builder) {
	out := &strings.Builder{}
	return Deps{
		Out: out, Err: out,
		Fge: func(dir string, args ...string) error {
			f.calls = append(f.calls, strings.Join(args, " "))
			if f.fail {
				return errors.New("赤")
			}
			return nil
		},
		Getenv: func(string) string { return "" },
	}, out
}

func TestUpdateWritesShasumFormatInByteOrder(t *testing.T) {
	dir := t.TempDir()
	put(t, dir, "gallery/b.png", "B")
	put(t, dir, "gallery/A.png", "A")
	put(t, dir, "gallery/b.items.tsv", "x")
	put(t, dir, "reference/title.png", "T")
	d, _ := deps(&fakeFge{})
	if code := Update(dir, false, d); code != 0 {
		t.Fatalf("code=%d", code)
	}
	want := hashOf("A") + "  A.png\n" + hashOf("B") + "  b.png\n"
	if got := get(t, dir, "reference/SHA256SUMS.txt"); got != want {
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestUpdateWritesItemsFromTheRecords(t *testing.T) {
	dir := t.TempDir()
	put(t, dir, "gallery/main.png", "M")
	put(t, dir, "gallery/main.items.tsv", "scene=main\ttotal=120\n")
	put(t, dir, "gallery/main.static.tsv", "static=20\n")
	put(t, dir, "gallery/quit.png", "Q")
	put(t, dir, "gallery/old.items.tsv", "total=5\n")
	d, _ := deps(&fakeFge{})
	Update(dir, false, d)
	if got := get(t, dir, "reference/ITEMS.tsv"); got != "main\tdynamic=100\tstatic=20\n" {
		t.Errorf("got %q", got)
	}
}

func TestUpdateJudgesTheBudgetBeforeCopying(t *testing.T) {
	dir := t.TempDir()
	put(t, dir, "gallery/main.png", "M")
	f := &fakeFge{fail: true}
	d, _ := deps(f)
	if code := Update(dir, false, d); code == 0 {
		t.Error("値段が赤なのに通しています")
	}
	if _, err := os.Stat(filepath.Join(dir, "reference/main.png")); err == nil {
		t.Error("値段が赤なのに絵を写しています")
	}
}

func TestBudgetAcceptSkipsTheGate(t *testing.T) {
	dir := t.TempDir()
	put(t, dir, "gallery/main.png", "M")
	f := &fakeFge{fail: true}
	d, _ := deps(f)
	if code := Run(dir, []string{"update", "BUDGET=accept"}, d); code != 0 || len(f.calls) != 0 {
		t.Errorf("code=%d calls=%v", code, f.calls)
	}
}

func TestUpdateWithoutGalleryFails(t *testing.T) {
	d, _ := deps(&fakeFge{})
	if Update(t.TempDir(), false, d) == 0 {
		t.Error("gallery が無いのに通しています")
	}
}

func checked(t *testing.T, gallery map[string]string, sums string) (int, string, *fakeFge) {
	t.Helper()
	dir := t.TempDir()
	for n, b := range gallery {
		put(t, dir, "gallery/"+n, b)
	}
	put(t, dir, "reference/SHA256SUMS.txt", sums)
	f := &fakeFge{}
	d, out := deps(f)
	code := Check(dir, d)
	return code, out.String(), f
}

func TestCheckPassesAndThenJudgesTheBudget(t *testing.T) {
	code, out, f := checked(t, map[string]string{"a.png": "A"}, hashOf("A")+"  a.png\n")
	if code != 0 || !strings.Contains(out, "reference-check OK: 1 枚") {
		t.Fatalf("code=%d out=%s", code, out)
	}
	if strings.Join(f.calls, ";") != "render-cache prune --quiet;check-render-budget ." {
		t.Errorf("calls=%v", f.calls)
	}
}

func TestCheckReadsCRLFSums(t *testing.T) {
	code, out, _ := checked(t, map[string]string{"a.png": "A"}, hashOf("A")+"  a.png\r\n")
	if code != 0 {
		t.Errorf("code=%d out=%s", code, out)
	}
}

func TestCheckFailsOnAnAddedPicture(t *testing.T) {
	code, out, _ := checked(t, map[string]string{"a.png": "A", "b.png": "B"}, hashOf("A")+"  a.png\n")
	if code == 0 || !strings.Contains(out, "増えた: b.png") {
		t.Errorf("code=%d out=%s", code, out)
	}
}

func TestCheckFailsOnARemovedPicture(t *testing.T) {
	code, out, _ := checked(t, map[string]string{"a.png": "A"}, hashOf("A")+"  a.png\n"+hashOf("B")+"  b.png\n")
	if code == 0 || !strings.Contains(out, "消えた: b.png") {
		t.Errorf("code=%d out=%s", code, out)
	}
}

func TestCheckFailsOnAChangedPicture(t *testing.T) {
	code, out, f := checked(t, map[string]string{"a.png": "A2"}, hashOf("A")+"  a.png\n")
	if code == 0 || !strings.Contains(out, "a.png: FAILED") || len(f.calls) != 0 {
		t.Errorf("code=%d out=%s calls=%v", code, out, f.calls)
	}
}

func TestCheckWithoutSumsTellsHowToMakeThem(t *testing.T) {
	dir := t.TempDir()
	d, out := deps(&fakeFge{})
	if Check(dir, d) == 0 || !strings.Contains(out.String(), "reference-update") {
		t.Errorf("out=%s", out.String())
	}
}
