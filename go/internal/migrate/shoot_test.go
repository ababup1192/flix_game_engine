package migrate

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestParseShootArgsTakesNameThenFlows(t *testing.T) {
	a, err := parseShootArgs([]string{"new", "--jobs", "2", "e2e/a.flow", "e2e/b.flow", "--run", "x"})
	if err != nil || a.name != "new" || len(a.flows) != 2 || a.jobs != 2 || a.run != "x" {
		t.Fatalf("got %+v %v", a, err)
	}
}

func TestParseShootArgsRefusesSameFlowName(t *testing.T) {
	if _, err := parseShootArgs([]string{"new", "--run", "x", "e2e/a.flow", "other/a.flow"}); err == nil {
		t.Fatal("同じ名前の flow を通した")
	}
}

func TestParseShootArgsRefusesPathAsName(t *testing.T) {
	if _, err := parseShootArgs([]string{"../x", "--run", "x", "e2e/a.flow"}); err == nil {
		t.Fatal("フォルダの区切りのある名前を通した")
	}
}

func TestParseShootArgsNeedsAFlow(t *testing.T) {
	if _, err := parseShootArgs([]string{"new", "--run", "x"}); err == nil {
		t.Fatal("flow の無い呼び出しを通した")
	}
}

func TestAutoJobsStaysInRange(t *testing.T) {
	if n := autoJobs(); n < 1 || n > shootMaxJobs {
		t.Fatalf("autoJobs = %d", n)
	}
}

func TestShootJavaOptsCapsTheHeap(t *testing.T) {
	if got := shootJavaOpts("-Xss64m"); got != "-Xss64m "+shootHeap {
		t.Fatalf("got %q", got)
	}
}

func TestShootJavaOptsKeepsTheCallersHeap(t *testing.T) {
	if got := shootJavaOpts("-Xmx8g"); got != "-Xmx8g" {
		t.Fatalf("got %q", got)
	}
}

func TestMemoryNoteSpeaksWhenJobsOutgrowMemory(t *testing.T) {
	if memoryNote(6, 8<<30) == "" {
		t.Fatal("6 本 × 3 GB を 8 GB の機械で黙った")
	}
}

func TestMemoryNoteIsQuietWithRoom(t *testing.T) {
	if note := memoryNote(3, 64<<30); note != "" {
		t.Fatal(note)
	}
}

func TestCacheNoteSpeaksWhenTheCapIsTooSmall(t *testing.T) {
	root := t.TempDir()
	writeTapeFrames(t, root, "a", 100)
	if cacheNote(root, t.TempDir(), 10<<20, func(string) int64 { return 1 << 40 }) == "" {
		t.Fatal("100 枚 × 2 を 10 MB の上限で黙った")
	}
}

func TestCacheNoteSpeaksWhenTheDiskIsTooSmall(t *testing.T) {
	root := t.TempDir()
	writeTapeFrames(t, root, "a", 100)
	if cacheNote(root, t.TempDir(), 1<<40, func(string) int64 { return 1 << 20 }) == "" {
		t.Fatal("ディスクの空き 1 MB で黙った")
	}
}

func TestCacheNoteIsQuietWithRoom(t *testing.T) {
	root := t.TempDir()
	writeTapeFrames(t, root, "a", 100)
	if note := cacheNote(root, t.TempDir(), 1<<40, func(string) int64 { return 1 << 40 }); note != "" {
		t.Fatal(note)
	}
}

// writeTapeFrames は root/flows/<flow>/tape.json に world のコマ n 枚の記録を書く。
func writeTapeFrames(t *testing.T, root, flow string, n int) {
	t.Helper()
	var frames []Frame
	for i := 0; i < n; i++ {
		frames = append(frames, Frame{File: fmt.Sprintf("frames/world/f%04d.png", i), T: float64(i), Node: "N", Seq: i, Kind: "lineDone", Layer: "world"})
	}
	data, _ := json.Marshal(map[string]any{"frames": frames})
	dir := filepath.Join(root, FlowsDir, flow)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, TapeFile), data, 0o644); err != nil {
		t.Fatal(err)
	}
}
