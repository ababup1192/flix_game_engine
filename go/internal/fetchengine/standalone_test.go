package fetchengine

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
)

// 単体の zip には Studio のラッパでなくリポと同じ bin/flix が入っている。
func standaloneZip(t *testing.T) []byte {
	t.Helper()
	return makeZipOf(t, map[string]zipEntry{
		"bin/lint-rules/stage-engine.json": {body: stageRules, mode: 0o644},
		"bin/flix":                         {body: "#!/bin/sh\nexec java -jar bin/flix.jar \"$@\"\n", mode: 0o755},
		toolName:                           {body: "tool", mode: 0o755},
		"Makefile":                         {body: "VERSION := 0.32.0\n", mode: 0o644},
	})
}

func standaloneOpts(t *testing.T, pages map[string][]byte) *opts {
	t.Helper()
	o := newOpts(t, pages)
	o.standalone = true
	t.Cleanup(func() { _ = fgehome.RemoveReadOnly(o.into) })
	return o
}

func TestStandaloneInstallsWithoutCarryingFromStudio(t *testing.T) {
	o := standaloneOpts(t, pagesFor(t, standaloneZip(t)))

	res, err := install(o)
	if err != nil {
		t.Fatalf("入れられませんでした: %v", err)
	}
	body, err := os.ReadFile(filepath.Join(res.Dir, "bin", "flix"))
	if err != nil || !strings.Contains(string(body), "flix.jar") {
		t.Fatalf("zip の bin/flix がそのまま置かれていない: %q %v", body, err)
	}
}

func TestStandaloneMarksTheEngineCompleteAndReadOnly(t *testing.T) {
	o := standaloneOpts(t, pagesFor(t, standaloneZip(t)))

	res, err := install(o)
	if err != nil {
		t.Fatalf("入れられませんでした: %v", err)
	}
	if !fgehome.IsComplete(res.Dir) {
		t.Fatal(".complete が無い")
	}
	info, err := os.Stat(filepath.Join(res.Dir, "Makefile"))
	if err != nil || info.Mode().Perm()&0o222 != 0 {
		t.Fatalf("読み取り専用になっていない: %v %v", info, err)
	}
}

func TestStandaloneLeavesNoStagingBehind(t *testing.T) {
	o := standaloneOpts(t, pagesFor(t, standaloneZip(t)))

	if _, err := install(o); err != nil {
		t.Fatalf("入れられませんでした: %v", err)
	}
	entries, _ := os.ReadDir(o.into)
	if len(entries) != 1 || entries[0].Name() != "0.32.0" {
		t.Fatalf("途中の場所が残っている: %v", entries)
	}
}

func TestStandaloneDoesNothingWhenTheVersionIsComplete(t *testing.T) {
	o := standaloneOpts(t, map[string][]byte{})
	dest := filepath.Join(o.into, "0.32.0")
	if err := os.MkdirAll(dest, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, fgehome.CompleteMarker), nil, 0o644); err != nil {
		t.Fatal(err)
	}

	res, err := install(o)
	if err != nil || !res.AlreadyThere || res.Dir != dest {
		t.Fatalf("網に出ずに済ませていない: %+v %v", res, err)
	}
}

func TestStandaloneReplacesAHalfDoneVersionFolder(t *testing.T) {
	o := standaloneOpts(t, pagesFor(t, standaloneZip(t)))
	dest := filepath.Join(o.into, "0.32.0")
	if err := os.MkdirAll(dest, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, "left-over"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	res, err := install(o)
	if err != nil {
		t.Fatalf("入れられませんでした: %v", err)
	}
	if _, err := os.Stat(filepath.Join(res.Dir, "left-over")); !os.IsNotExist(err) {
		t.Fatalf("半端な物が残っている: %v", err)
	}
}

func TestStandaloneKeepsAHalfDoneFolderWhenTheDownloadFails(t *testing.T) {
	pages := pagesFor(t, standaloneZip(t))
	pages["https://example.test/"+SumsName] = []byte(strings.Repeat("0", 64) + "  " + ZipName("0.32.0") + "\n")
	o := standaloneOpts(t, pages)
	dest := filepath.Join(o.into, "0.32.0")
	if err := os.MkdirAll(dest, 0o755); err != nil {
		t.Fatal(err)
	}

	if _, err := install(o); err == nil {
		t.Fatal("照合の合わない zip を受けた")
	}
	if _, err := os.Stat(dest); err != nil {
		t.Fatalf("落とせなかったのに今ある物を消した: %v", err)
	}
}

func TestStandaloneRefusesCarryFrom(t *testing.T) {
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, []string{"--standalone", "--version", "0.32.0", "--into", t.TempDir(), "--carry-from", t.TempDir()}, false)
	if err != nil || code != exitBadUsage {
		t.Fatalf("code=%d err=%v", code, err)
	}
}
