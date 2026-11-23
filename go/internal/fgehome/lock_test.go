package fgehome

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type lockedBuilder struct {
	mu sync.Mutex
	b  strings.Builder
}

func (l *lockedBuilder) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuilder) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

func TestLockMakesASecondHolderWaitUntilTheFirstReleases(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".lock")
	unlock, err := Lock(path, nil)
	if err != nil {
		t.Fatal(err)
	}
	said := &lockedBuilder{}
	got := make(chan struct{})
	go func() {
		second, err := Lock(path, said)
		if err == nil {
			second()
		}
		close(got)
	}()
	select {
	case <-got:
		t.Fatal("2 つ目が 1 つ目の持っている間に取れた")
	case <-time.After(200 * time.Millisecond):
	}
	unlock()
	select {
	case <-got:
	case <-time.After(5 * time.Second):
		t.Fatal("1 つ目を外しても 2 つ目が取れない")
	}
	if !strings.Contains(said.String(), "待ちます") {
		t.Fatalf("待っている旨が出ていない: %q", said.String())
	}
}

func TestRemoveReadOnlyDeletesAReadOnlyTree(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "engine")
	if err := os.MkdirAll(filepath.Join(dir, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "bin", "fge"), []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := MakeReadOnly(dir); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(dir, "bin", "fge"))
	if err != nil || info.Mode().Perm()&0o222 != 0 {
		t.Fatalf("書き込みの権限が残っている: %v %v", info, err)
	}
	if err := RemoveReadOnly(dir); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("消えていない: %v", err)
	}
}
