package javacmd

import (
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}

func devboxJava(root string) string {
	return filepath.Join(root, ".devbox", "nix", "profile", "default", "bin", exe())
}

// PATH の java が -version で通らない時（macOS の /usr/bin/java の入口）とする。
func withBrokenPathJava(t *testing.T) {
	t.Setenv("JAVA", "")
	old := pathJavaWorks
	pathJavaWorks = func() bool { return false }
	t.Cleanup(func() { pathJavaWorks = old })
}

// main の checkout（.git のフォルダ・devbox の jdk）と、その worktree（.git のファイル・.devbox 無し）を作る。
func mainAndWorktree(t *testing.T, mainDevbox, worktreeDevbox string) (string, string) {
	base := t.TempDir()
	main := filepath.Join(base, "engine")
	wt := filepath.Join(main, ".claude", "worktrees", "a")
	gitdir := filepath.Join(main, ".git", "worktrees", "a")
	write(t, filepath.Join(gitdir, "commondir"), "../..\n")
	write(t, filepath.Join(wt, ".git"), "gitdir: "+gitdir+"\n")
	write(t, devboxJava(main), "")
	write(t, filepath.Join(main, "devbox.json"), mainDevbox)
	write(t, filepath.Join(wt, "devbox.json"), worktreeDevbox)
	return main, wt
}

// JAVA で名指した java を何より先に使う。
func TestResolvePrefersJavaEnv(t *testing.T) {
	t.Setenv("JAVA", "/opt/jdk/bin/java")
	if got := Resolve(t.TempDir()); got != "/opt/jdk/bin/java" {
		t.Errorf("got %q", got)
	}
}

// PATH の java が動けば、PATH の java。
func TestResolveUsesWorkingPathJava(t *testing.T) {
	t.Setenv("JAVA", "")
	old := pathJavaWorks
	pathJavaWorks = func() bool { return true }
	t.Cleanup(func() { pathJavaWorks = old })
	root := t.TempDir()
	write(t, devboxJava(root), "")
	if got := Resolve(root); got != "java" {
		t.Errorf("got %q", got)
	}
}

// PATH の java が動かなければ、engine の devbox の jdk。
func TestResolveFallsBackToEngineDevbox(t *testing.T) {
	withBrokenPathJava(t)
	root := t.TempDir()
	write(t, devboxJava(root), "")
	if got := Resolve(root); got != devboxJava(root) {
		t.Errorf("got %q", got)
	}
}

// worktree に .devbox が無く devbox.json が main の checkout と同じなら、main の checkout の jdk。
func TestResolveBorrowsMainCheckoutDevboxFromWorktree(t *testing.T) {
	withBrokenPathJava(t)
	main, wt := mainAndWorktree(t, `{"packages":["jdk@25"]}`, `{"packages":["jdk@25"]}`)
	if got := Resolve(wt); got != devboxJava(main) {
		t.Errorf("got %q", got)
	}
}

// worktree の devbox.json が main の checkout と違えば（jdk の版を替えた枝）、main の jdk を借りない。
func TestResolveDoesNotBorrowWhenDevboxJSONDiffers(t *testing.T) {
	withBrokenPathJava(t)
	_, wt := mainAndWorktree(t, `{"packages":["jdk@25"]}`, `{"packages":["jdk@26"]}`)
	if got := Resolve(wt); got != "java" {
		t.Errorf("got %q", got)
	}
}

// .git がフォルダ（main の checkout そのもの）なら、main の checkout は無い。
func TestMainCheckoutEmptyForMainItself(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := MainCheckout(root); got != "" {
		t.Errorf("got %q", got)
	}
}

// commondir の相対パスを gitdir から辿って main の checkout の根を出す。
func TestMainCheckoutFollowsCommonDir(t *testing.T) {
	main, wt := mainAndWorktree(t, "{}", "{}")
	if got := MainCheckout(wt); got != main {
		t.Errorf("got %q（%q のはず）", got, main)
	}
}
