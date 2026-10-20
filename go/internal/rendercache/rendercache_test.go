package rendercache

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func key(c byte) string {
	b := make([]byte, 64)
	for i := range b {
		b[i] = c
	}
	return string(b)
}

func put(t *testing.T, dir, name string, size int, age time.Duration) string {
	t.Helper()
	p := filepath.Join(dir, name[:2], name+".png")
	os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, make([]byte, size), 0o644); err != nil {
		t.Fatal(err)
	}
	when := time.Now().Add(-age)
	os.Chtimes(p, when, when)
	return p
}

func TestPruneRemovesLeastRecentlyUsedFirst(t *testing.T) {
	dir := t.TempDir()
	old := put(t, dir, key('a'), 100, 3*time.Hour)
	mid := put(t, dir, key('b'), 100, 2*time.Hour)
	recent := put(t, dir, key('c'), 100, time.Hour)
	removed, kept := Prune(dir, 150)
	_, errOld := os.Stat(old)
	_, errMid := os.Stat(mid)
	_, errNew := os.Stat(recent)
	if removed != 2 || kept != 100 || errOld == nil || errMid == nil || errNew != nil {
		t.Fatalf("removed=%d kept=%d old=%v mid=%v new=%v", removed, kept, errOld, errMid, errNew)
	}
}

func TestPruneKeepsAllUnderLimit(t *testing.T) {
	dir := t.TempDir()
	put(t, dir, key('a'), 100, time.Hour)
	if removed, _ := Prune(dir, 1000); removed != 0 {
		t.Fatalf("removed=%d", removed)
	}
}

func TestDirOffIsEmpty(t *testing.T) {
	t.Setenv("FGE_RENDER_CACHE", "off")
	if d := Dir(); d != "" {
		t.Fatalf("Dir()=%q", d)
	}
}

func TestPruneLeavesFilesThatAreNotStoredKeys(t *testing.T) {
	dir := t.TempDir()
	other := filepath.Join(dir, "gallery", "title.png")
	os.MkdirAll(filepath.Dir(other), 0o755)
	os.WriteFile(other, make([]byte, 100), 0o644)
	Prune(dir, 0)
	if _, err := os.Stat(other); err != nil {
		t.Fatalf("鍵の形でない PNG を消した: %v", err)
	}
}

func TestPruneCountsWrittenFilesAndMixedSound(t *testing.T) {
	dir := t.TempDir()
	stamp := filepath.Join(dir, "files", "aa", key('a')+".txt")
	mixed := filepath.Join(dir, "mix", "bb", key('b')+".wav")
	for _, p := range []string{stamp, mixed} {
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, make([]byte, 100), 0o644)
	}
	if removed, _ := Prune(dir, 0); removed != 2 {
		t.Fatalf("removed=%d（files/ と mix/ を数えていない）", removed)
	}
}

func TestDirRelativeIsEmpty(t *testing.T) {
	t.Setenv("FGE_RENDER_CACHE", "cache")
	if d := Dir(); d != "" {
		t.Fatalf("Dir()=%q", d)
	}
}
