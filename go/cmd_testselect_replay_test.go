package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// replayRepo は C^（src/a.flix=1・test/T.flix=x）と C（a=2・T=y・src/new.flix を足す）を持つ git のリポ。作業の木の gates.json は今の物（now）。
func replayRepo(t *testing.T) (dir, c string) {
	t.Helper()
	dir = t.TempDir()
	run := func(args ...string) string {
		t.Helper()
		// WhyNot: 利用者の core.hooksPath を通さない — 一時のリポのコミットで engine のフックが走る。
		cmd := exec.Command("git", append([]string{"-c", "core.hooksPath=/dev/null"}, args...)...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com")
		b, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v %s", args, err, b)
		}
		return strings.TrimSpace(string(b))
	}
	write := func(p, s string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, p)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, p), []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	run("init", "-q")
	write("src/a.flix", "1\n")
	write("test/T.flix", "x\n")
	write("gates.json", "old\n")
	run("add", "-A")
	run("commit", "-q", "-m", "parent")
	write("src/a.flix", "2\n")
	write("test/T.flix", "y\n")
	write("src/new.flix", "n\n")
	run("add", "-A")
	run("commit", "-q", "-m", "change")
	write("gates.json", "now\n")
	return dir, run("rev-parse", "HEAD")
}

func show(dir, rev, p string) string {
	out, err := gitLine(dir, "show", rev+":"+p)
	if err != nil {
		return "(無い)"
	}
	return out
}

func blobOf(t *testing.T, dir string) string {
	t.Helper()
	b, err := gitLine(dir, "hash-object", "-w", "gates.json")
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// red: target は C のテストのまま src だけを C^ に戻した木（足した src は消える）。
func TestReplayTreesRevertKeepsTestsAndRevertsSrc(t *testing.T) {
	dir, c := replayRepo(t)
	_, target, reverted, err := replayTrees(dir, blobOf(t, dir), c)
	if err != nil {
		t.Fatal(err)
	}
	got := []string{show(dir, target, "src/a.flix"), show(dir, target, "test/T.flix"), show(dir, target, "src/new.flix"), strings.Join(reverted, ",")}
	if strings.Join(got, "|") != "1|y|(無い)|src/a.flix,src/new.flix" {
		t.Errorf("got %v", got)
	}
}

// base は target の祖先（merge-base が base になり、--since base の差分が空にならない）。
func TestReplayTreesBaseIsAncestorOfTarget(t *testing.T) {
	dir, c := replayRepo(t)
	base, target, _, err := replayTrees(dir, blobOf(t, dir), c)
	if err != nil {
		t.Fatal(err)
	}
	if mb, _ := gitLine(dir, "merge-base", base, target); mb != base {
		t.Errorf("merge-base %s base %s", mb, base)
	}
}

// どちらの木にも今の gates.json を重ねる。
func TestReplayTreesOverlayCurrentGates(t *testing.T) {
	dir, c := replayRepo(t)
	base, target, _, err := replayTrees(dir, blobOf(t, dir), c)
	if err != nil {
		t.Fatal(err)
	}
	if show(dir, base, "gates.json") != "now" || show(dir, target, "gates.json") != "now" {
		t.Errorf("gates %q %q", show(dir, base, "gates.json"), show(dir, target, "gates.json"))
	}
}

// 鍵は生きている持ち主がいる間は取れない。
func TestReplayLockRefusesWhileHeld(t *testing.T) {
	path := filepath.Join(t.TempDir(), "replay.lock")
	unlock, err := takeReplayLock(path)
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	if _, err := takeReplayLock(path); err == nil {
		t.Error("2 本目が鍵を取れた")
	}
}

// 持ち主のいない鍵（終わった pid）は取り直せる。
func TestReplayLockTakesOverStaleLock(t *testing.T) {
	path := filepath.Join(t.TempDir(), "replay.lock")
	cmd := exec.Command("true")
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(strconv.Itoa(cmd.Process.Pid)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	unlock, err := takeReplayLock(path)
	if err != nil {
		t.Fatal(err)
	}
	unlock()
}

// --range と --commits はどちらか 1 つ・red でない mode と知らない口は断る。
func TestParseReplayArgsRejects(t *testing.T) {
	for _, args := range [][]string{{}, {"--range", "a..b", "--commits", "x"}, {"--commits", "x", "--mode", "inject"}, {"--commits", "x", "--sample", "3"}} {
		if _, err := parseReplayArgs(args); err == nil {
			t.Errorf("%v を通した", args)
		}
	}
}
