package exereplace

// What: Windows では今の exe を .old に退けてから置く・他の OS は退けない・.old は次の起動で消える・
// 前の .old が残っていても置ける。

import (
	"os"
	"path/filepath"
	"testing"
)

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestWindowsMovesTheRunningExeAsideBeforePlacingTheNewOne(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "fge-go.exe")
	writeFile(t, dest, "old")
	if err := Write(dest, []byte("new"), "windows"); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, dest+OldSuffix); got != "old" {
		t.Errorf(".old に前の中身がありません: %q", got)
	}
	if got := readFile(t, dest); got != "new" {
		t.Errorf("新しい中身を置いていません: %q", got)
	}
}

func TestOtherOSLeavesNoOldFile(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "fge-go")
	writeFile(t, dest, "old")
	if err := Write(dest, []byte("new"), "linux"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dest + OldSuffix); err == nil {
		t.Error("Windows でないのに .old を残しています")
	}
	if info, err := os.Stat(dest); err != nil || info.Mode().Perm()&0o100 == 0 {
		t.Errorf("実行ビットがありません: %v", err)
	}
}

func TestWindowsPlacesEvenWhenAnOldFileIsLeft(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "fge-go.exe")
	writeFile(t, dest, "second")
	writeFile(t, dest+OldSuffix, "first")
	if err := Write(dest, []byte("third"), "windows"); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, dest); got != "third" {
		t.Errorf("置けていません: %q", got)
	}
}

func TestRemoveOldDeletesMovedAsideFilesOnWindowsOnly(t *testing.T) {
	dir := t.TempDir()
	exe := filepath.Join(dir, "fge-go.exe")
	writeFile(t, exe, "now")
	writeFile(t, exe+".old", "a")
	writeFile(t, exe+".old2", "b")
	writeFile(t, exe+".older", "keep")
	RemoveOld(exe, "linux")
	if _, err := os.Stat(exe + ".old"); err != nil {
		t.Fatal("Windows でないのに消しています")
	}
	RemoveOld(exe, "windows")
	for _, gone := range []string{".old", ".old2"} {
		if _, err := os.Stat(exe + gone); err == nil {
			t.Errorf("%s が残っています", gone)
		}
	}
	for _, kept := range []string{"", ".older"} {
		if _, err := os.Stat(exe + kept); err != nil {
			t.Errorf("%q まで消しています", kept)
		}
	}
}
