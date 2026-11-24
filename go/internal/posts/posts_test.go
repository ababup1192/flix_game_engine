package posts

// 何を守るか: worktree の中で書いた post が main の作業ツリーの置き場へ入ること、素材の写し方（名前のぶつかり・
// リポの外と無い素材を止める）、返事の出し直しで前の返事を消さないこと、inbox が片付いた物と他の worktree の物を出さないこと。

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var now = time.Date(2026, 11, 24, 10, 15, 0, 0, time.Local)

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func git(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com"}, args...)...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// repoWithWorktree は main の作業ツリー（ゲームは根）と、枝 wt の worktree を作る。
func repoWithWorktree(t *testing.T) (string, string) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git がありません")
	}
	base := t.TempDir()
	main := filepath.Join(base, "game")
	write(t, filepath.Join(main, "flix.toml"), "[package]\n")
	git(t, main, "init", "-q", "-b", "main")
	git(t, main, "add", ".")
	git(t, main, "commit", "-q", "-m", "init")
	wt := filepath.Join(base, "wt")
	git(t, main, "worktree", "add", "-q", "-b", "wt", wt)
	return RealPath(main), RealPath(wt)
}

func create(t *testing.T, roots Roots, manifest string) string {
	t.Helper()
	id, err := Create(CreateOptions{PostsDir: roots.PostsDir(), Manifest: manifest, RepoRoot: roots.Worktree, Author: "claude",
		Origin: Origin{Branch: roots.Branch, Worktree: roots.Worktree}, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func TestResolveFromWorktreePointsAtMainPosts(t *testing.T) {
	main, wt := repoWithWorktree(t)
	if got := Resolve(filepath.Join(wt)).PostsDir(); got != filepath.Join(main, "debug", "dashboard", "posts") {
		t.Fatalf("置き場が main を指さない: %s", got)
	}
}

func TestResolveFromGameSubfolderKeepsGameRoot(t *testing.T) {
	main, _ := repoWithWorktree(t)
	write(t, filepath.Join(main, "src", "x.flix"), "")
	if got := Resolve(filepath.Join(main, "src")).MainRoot; got != main {
		t.Fatalf("src で打つと根がずれる: %s", got)
	}
}

func TestResolveKeepsTemplatePrefix(t *testing.T) {
	main, wt := repoWithWorktree(t)
	write(t, filepath.Join(wt, "templates", "x", "flix.toml"), "")
	write(t, filepath.Join(main, "templates", "x", "flix.toml"), "")
	if got := Resolve(filepath.Join(wt, "templates", "x")).MainRoot; got != filepath.Join(main, "templates", "x") {
		t.Fatalf("templates/x の prefix が落ちた: %s", got)
	}
}

func TestResolveOutsideGitUsesGameRoot(t *testing.T) {
	dir := RealPath(t.TempDir())
	write(t, filepath.Join(dir, "flix.toml"), "")
	if got := Resolve(dir).PostsDir(); got != filepath.Join(dir, "debug", "dashboard", "posts") {
		t.Fatal(got)
	}
}

func TestCreateCopiesMediaAndRewritesPaths(t *testing.T) {
	_, wt := repoWithWorktree(t)
	write(t, filepath.Join(wt, "shots", "a.png"), "A")
	write(t, filepath.Join(wt, "other", "a.png"), "B")
	write(t, filepath.Join(wt, "shots", "post.json"), `{"title": "t", "sections": [{"id": "A", "options": [
	  {"id": "A1", "media": ["a.png"]}, {"id": "A2", "media": ["`+filepath.ToSlash(filepath.Join(wt, "other", "a.png"))+`"]}]}]}`)
	roots := Resolve(wt)
	id := create(t, roots, filepath.Join(wt, "shots", "post.json"))
	got, _ := os.ReadFile(filepath.Join(roots.PostsDir(), id, "a-2.png"))
	if string(got) != "B" {
		t.Fatalf("ぶつかった名前の 2 つ目が a-2.png に入らない: %q", got)
	}
}

func TestCreateStopsOnMediaOutsideRepo(t *testing.T) {
	_, wt := repoWithWorktree(t)
	outside := filepath.Join(t.TempDir(), "x.png")
	write(t, outside, "X")
	write(t, filepath.Join(wt, "post.json"), `{"sections": [{"id": "A", "options": [{"id": "A1", "media": ["`+filepath.ToSlash(outside)+`"]}]}]}`)
	_, err := Create(CreateOptions{PostsDir: Resolve(wt).PostsDir(), Manifest: filepath.Join(wt, "post.json"), RepoRoot: wt, Now: now})
	if err == nil || !strings.Contains(err.Error(), "外") {
		t.Fatalf("リポの外の素材を止めない: %v", err)
	}
}

func TestCreateStopsOnMissingMedia(t *testing.T) {
	_, wt := repoWithWorktree(t)
	write(t, filepath.Join(wt, "post.json"), `{"sections": [{"id": "A", "options": [{"id": "A1", "media": ["none.png"]}]}]}`)
	_, err := Create(CreateOptions{PostsDir: Resolve(wt).PostsDir(), Manifest: filepath.Join(wt, "post.json"), RepoRoot: wt, Now: now})
	if err == nil || !strings.Contains(err.Error(), "none.png") {
		t.Fatalf("無い素材を止めない: %v", err)
	}
}

func TestCreateInSameSecondAddsSuffix(t *testing.T) {
	_, wt := repoWithWorktree(t)
	write(t, filepath.Join(wt, "post.json"), `{"title": "Glow test"}`)
	roots := Resolve(wt)
	create(t, roots, filepath.Join(wt, "post.json"))
	if id := create(t, roots, filepath.Join(wt, "post.json")); id != "20261124-101500-glow-test-2" {
		t.Fatal(id)
	}
}

func TestCreateWritesOrigin(t *testing.T) {
	_, wt := repoWithWorktree(t)
	write(t, filepath.Join(wt, "post.json"), `{"title": "t"}`)
	roots := Resolve(wt)
	p, _, err := Load(roots.PostsDir(), create(t, roots, filepath.Join(wt, "post.json")))
	if err != nil || p.Origin.Branch != "wt" || !SamePath(p.Origin.Worktree, wt) {
		t.Fatalf("origin が違う: %+v %v", p.Origin, err)
	}
}

func TestWriteReplyReopensResolvedPost(t *testing.T) {
	_, wt := repoWithWorktree(t)
	write(t, filepath.Join(wt, "post.json"), `{"title": "t"}`)
	roots := Resolve(wt)
	id := create(t, roots, filepath.Join(wt, "post.json"))
	MarkResolved(roots.PostsDir(), id, "")
	WriteReply(roots.PostsDir(), id, nil, "もう一度", now)
	if p, _, _ := Load(roots.PostsDir(), id); p.Resolved {
		t.Fatal("新しい返事の後も片付いたまま")
	}
}

func TestInboxSkipsResolvedPosts(t *testing.T) {
	_, wt := repoWithWorktree(t)
	write(t, filepath.Join(wt, "post.json"), `{"title": "t"}`)
	roots := Resolve(wt)
	id := create(t, roots, filepath.Join(wt, "post.json"))
	WriteReply(roots.PostsDir(), id, nil, "ok", now)
	MarkResolved(roots.PostsDir(), id, "")
	if got := Inbox(List(roots.PostsDir()), wt, false); len(got) != 0 {
		t.Fatalf("片付いた post が出た: %v", got)
	}
}

func TestInboxSkipsOtherWorktreePosts(t *testing.T) {
	main, wt := repoWithWorktree(t)
	write(t, filepath.Join(wt, "post.json"), `{"title": "t"}`)
	roots := Resolve(wt)
	id := create(t, roots, filepath.Join(wt, "post.json"))
	WriteReply(roots.PostsDir(), id, nil, "ok", now)
	if got := Inbox(List(roots.PostsDir()), main, false); len(got) != 0 {
		t.Fatalf("他の worktree の返事が出た: %v", got)
	}
}

func TestInboxAllShowsOtherWorktreePosts(t *testing.T) {
	main, wt := repoWithWorktree(t)
	write(t, filepath.Join(wt, "post.json"), `{"title": "t"}`)
	roots := Resolve(wt)
	id := create(t, roots, filepath.Join(wt, "post.json"))
	WriteReply(roots.PostsDir(), id, nil, "ok", now)
	if got := Inbox(List(roots.PostsDir()), main, true); len(got) != 1 {
		t.Fatalf("--all で出ない: %v", got)
	}
}

func TestWorktreesListsMainFirst(t *testing.T) {
	main, wt := repoWithWorktree(t)
	got := Worktrees(wt)
	if len(got) != 2 || got[0].Path != main || got[1].Branch != "wt" {
		t.Fatalf("%+v", got)
	}
}

func TestResolveFallsBackWhenMainLacksGame(t *testing.T) {
	_, wt := repoWithWorktree(t)
	write(t, filepath.Join(wt, "games", "new", "flix.toml"), "")
	r := Resolve(filepath.Join(wt, "games", "new"))
	if !r.MainMissing || r.MainRoot != filepath.Join(wt, "games", "new") {
		t.Fatalf("worktree の置き場へ戻らない: %+v", r)
	}
}

func TestResolveLeavesNewerReplyInInbox(t *testing.T) {
	_, wt := repoWithWorktree(t)
	write(t, filepath.Join(wt, "post.json"), `{"title": "t"}`)
	roots := Resolve(wt)
	id := create(t, roots, filepath.Join(wt, "post.json"))
	WriteReply(roots.PostsDir(), id, nil, "v1", now)
	WriteReply(roots.PostsDir(), id, nil, "v2", now.Add(time.Minute))
	MarkResolved(roots.PostsDir(), id, now.Format(time.RFC3339))
	if got := Inbox(List(roots.PostsDir()), wt, false); len(got) != 1 || got[0].Reply.Comment != "v2" {
		t.Fatalf("AI が読んでいない v2 まで片付いた: %+v", got)
	}
}

func TestMarkResolvedRefusesStaleAt(t *testing.T) {
	_, wt := repoWithWorktree(t)
	write(t, filepath.Join(wt, "post.json"), `{"title": "t"}`)
	roots := Resolve(wt)
	id := create(t, roots, filepath.Join(wt, "post.json"))
	WriteReply(roots.PostsDir(), id, nil, "v2", now.Add(time.Minute))
	_, err := MarkResolved(roots.PostsDir(), id, now.Format(time.RFC3339))
	var stale *StaleError
	if !errors.As(err, &stale) {
		t.Fatalf("古い at の resolve を断らない: %v", err)
	}
}

func TestMarkResolvedWithoutAtResolvesCurrentReply(t *testing.T) {
	_, wt := repoWithWorktree(t)
	write(t, filepath.Join(wt, "post.json"), `{"title": "t"}`)
	roots := Resolve(wt)
	id := create(t, roots, filepath.Join(wt, "post.json"))
	WriteReply(roots.PostsDir(), id, nil, "v1", now)
	MarkResolved(roots.PostsDir(), id, "")
	if got := Inbox(List(roots.PostsDir()), wt, false); len(got) != 0 {
		t.Fatalf("今の返事が片付かない: %+v", got)
	}
}

func TestWriteReplyKeepsReplyJSONWhenReplacing(t *testing.T) {
	_, wt := repoWithWorktree(t)
	write(t, filepath.Join(wt, "post.json"), `{"title": "t"}`)
	roots := Resolve(wt)
	id := create(t, roots, filepath.Join(wt, "post.json"))
	WriteReply(roots.PostsDir(), id, nil, "v1", now)
	WriteReply(roots.PostsDir(), id, nil, "v2", now.Add(time.Minute))
	old, _ := os.ReadFile(filepath.Join(roots.PostsDir(), id, "replies", "20261124T101500.json"))
	if !strings.Contains(string(old), "v1") {
		t.Fatalf("前の返事の中身が replies に写らない: %s", old)
	}
}

func TestCreateMakesMediaNamesSafe(t *testing.T) {
	_, wt := repoWithWorktree(t)
	write(t, filepath.Join(wt, "my shot #1.png"), "A")
	write(t, filepath.Join(wt, "post.json"), `{"sections": [{"id": "A", "options": [{"id": "A1", "media": ["my shot #1.png"]}]}]}`)
	roots := Resolve(wt)
	id := create(t, roots, filepath.Join(wt, "post.json"))
	if _, err := os.Stat(filepath.Join(roots.PostsDir(), id, "my-shot-1.png")); err != nil {
		t.Fatalf("名前が [A-Za-z0-9._-] にそろわない: %v", err)
	}
}
