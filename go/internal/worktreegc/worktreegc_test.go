package worktreegc

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestParsePorcelainReadsBranchLockAndDetached(t *testing.T) {
	got := ParsePorcelain("worktree /r\nHEAD aaa\nbranch refs/heads/main\n\nworktree /r/w1\nHEAD bbb\ndetached\nlocked\n\nworktree /r/w2\nHEAD ccc\nbranch refs/heads/feat\nprunable gitdir file points to non-existent location\n")
	if len(got) != 3 || got[0].Branch != "main" || got[1].Branch != "" || !got[1].Locked || got[2].Branch != "feat" || !got[2].Prunable {
		t.Fatalf("読み違い: %+v", got)
	}
}

func run(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// 取り込み済みで変更の無い物だけが「消せる」に出て、--apply で消え、枝は残る。
func TestRunListsOnlyMergedCleanWorktreesAndApplyKeepsBranches(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git が無い")
	}
	root := t.TempDir()
	repo := filepath.Join(root, "repo")
	os.MkdirAll(repo, 0o755)
	run(t, repo, "init", "-q", "-b", "main")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("a"), 0o644)
	run(t, repo, "add", "a.txt")
	run(t, repo, "commit", "-q", "-m", "a")
	for _, n := range []string{"merged", "untracked", "ahead"} {
		run(t, repo, "worktree", "add", "-q", "-b", n, filepath.Join(root, n))
	}
	os.WriteFile(filepath.Join(root, "untracked", "new.txt"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(root, "ahead", "b.txt"), []byte("b"), 0o644)
	run(t, filepath.Join(root, "ahead"), "add", "b.txt")
	run(t, filepath.Join(root, "ahead"), "commit", "-q", "-m", "b")

	var out, errOut bytes.Buffer
	if code, err := Run(&out, &errOut, repo, []string{"--age", "0"}); code != 0 || err != nil {
		t.Fatalf("code=%d err=%v %s", code, err, errOut.String())
	}
	text := out.String()
	if !strings.Contains(text, "消せる") || !strings.Contains(text, filepath.Join(root, "merged")) ||
		strings.Contains(text, "消せる  "+filepath.Join(root, "untracked")) || strings.Count(text, "  消せる ") != 1 {
		t.Fatalf("一覧が違う:\n%s", text)
	}
	if _, err := os.Stat(filepath.Join(root, "merged")); err != nil {
		t.Fatalf("一覧だけで消えた")
	}
	out.Reset()
	if code, err := Run(&out, &errOut, repo, []string{"--age", "0", "--apply"}); code != 0 || err != nil {
		t.Fatalf("apply: code=%d err=%v %s", code, err, errOut.String())
	}
	if _, err := os.Stat(filepath.Join(root, "merged")); !os.IsNotExist(err) {
		t.Fatalf("消えていない")
	}
	for _, n := range []string{"untracked", "ahead"} {
		if _, err := os.Stat(filepath.Join(root, n)); err != nil {
			t.Fatalf("%s まで消えた", n)
		}
	}
	if b, _ := git(repo, "branch", "--list", "merged"); !strings.Contains(b, "merged") {
		t.Fatalf("枝が消えた")
	}
	if c, ok := ReadCache(filepath.Join(repo, ".git")); !ok || c.Total != 2 || c.Removable != 0 {
		t.Fatalf("結果の控えが違う: %+v %v", c, ok)
	}
}

// 作ったばかり（--age より新しい）の物は残す。
func TestRunKeepsRecentlyTouched(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git が無い")
	}
	root := t.TempDir()
	repo := filepath.Join(root, "repo")
	os.MkdirAll(repo, 0o755)
	run(t, repo, "init", "-q", "-b", "main")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("a"), 0o644)
	run(t, repo, "add", "a.txt")
	run(t, repo, "commit", "-q", "-m", "a")
	run(t, repo, "worktree", "add", "-q", "-b", "fresh", filepath.Join(root, "fresh"))
	var out, errOut bytes.Buffer
	Run(&out, &errOut, repo, nil)
	if strings.Contains(out.String(), "  消せる ") || !strings.Contains(out.String(), "最近触った 1") {
		t.Fatalf("作ったばかりの物を消せるに出した:\n%s", out.String())
	}
}
