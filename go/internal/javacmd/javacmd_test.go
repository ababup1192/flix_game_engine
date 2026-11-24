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

// java -version が通るのは、在るファイルだけとする（PATH の java は通らない＝macOS の /usr/bin/java の入口）。
func withBrokenPathJava(t *testing.T) {
	t.Setenv("JAVA", "")
	withJavaWorks(t, func(c string) bool {
		_, err := os.Stat(c)
		return c != "java" && err == nil
	})
}

func mustResolve(t *testing.T, engine string) string {
	t.Helper()
	got, err := Resolve(engine)
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func withJavaWorks(t *testing.T, f func(string) bool) {
	old := javaWorks
	javaWorks = f
	t.Cleanup(func() { javaWorks = old })
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

// JAVA で名指した java が通れば、何より先に使う。
func TestResolvePrefersJavaEnv(t *testing.T) {
	t.Setenv("JAVA", "/opt/jdk/bin/java")
	withJavaWorks(t, func(string) bool { return true })
	if got := mustResolve(t, t.TempDir()); got != "/opt/jdk/bin/java" {
		t.Errorf("got %q", got)
	}
}

// PATH の java が動けば、PATH の java。
func TestResolveUsesWorkingPathJava(t *testing.T) {
	t.Setenv("JAVA", "")
	withJavaWorks(t, func(string) bool { return true })
	root := t.TempDir()
	write(t, devboxJava(root), "")
	if got := mustResolve(t, root); got != "java" {
		t.Errorf("got %q", got)
	}
}

// JAVA の java が -version で通らなければ、次（engine の devbox の jdk）へ進む。
func TestResolveSkipsBrokenJavaEnv(t *testing.T) {
	withBrokenPathJava(t)
	t.Setenv("JAVA", "/nowhere/bin/java")
	root := t.TempDir()
	write(t, devboxJava(root), "")
	if got := mustResolve(t, root); got != devboxJava(root) {
		t.Errorf("got %q", got)
	}
}

// PATH の java が動かなければ、engine の devbox の jdk。
func TestResolveFallsBackToEngineDevbox(t *testing.T) {
	withBrokenPathJava(t)
	root := t.TempDir()
	write(t, devboxJava(root), "")
	if got := mustResolve(t, root); got != devboxJava(root) {
		t.Errorf("got %q", got)
	}
}

// worktree に .devbox が無く devbox.json が main の checkout と同じなら、main の checkout の jdk。
func TestResolveBorrowsMainCheckoutDevboxFromWorktree(t *testing.T) {
	withBrokenPathJava(t)
	main, wt := mainAndWorktree(t, `{"packages":["jdk@25"]}`, `{"packages":["jdk@25"]}`)
	if got := mustResolve(t, wt); got != devboxJava(main) {
		t.Errorf("got %q", got)
	}
}

// worktree の devbox.json が main の checkout と違えば（jdk の版を替えた枝）、main の jdk を借りず、見つからない誤り。
func TestResolveDoesNotBorrowWhenDevboxJSONDiffers(t *testing.T) {
	withBrokenPathJava(t)
	_, wt := mainAndWorktree(t, `{"packages":["jdk@25"]}`, `{"packages":["jdk@26"]}`)
	if got, err := Resolve(wt); err == nil {
		t.Errorf("誤りになりません: %q", got)
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

// commondir の相対パスを gitdir から辿って main の checkout のルートを出す。
func TestMainCheckoutFollowsCommonDir(t *testing.T) {
	main, wt := mainAndWorktree(t, "{}", "{}")
	if got := MainCheckout(wt); got != main {
		t.Errorf("got %q（%q のはず）", got, main)
	}
}
