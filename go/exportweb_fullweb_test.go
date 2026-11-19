package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// devEngine は exportWebFixture の engine を作業コピー（go/ と VERSION の行のある Makefile）にし、置き場の current を entry へ向ける。
func devEngine(t *testing.T, eng, version, entry string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(eng, "go"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(eng, "Makefile"), []byte("VERSION := "+version+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if entry == "" {
		return
	}
	if err := os.MkdirAll(filepath.Join(eng, "build/fpkg-store/current"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../"+entry, filepath.Join(eng, "build/fpkg-store/current/engine_full_web")); err != nil {
		t.Fatal(err)
	}
}

// fakeSync は syncFullWeb を差し替え、呼ばれた回数を数える。after は呼ばれた時に置き場へする事。
func fakeSync(t *testing.T, after func(engine string)) *int {
	t.Helper()
	calls := 0
	orig := syncFullWeb
	syncFullWeb = func(engine string) error {
		calls++
		if after != nil {
			after(engine)
		}
		return nil
	}
	t.Cleanup(func() { syncFullWeb = orig })
	return &calls
}

func TestFullWebFreshRunsNoSyncWhenTheEntryMatches(t *testing.T) {
	game, eng := exportWebFixture(t)
	devEngine(t, eng, "0.9.0", "engine_full_web-0.9.0-0123456789abcdef")
	calls := fakeSync(t, nil)
	if _, code, err := resolveExportWebPaths(exportWebOptions{Game: game, Engine: eng}); err != nil || code != 0 || *calls != 0 {
		t.Errorf("code=%d err=%v sync=%d", code, err, *calls)
	}
}

func TestFullWebFreshSyncsWhenTheEntryIsAnOlderVersion(t *testing.T) {
	game, eng := exportWebFixture(t)
	old := "build/fpkg-store/engine_full_web-0.8.0-0123456789abcdef"
	if err := os.MkdirAll(filepath.Join(eng, old), 0o755); err != nil {
		t.Fatal(err)
	}
	devEngine(t, eng, "0.9.0", "engine_full_web-0.8.0-0123456789abcdef")
	calls := fakeSync(t, func(engine string) {
		link := filepath.Join(engine, "build/fpkg-store/current/engine_full_web")
		os.Remove(link)
		if err := os.Symlink("../engine_full_web-0.9.0-0123456789abcdef", link); err != nil {
			t.Fatal(err)
		}
	})
	_, code, err := resolveExportWebPaths(exportWebOptions{Game: game, Engine: eng})
	if err != nil || code != 0 || *calls != 1 {
		t.Errorf("code=%d err=%v sync=%d", code, err, *calls)
	}
}

func TestFullWebFreshStopsWhenTheSyncLeavesItStale(t *testing.T) {
	game, eng := exportWebFixture(t)
	devEngine(t, eng, "0.9.0", "")
	fakeSync(t, nil)
	if _, code, err := resolveExportWebPaths(exportWebOptions{Game: game, Engine: eng}); code != 1 || err == nil || !strings.Contains(err.Error(), "後も") {
		t.Errorf("code=%d err=%v", code, err)
	}
}

func TestFullWebFreshReportsAFailedSync(t *testing.T) {
	game, eng := exportWebFixture(t)
	devEngine(t, eng, "0.9.0", "")
	orig := syncFullWeb
	syncFullWeb = func(string) error { return errors.New("exit status 2") }
	t.Cleanup(func() { syncFullWeb = orig })
	if _, code, err := resolveExportWebPaths(exportWebOptions{Game: game, Engine: eng}); code != 1 || err == nil || !strings.Contains(err.Error(), "sync-engine-full-web が通らない") {
		t.Errorf("code=%d err=%v", code, err)
	}
}

func TestFullWebFreshStopsOnAGameOfAnotherVersion(t *testing.T) {
	game, eng := exportWebFixture(t)
	devEngine(t, eng, "0.10.0", "engine_full_web-0.9.0-0123456789abcdef")
	calls := fakeSync(t, nil)
	_, code, err := resolveExportWebPaths(exportWebOptions{Game: game, Engine: eng})
	if code != 2 || err == nil || !strings.Contains(err.Error(), "make engine-upgrade") || *calls != 0 {
		t.Errorf("code=%d err=%v sync=%d", code, err, *calls)
	}
}

// 配った版（go/ が無い）は組み直さず、前のとおり足りない物を言って止まる。
func TestFullWebFreshLeavesABundleAlone(t *testing.T) {
	game, eng := exportWebFixture(t)
	calls := fakeSync(t, nil)
	if _, code, _ := resolveExportWebPaths(exportWebOptions{Game: game, Engine: eng}); code != 2 || *calls != 0 {
		t.Errorf("code=%d sync=%d", code, *calls)
	}
}
